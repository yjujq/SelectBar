import AppKit
import QuartzCore

/// Rewrites the refraction of a glass view.
///
/// `NSGlassEffectView` exposes a style and a corner radius and nothing else,
/// yet the effect underneath is fully parameterised. Its layer tree is a
/// `CABackdropLayer` — the layer that asks the window server for whatever is
/// behind the window — carrying a private `CAFilter` named `glassBackground`,
/// over `CASDFLayer`/`CASDFElementLayer` which describe the capsule as a
/// signed distance field. The bend is computed from the distance to the edge,
/// and how far and how deep it reaches are inputs of that filter.
///
/// So the bar keeps using the system's own refraction, drawn by the window
/// server exactly as the Dock's is. Only the numbers change. Nothing is
/// captured, no permission is involved, and the screen-recording indicator
/// never appears — the pixels never leave the compositor.
///
/// Two things this relies on are private and could go away in any macOS
/// release: the name of the filter and the names of its inputs. Both are
/// checked before use, and if either stops matching, the glass simply keeps
/// the look the system gave it.
enum GlassTuning {

    /// The system fills the filter in while it draws the glass for the first
    /// time, and overwrites whatever we wrote before that. So the write is
    /// deferred to the next turn of the run loop, and repeated once more a
    /// moment later for the case where the first pass has not happened yet.
    static func apply(_ lens: BarLens, to view: NSView) {
        guard !lens.parameters.isEmpty else { return }
        // Staggered rather than once: the first draw is what fills the filter
        // in, and when that happens is not ours to know. Writing four times
        // over the first half-second costs nothing and covers a slow start.
        for delay in [0.0, 0.1, 0.25, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                write(lens.parameters, in: view)
            }
        }
    }

    private static func write(_ parameters: [String: Double], in view: NSView) {
        guard let root = view.layer else { return }
        for (layer, filter) in glassFilters(in: root) {
            // Without this the layer serves the previous frame from its cache
            // and the new numbers never reach the screen.
            layer.setValue(true, forKey: "disableFilterCache")

            for (key, value) in parameters {
                // An input that no longer exists is skipped rather than set:
                // an unknown key on a CAFilter is not an error, it simply
                // accumulates, and a typo would then be invisible.
                guard filter.value(forKey: key) != nil else { continue }
                filter.setValue(value, forKey: key)
            }

            // Core Animation has already handed the filter to the render tree;
            // mutating it in place does not travel. Reassigning the array does.
            let all = layer.filters
            layer.filters = nil
            layer.filters = all
            layer.setNeedsDisplay()
        }
    }

    /// Every `glassBackground` filter in the tree, with the layer that holds it.
    private static func glassFilters(in layer: CALayer) -> [(CALayer, NSObject)] {
        var found: [(CALayer, NSObject)] = []
        if let filters = layer.filters as? [NSObject] {
            for filter in filters where filter.description == "glassBackground" {
                found.append((layer, filter))
            }
        }
        for sublayer in layer.sublayers ?? [] {
            found.append(contentsOf: glassFilters(in: sublayer))
        }
        return found
    }
}

/// A glass container that retunes itself whenever it lands in a window.
///
/// Both the bar and the preview in settings are built by the same code and
/// both need the same treatment, so it lives here rather than at either call
/// site. A window is also where the first draw happens, which is the moment
/// the system fills the filter in — and therefore the moment after which our
/// numbers stick.
@available(macOS 26.0, *)
final class TunedGlassContainer: NSGlassEffectContainerView {
    var lens: BarLens = .system

    /// The tuning is applied here rather than at build time: a window is
    /// where the first draw happens, and the filter does not exist until the
    /// glass has drawn itself once.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        GlassTuning.apply(lens, to: self)
    }
}
