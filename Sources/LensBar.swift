import AppKit
import CoreMedia
import CoreVideo
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
/// It was a photograph at first, taken once as the bar appeared, on the
/// reasoning that nothing moves underneath in the second or two it is up. That
/// is wrong often enough to matter: video plays, pages scroll, and the lens sat
/// there showing a moment that had passed.
///
/// So it is a film. `SCStream` is the tool for it — the one thing in
/// ScreenCaptureKit meant for continuous capture — and it hands back
/// `CVPixelBuffer`s the texture cache turns into Metal textures without a copy.
/// Repeating single screenshots on a timer would cost far more: each one
/// enumerates the shareable content of the whole machine before it can begin.
/// The stream runs only while the bar is on screen.
@MainActor
final class LensView: NSView {

    /// The lens the shader is set to, taken from the same setting the glass
    /// styles use so both routes answer to one control.
    var lens: BarLens = .system

    /// The capsule's radius, in points.
    var cornerRadius: CGFloat = 0

    /// How long to keep filming, or nil to film for as long as the view is on
    /// screen.
    ///
    /// The bar wants nil: it is up for a second or two and then gone, and the
    /// indicator in the menu bar goes out with it. The preview in settings
    /// wants a limit — it sits there for as long as the Appearance page is
    /// open, which can be minutes, and there is no reason to hold the camera
    /// on for all of them. It films long enough to show what the lens does and
    /// then keeps its last frame.
    var liveFor: TimeInterval?

    /// What to show until the first frame arrives, and if none ever does.
    ///
    /// A stream takes a moment to start, and it may never start at all —
    /// Screen Recording refused, or granted just now and not in force until
    /// the next launch. Drawing nothing in the meantime left a hole where the
    /// bar should be: the icons floating over the page with no bar under them.
    /// The plain fill stands in, so the worst case is the Solid style rather
    /// than nothing at all.
    var fallback: NSColor = .clear

    private var renderer: LensRenderer?
    private let stream = LensStream()
    private var latest: CVPixelBuffer?
    /// Where the bar sits inside the photograph, 0 to 1 on each axis. Not the
    /// whole of it: the picture is taken wider than the bar.
    private var barInPicture = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The stream is started once. Without this a window change — moving
    /// between spaces, say — would set a second one going for the same bar.
    private var started = false

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        // Frames arrive from the stream at their own pace, and each is drawn
        // as it comes. Not presentsWithTransaction: that waits for the command
        // buffer to finish before handing the drawable over, which is right
        // for a single picture and a stall for thirty a second.
        layer.presentsWithTransaction = false
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    /// Stop filming now, rather than whenever this view happens to be freed.
    ///
    /// Ordering a panel out does not take its content view off the window, and
    /// the window itself lives on until the last reference to it goes — which
    /// is not the moment the bar disappears. Left to deallocation, the camera
    /// ran on after the bar was gone and the indicator in the menu bar stayed
    /// lit with nothing on screen to explain it.
    func stopFilming() {
        stream.stop()
        started = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // The bar has gone. Nothing is watching the screen any more, and
            // the indicator in the menu bar goes out with it.
            stream.stop()
            started = false
            return
        }
        guard !started else { return }
        started = true
        beginCapture()
    }

    deinit { stream.stop() }

    override func layout() {
        super.layout()
        guard let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2

        // The fill sits on the layer beneath whatever the shader draws. The
        // shader leaves everything outside the capsule transparent, and the
        // rounded corner here is that same capsule, so the two agree on the
        // silhouette and only the inside is ever replaced.
        layer.backgroundColor = fallback.cgColor
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true

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

    /// How much wider than the bar the photograph is taken.
    ///
    /// A lens that shrinks what is under it has to read from beyond its own
    /// edges, and a picture cut to the bar has nothing there to read — the
    /// sampler simply repeats the last column, which is the smearing the
    /// stronger settings used to show at their caps. Four times over covers the
    /// widest of them — Reduce reads 3.4 bar-widths across — and costs one
    /// capture of a few hundred pixels. Read wider than the picture reaches and
    /// the sampler repeats its edge column, which comes out as a band of flat
    /// colour at the cap.
    private let overscan: CGFloat = 4

    private func beginCapture() {
        guard let (screen, rect) = screenRect(), rect.width > 1, rect.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2

        // Widened about the bar's centre, then held inside the display: asking
        // for anything outside it comes back empty.
        let grown = rect.insetBy(dx: -rect.width * (overscan - 1) / 2,
                                 dy: -rect.height * (overscan - 1) / 2)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let shot = grown.intersection(bounds)
        guard shot.width > 1, shot.height > 1 else { return }

        // Where the bar ended up in whatever was actually taken — which is not
        // the middle when the bar sits near an edge of the screen and the
        // widened rectangle was clipped.
        barInPicture = CGRect(x: (rect.minX - shot.minX) / shot.width,
                              y: (rect.minY - shot.minY) / shot.height,
                              width: rect.width / shot.width,
                              height: rect.height / shot.height)

        let pixels = CGSize(width: shot.width * scale, height: shot.height * scale)
        stream.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.latest = buffer
            self.draw()
        }
        stream.start(of: shot, on: screen, sized: pixels)

        if let liveFor {
            DispatchQueue.main.asyncAfter(deadline: .now() + liveFor) { [weak self] in
                // The last frame stays on the layer; only the camera stops.
                self?.stream.stop()
            }
        }
    }

    // MARK: - Drawing

    private func draw() {
        guard let layer = layer as? CAMetalLayer,
              let latest,
              layer.drawableSize.width > 0 else { return }

        if renderer == nil { renderer = LensRenderer() }
        guard let renderer else { return }

        let scale = window?.backingScaleFactor ?? 2
        renderer.draw(frame: latest, in: layer, barInPicture: barInPicture,
                      radius: cornerRadius * scale,
                      lens: lens, scale: scale)
    }
}

/// A live feed of whatever is on screen behind us.
///
/// Our own application is left out of it, which is what makes the capture safe
/// to run while the bar is already on screen: without that the bar would film
/// itself and every frame would fold the last one into the picture.
final class LensStream: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Handed each frame on the main thread, for as long as the stream runs.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var stream: SCStream?
    /// Frames are delivered here rather than on the main queue: the callback
    /// arrives thirty times a second and the main thread has a panel to draw.
    private let delivery = DispatchQueue(label: "local.selectbar.lens", qos: .userInitiated)

    func start(of rect: CGRect, on screen: NSScreen, sized pixels: CGSize) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)

                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                guard let display = content.displays.first(where: {
                    $0.displayID == number?.uint32Value
                }) ?? content.displays.first else { return }

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
                // Thirty a second. The bar is small and short-lived, and past
                // this the eye gains nothing while the machine pays for every
                // frame.
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen,
                                           sampleHandlerQueue: self.delivery)
                try await stream.startCapture()
                self.stream = stream
            } catch {
                // Permission refused, or the display went away between asking
                // and starting. The bar keeps the plain fill underneath.
                NSLog("SelectBar: the screen could not be filmed: \(error)")
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // A frame arrives even when nothing under the bar has changed, and
        // then carries no image at all — the status says so. Drawing it would
        // blank the bar.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        DispatchQueue.main.async { [weak self] in self?.onFrame?(buffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SelectBar: the lens stream stopped: \(error)")
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

    /// Whether what lies in `rect` is dark, or nil if the screen cannot be
    /// read — no permission, or no display there.
    ///
    /// The picture is asked for at a couple of dozen pixels across. The mean
    /// is all that is wanted, and scaling to that size is the window server's
    /// work rather than ours.
    static func tone(of rect: NSRect) async -> Bool? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
                        ?? NSScreen.main else { return nil }
        let local = CGRect(x: rect.minX - screen.frame.minX,
                           y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        // The shape of the region, not a fixed one. The capture fits the
        // region into whatever size is asked for without stretching it, and
        // fills what is left over with black — so a bar of any other
        // proportion than the size asked for was measured together with a
        // black margin, and came out dark whatever it was standing on. A bar
        // is around 52 by 44 with one action in it; against a fixed 24 by 8
        // that margin was well over half the picture.
        let across = 24.0
        let down = max(1.0, (across * local.height / max(local.width, 1)).rounded())
        guard let image = await take(of: local, on: screen,
                                     sized: CGSize(width: across, height: down))
        else { return nil }
        return meanLuminance(of: image).map { $0 < 0.5 }
    }

    private static func meanLuminance(of image: CGImage) -> Double? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * 4 * h)
        // Inside the closure, all of it. `&bytes` lends the array's storage
        // for the length of the call it is written in and no longer — and the
        // drawing happens on the line after, by which time the context may be
        // writing somewhere else entirely. It reads as a screen that is always
        // dark, because what is measured is a buffer that stayed zero; and it
        // is intermittent, because whether the storage is still there is a
        // matter of what the allocator did next. Two readings of the same
        // white screen, a second apart, came back light and dark.
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var total = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            // Little-endian BGRA, and weighted the way the eye weighs them:
            // green carries most of the brightness, blue almost none.
            let b = Double(bytes[i]), g = Double(bytes[i + 1]), r = Double(bytes[i + 2])
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return total / Double(bytes.count / 4)
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
        var barInPicture: SIMD4<Float>
        var size: SIMD2<Float>
        var radius: Float
        var strength: Float
        var band: Float
        var blur: Float
        var shape: Int32
    }

    /// The device, its queue and the compiled pipeline. None of the three
    /// ever changes, and building them costs some thirty milliseconds —
    /// measured — nearly all of it compiling the shader from source.
    private struct Machinery {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
    }

    /// Built once for the life of the process.
    ///
    /// It used to be built per instance, and an instance is made by the view
    /// that draws the bar — a new view every time the bar appears. So every
    /// appearance paid to compile the same shader again, thirty milliseconds
    /// before anything could be drawn.
    private static let machinery: Machinery? = makeMachinery()

    /// Turns a frame from the stream into a Metal texture without copying it:
    /// the pixels stay where the window server put them and the GPU is handed
    /// a view onto them. At thirty frames a second a copy each time would be
    /// the most expensive thing here by far.
    private var textures: CVMetalTextureCache?

    private static func makeMachinery() -> Machinery? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
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
            return Machinery(device: device, queue: queue,
                             pipeline: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            NSLog("SelectBar: the lens shader would not build: \(error)")
            return nil
        }
    }

    func draw(frame: CVPixelBuffer, in layer: CAMetalLayer, barInPicture: CGRect,
              radius: CGFloat, lens: BarLens, scale: CGFloat) {
        guard let machinery = Self.machinery else { return }
        layer.device = machinery.device

        if textures == nil {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, machinery.device, nil, &textures)
        }
        guard let textures,
              let texture = Self.texture(from: frame, cache: textures),
              let drawable = layer.nextDrawable() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = machinery.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let numbers = lens.parameters
        // The same dictionary the glass route writes into the private filter,
        // read here as plain numbers. A stock clear bar bends by 60 over a
        // band of 20, which is what an empty dictionary — "leave it be" —
        // stands for.
        var params = Params(
            barInPicture: SIMD4(Float(barInPicture.minX), Float(barInPicture.minY),
                                Float(barInPicture.width), Float(barInPicture.height)),
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
            blur: Float((numbers["inputBlurRadius"] ?? 0) * scale),
            shape: lens.shape.rawValue)

        encoder.setRenderPipelineState(machinery.pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Scheduled rather than waited on: at thirty frames a second, blocking
        // the main thread until the GPU is done would stall the whole panel.
        buffer.present(drawable)
        buffer.commit()

        // The cache hands out a texture per frame and holds each until told it
        // may go. Left alone at thirty a second it grows without bound; this
        // releases the ones no longer in use.
        CVMetalTextureCacheFlush(textures, 0)
    }

    /// A Metal view onto the frame's own pixels.
    ///
    /// The CVMetalTexture must outlive the encoding, hence holding it until
    /// the texture has been taken from it; the cache reclaims it afterwards.
    private static func texture(from frame: CVPixelBuffer,
                                cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        guard width > 0, height > 0 else { return nil }

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, frame, nil,
            .bgra8Unorm, width, height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped else { return nil }
        return CVMetalTextureGetTexture(wrapped)
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

    // The most strictly aligned member first, so Swift and Metal agree on the
    // layout without either side having to guess where the padding went.
    struct Params {
        float4 barInPicture;   // where the bar sits in the photograph, 0 to 1
        float2 size;
        float  radius;
        float  strength;
        float  band;
        float  blur;
        int    shape;
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

    // The photograph reaches beyond the bar on every side, so a point may be
    // read from outside it. Bar space runs 0 to 1 across the bar itself; this
    // puts such a point where it belongs in the picture.
    static float2 inPicture(float2 barSpace, constant Params &P) {
        return P.barInPicture.xy + barSpace * P.barInPicture.zw;
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

        // All of the bend at the rim, none of it a band's width in.
        float t = clamp(1.0 + d / max(P.band, 0.001), 0.0, 1.0);

        float2 unit = px / P.size;        // 0 to 1 across the bar
        float2 c = unit - 0.5;
        float2 norm = centred / halfSize;
        float r2 = dot(norm, norm);
        float2 edgeBend = g * (P.strength * t * t) / P.size;
        // The strength in bar space rather than pixels, which is the unit a
        // pick is measured in.
        float2 push = float2(P.strength) / P.size;

        // Where to read from, in bar space. A scale above 1 reads from wider
        // afield than the bar covers and so shrinks what is under it; below 1
        // reads from a smaller patch and magnifies.
        float2 pick;
        switch (P.shape) {
            case 1:  pick = 0.5 + c * 0.62; break;               // Convex
            case 2:  pick = 0.5 + c * 1.55; break;               // Concave
            case 3:  pick = 0.5 + c * (1.0 - 0.55 * (1.0 - r2)); break;  // Fisheye
            case 4:  pick = unit + float2(0.0,                    // Cylinder
                        -norm.y * P.strength * 2.5 * (1.0 - norm.y * norm.y) / P.size.y);
                     break;
            case 6:  pick = 0.5 + c * 3.4; break;                // Reduce
            case 7:  pick = 0.5 + c * 0.40; break;               // Magnify
            case 8:  pick = unit + g * (P.strength * 2.2 * pow(t, 6.0)) / P.size; break; // Bevel
            case 9: {                                            // Ripple
                float rr = length(norm);
                float wave = sin(rr * 16.0) * (1.0 - rr) * 0.5;
                pick = unit + normalize(norm + float2(1e-6)) * wave * P.strength / P.size;
                break;
            }
            case 10: pick = 0.5 + float2(c.x * 2.4, c.y); break;  // Anamorphic

            case 12: {   // Fresnel: the curve cut into rings and laid flat.
                // A thick lens's face, sliced into concentric bands with the
                // bulk thrown away. Each band carries the same slope the whole
                // curve would have had there, so the bend starts over at every
                // ring — which is what makes the rings visible.
                const float rings = 4.0;
                float radius = length(norm);
                float within = fract(radius * rings) - 0.5;
                pick = unit + normalize(norm + float2(1e-6)) * within * push * 3.2;
                break;
            }
            case 13: {   // Lenticular: a row of glass rods laid side by side.
                const float rods = 7.0;
                float across = fract(unit.x * rods) - 0.5;
                pick = unit + float2(-across * P.strength * 2.0 / P.size.x, 0.0);
                break;
            }
            case 14:     // Axicon: a cone, so the slope never changes.
                // A dome's bend grows with the radius; a cone's does not. The
                // light it gathers falls in a ring rather than a point.
                pick = unit + normalize(norm + float2(1e-6)) * push * 1.1;
                break;
            case 15:     // Aspheric: flat in the middle, sharp at the rim.
                pick = 0.5 + c * (1.0 - 0.75 * r2 * r2 * r2);
                break;
            case 16:     // Astigmatic: one power across, another down.
                pick = 0.5 + float2(c.x * 0.65, c.y * 1.7);
                break;
            case 17: {   // Coma: the smear given to what is off the axis.
                // Sharp on the side towards the axis and trailing away from
                // it, and worse the further out — hence the square of the
                // radius rather than the radius itself.
                float2 away = normalize(norm + float2(1e-6));
                pick = unit + (away + float2(0.35, 0.0)) * r2 * push * 2.6;
                break;
            }
            default: pick = unit + edgeBend; break;               // Edge, and the rest
        }

        float4 colour;
        if (P.shape == 11) {
            // Fisheye and prism together, which is what a single piece of real
            // glass does rather than a contrivance: it magnifies from the
            // middle outwards, and the three colours do not magnify by quite
            // the same amount. Each channel therefore gets its own fisheye,
            // and because all three agree at the centre and diverge with the
            // radius, the fringe appears where a lens really does show it —
            // at the rim, where the ray meets the glass most steeply.
            float2 pr = 0.5 + c * (1.0 - 0.62 * (1.0 - r2));
            float2 pg = 0.5 + c * (1.0 - 0.55 * (1.0 - r2));
            float2 pb = 0.5 + c * (1.0 - 0.48 * (1.0 - r2));
            float  r  = picture.sample(smp, inPicture(pr, P)).r;
            float4 mid = picture.sample(smp, inPicture(pg, P));
            float  b  = picture.sample(smp, inPicture(pb, P)).b;
            colour = float4(r, mid.g, b, mid.a);
        } else if (P.shape == 5) {
            // A prism has no single answer: each channel leaves the glass at
            // its own angle, so each is read from its own place.
            float r = picture.sample(smp, inPicture(unit + edgeBend * 1.8, P)).r;
            float b = picture.sample(smp, inPicture(unit + edgeBend * 0.2, P)).b;
            float4 mid = picture.sample(smp, inPicture(unit + edgeBend, P));
            colour = float4(r, mid.g, b, mid.a);
        } else if (P.blur > 0.5) {
            float4 sum = float4(0.0);
            for (int i = -3; i <= 3; ++i) {
                for (int j = -3; j <= 3; ++j) {
                    float2 o = float2(i, j) * (P.blur / 3.0) / P.size;
                    sum += picture.sample(smp, inPicture(pick + o, P));
                }
            }
            colour = sum / 49.0;
        } else {
            colour = picture.sample(smp, inPicture(pick, P));
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
