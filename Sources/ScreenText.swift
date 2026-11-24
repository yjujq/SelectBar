import AppKit
import Carbon.HIToolbox
import Vision

/// Text from a piece of the screen: the system's own area selection — the
/// crosshair of ⇧⌘4 — then the text in the picture, read by Vision.
///
/// What is read goes to the pasteboard, and then either the bar comes up with
/// it as if it had been selected, or it goes straight to the translation.
@MainActor
enum ScreenText {
    enum Then {
        /// The bar, with all it offers for a selection.
        case bar
        /// DeepL's own little window.
        case translate
    }

    /// Called with the text, and where the pointer was at the end of the
    /// selection — at a corner of the area.
    static var onText: ((String, NSPoint) -> Void)?
    private static var running = false
    private static var endedAt = Date.distantPast

    /// From the shortcut until a moment after the area is chosen: the
    /// mouse-up that ends the drag reaches SelectBar's watcher a little later.
    static var isCapturing: Bool { running || Date().timeIntervalSince(endedAt) < 1 }

    static func capture(then: Then = .bar) {
        guard !running else { return }
        // The selection is drawn by screencapture, but the picture is taken in
        // SelectBar's name: without the permission it holds only the desktop.
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("SelectBar: no screen recording permission; asking for it")
            CGRequestScreenCaptureAccess()
            return
        }
        running = true
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("selectbar-capture-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i area or window, chosen by hand; -x no sound; -o no window shadow.
        task.arguments = ["-i", "-x", "-o", file.path]
        task.terminationHandler = { _ in
            Task { @MainActor in
                running = false
                endedAt = Date()
                defer { try? FileManager.default.removeItem(at: file) }
                let point = NSEvent.mouseLocation
                // Escape leaves no file.
                guard let image = NSImage(contentsOf: file)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let text = await recognise(image)
                guard !text.isEmpty else {
                    NSSound.beep()
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                switch then {
                case .bar: onText?(text, point)
                case .translate:
                    if DeepLApp.installed { DeepLApp.quickTranslate(text) } else { Translator.show(text) }
                }
            }
        }
        do { try task.run() } catch { running = false }
    }

    /// The lines top to bottom, as they stand in the picture.
    nonisolated static func recognise(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { a, b in
                        // Same line when their middles are close: left to right.
                        let dy = a.boundingBox.midY - b.boundingBox.midY
                        if abs(dy) < min(a.boundingBox.height, b.boundingBox.height) / 2 {
                            return a.boundingBox.minX < b.boundingBox.minX
                        }
                        return dy > 0
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Russian first, so Cyrillic is not read as look-alike Latin; then
            // the languages that turn up beside it.
            let wanted = ["ru-RU", "en-US", "uk-UA", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR"]
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            request.recognitionLanguages = wanted.filter(supported.contains)
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: Shortcut

    /// ⇧⌘1: beside the system's ⇧⌘3, ⇧⌘4 and ⇧⌘5 for screenshots. Not ⇧⌘2,
    /// which DeepL takes for its own screenshot translation. With ⌥ as well,
    /// the text is translated at once.
    static let shortcut = "⇧⌘1"
    static let translateShortcut = "⌥⇧⌘1"
    private static var hotKeys: [EventHotKeyRef?] = []

    static func registerShortcut() {
        guard hotKeys.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch number {
                    case 3: ListeningPanel.toggle()
                    case 2: ScreenText.capture(then: .translate)
                    default: ScreenText.capture(then: .bar)
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        // The third, ⌥⇧⌘2, opens the panel that turns sound into text.
        for (number, key, modifiers, name) in [(UInt32(1), kVK_ANSI_1, cmdKey | shiftKey, shortcut),
                                               (UInt32(2), kVK_ANSI_1, cmdKey | shiftKey | optionKey, translateShortcut),
                                               (UInt32(3), kVK_ANSI_2, cmdKey | shiftKey | optionKey, ListeningPanel.shortcut)] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53424354), id: number)   // "SBCT"
            let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { NSLog("SelectBar: \(name) is taken (\(status))") }
            hotKeys.append(ref)
        }
    }
}
