import AppKit
import Metal
import ScreenCaptureKit

/// The bar drawn as a real lens: a photograph of what lies behind it, bent by
/// a shader of our own.
///
/// This is the route the glass styles deliberately do not take — see the
/// README. The system's own glass is drawn by the window server, which is why
/// it costs no permission and lights no indicator. A shader cannot reach into
/// another application's window, so to bend what is behind the bar it must
/// first be given a picture of it, and taking that picture needs Screen
/// Recording. The purple indicator in the menu bar is the price, and it is why
/// this is an option rather than the default.
///
/// It is a photograph, not a film. The bar is up for a second or two and what
/// is behind it does not move in that time, so one capture when it appears is
/// enough — and a still costs neither the frame rate nor the battery of a
/// stream.
@MainActor
final class LensView: NSView {

    /// The lens the shader is set to, taken from the same setting the glass
    /// styles use so both routes answer to one control.
    var lens: BarLens = .system

    /// The capsule's radius, in points.
    var cornerRadius: CGFloat = 0

    private var renderer: LensRenderer?
    private var captured: CGImage?
    /// The capture is asked for once. Without this a window change — moving
    /// between spaces, say — would set another one going for the same bar.
    private var asked = false

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        // Drawn on demand rather than on a display link: the picture behind
        // the bar is taken once and never changes while it is up.
        layer.presentsWithTransaction = true
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !asked else { return }
        asked = true
        capture()
    }

    override func layout() {
        super.layout()
        guard let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale,
                                    height: bounds.height * scale)
        draw()
    }

    // MARK: - The photograph

    /// The rectangle this view occupies on screen, in the coordinates
    /// ScreenCaptureKit wants: the origin at the top left of its display,
    /// while Cocoa's is at the bottom left of the primary one.
    private func screenRect() -> (display: NSScreen, rect: CGRect)? {
        guard let window else { return nil }
        let inWindow = convert(bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        guard let display = NSScreen.screens.first(where: {
            $0.frame.intersects(onScreen)
        }) ?? NSScreen.main else { return nil }

        let local = CGRect(x: onScreen.minX - display.frame.minX,
                           y: display.frame.maxY - onScreen.maxY,
                           width: onScreen.width,
                           height: onScreen.height)
        return (display, local)
    }

    private func capture() {
        guard let (screen, rect) = screenRect(), rect.width > 1, rect.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: rect.width * scale, height: rect.height * scale)

        Task { [weak self] in
            let image = await ScreenPhoto.take(of: rect, on: screen, sized: pixels)
            guard let self, let image else { return }
            self.captured = image
            self.draw()
        }
    }

    // MARK: - Drawing

    private func draw() {
        guard let layer = layer as? CAMetalLayer,
              let captured,
              layer.drawableSize.width > 0 else { return }

        if renderer == nil { renderer = LensRenderer() }
        guard let renderer else { return }

        let scale = window?.backingScaleFactor ?? 2
        renderer.draw(image: captured, in: layer,
                      radius: cornerRadius * scale,
                      lens: lens, scale: scale)
    }
}

/// One still of whatever is on screen behind us.
enum ScreenPhoto {

    /// Whether Screen Recording has been granted. Asked without prompting, so
    /// settings can say so plainly instead of the bar simply coming out blank.
    static var permitted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for it. The system shows its own dialogue and the answer only
    /// takes effect on the next launch, which is the system's rule, not ours.
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// The picture, with our own application left out of it.
    ///
    /// Excluding ourselves is what makes the capture safe to take while the
    /// bar is already on screen: without it the bar would photograph itself
    /// and each capture would fold the last one into the picture.
    static func take(of rect: CGRect, on screen: NSScreen, sized pixels: CGSize) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            // NSScreen and SCDisplay are matched on the display's identifier,
            // which NSScreen keeps in its device description.
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            guard let display = content.displays.first(where: {
                $0.displayID == number?.uint32Value
            }) ?? content.displays.first else { return nil }

            let ours = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ours,
                                         exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(pixels.width.rounded())
            config.height = Int(pixels.height.rounded())
            config.captureResolution = .best
            config.showsCursor = false
            config.scalesToFit = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            // Permission refused, or the display went away between asking and
            // capturing. Either way the bar keeps the plain fill underneath.
            NSLog("SelectBar: the screen could not be photographed: \(error)")
            return nil
        }
    }
}

/// The shader, and the little that is needed to run it.
///
/// The source is compiled at runtime rather than shipped as a .metallib: the
/// build is a single call to swiftc with no Metal step in it, and adding one
/// for thirty lines of shader would be the larger change.
@MainActor
final class LensRenderer {

    /// Mirrors the `Params` struct in the shader. Laid out to match: two
    /// floats of size, then four loose ones.
    private struct Params {
        var size: SIMD2<Float>
        var radius: Float
        var strength: Float
        var band: Float
        var blur: Float
    }

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var textureSource: CGImage?

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            self.device = nil; self.queue = nil; self.pipeline = nil
            return
        }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "lens_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "lens_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // The bar is not a rectangle, so what falls outside the capsule is
            // left transparent and must blend rather than overwrite.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("SelectBar: the lens shader would not build: \(error)")
            pipeline = nil
        }
    }

    func draw(image: CGImage, in layer: CAMetalLayer,
              radius: CGFloat, lens: BarLens, scale: CGFloat) {
        guard let device, let queue, let pipeline else { return }
        layer.device = device

        if textureSource !== image {
            texture = Self.makeTexture(from: image, device: device)
            textureSource = image
        }
        guard let texture, let drawable = layer.nextDrawable() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let numbers = lens.parameters
        // The same dictionary the glass route writes into the private filter,
        // read here as plain numbers. A stock clear bar bends by 60 over a
        // band of 20, which is what an empty dictionary — "leave it be" —
        // stands for.
        var params = Params(
            size: SIMD2(Float(layer.drawableSize.width), Float(layer.drawableSize.height)),
            radius: Float(radius),
            // The filter's amount is not a distance, so there is no true
            // conversion — it is fitted by eye against a rendering of this
            // very shader. A twentieth puts the stock 60 at three points and
            // keeps Deep's 400 from smearing the whole bar, which a sixth did.
            // Capped just under the band as well: displacement wider than the
            // fall-off has nowhere left to fall off to.
            strength: Float(min(abs(numbers["inputInnerRefractionAmount"] ?? -60) / 20,
                                (numbers["inputInnerRefractionHeight"] ?? 20) * 0.9) * scale),
            band: Float((numbers["inputInnerRefractionHeight"] ?? 20) * scale),
            blur: Float((numbers["inputBlurRadius"] ?? 0) * scale))

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // presentsWithTransaction is set on the layer, so the drawable is
        // handed over after the buffer has finished rather than scheduled
        // alongside it — otherwise the first frame can reach the screen before
        // it has been drawn, and the bar flickers as it appears.
        buffer.commit()
        buffer.waitUntilCompleted()
        drawable.present()
    }

    private static func makeTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: &bytes, bytesPerRow: rowBytes)
        return texture
    }

    /// The shader itself.
    ///
    /// The capsule is a signed distance field, the same shape the system's own
    /// glass is built on. The bend is the field's gradient — the direction
    /// straight out of the nearest edge — applied to the coordinate the picture
    /// is sampled at, and falling off to nothing by the time it is a band's
    /// width inside. That is the whole of it: what is sampled from further out
    /// than it should be is what makes an edge look like glass.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    struct Params {
        float2 size;
        float  radius;
        float  strength;
        float  band;
        float  blur;
    };

    vertex VOut lens_vertex(uint vid [[vertex_id]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 p = corners[vid];
        VOut out;
        out.pos = float4(p, 0, 1);
        out.uv = float2((p.x + 1) * 0.5, 1 - (p.y + 1) * 0.5);
        return out;
    }

    // Negative inside the capsule, zero on its outline.
    static float sdRoundRect(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - (halfSize - r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 lens_fragment(VOut in [[stage_in]],
                                  texture2d<float> picture [[texture(0)]],
                                  constant Params &P [[buffer(0)]]) {
        constexpr sampler smp(address::clamp_to_edge, filter::linear);

        float2 px = in.uv * P.size;
        float2 halfSize = P.size * 0.5;
        float2 centred = px - halfSize;
        float d = sdRoundRect(centred, halfSize, P.radius);
        if (d > 0.0) { return float4(0.0); }

        // The gradient of the field: which way the nearest edge lies.
        const float e = 1.0;
        float2 g = float2(
            sdRoundRect(centred + float2(e, 0), halfSize, P.radius)
          - sdRoundRect(centred - float2(e, 0), halfSize, P.radius),
            sdRoundRect(centred + float2(0, e), halfSize, P.radius)
          - sdRoundRect(centred - float2(0, e), halfSize, P.radius));
        g = normalize(g + float2(1e-6));

        // All of the bend at the rim, none of it a band's width in. Squared,
        // so the fall is gentle rather than a visible ring.
        float t = clamp(1.0 + d / max(P.band, 0.001), 0.0, 1.0);
        float2 offset = g * (P.strength * t * t);

        float4 colour;
        if (P.blur > 0.5) {
            float4 sum = float4(0.0);
            for (int i = -3; i <= 3; ++i) {
                for (int j = -3; j <= 3; ++j) {
                    float2 o = float2(i, j) * (P.blur / 3.0);
                    sum += picture.sample(smp, (px + offset + o) / P.size);
                }
            }
            colour = sum / 49.0;
        } else {
            colour = picture.sample(smp, (px + offset) / P.size);
        }

        // The rim catches a little light, as a real edge does. Its width is
        // fixed at a few pixels rather than taken from the refraction band:
        // that band is 20 points by default, while the bar is 38 tall, so a
        // highlight following it washed out the whole capsule instead of
        // catching its edge.
        float rim = clamp(1.0 + d / 4.0, 0.0, 1.0);
        colour.rgb += rim * rim * 0.12;

        // One pixel of softening on the outline, or the capsule comes out
        // with a staircase for a cap.
        float alpha = clamp(-d, 0.0, 1.0);
        return float4(colour.rgb, alpha);
    }
    """
}
