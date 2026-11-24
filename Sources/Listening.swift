import AVFoundation
import ScreenCaptureKit
import Speech

/// Speech to text, live: what the Mac is playing, or what the microphone
/// hears, turned into text by the system's on-device dictation engine.
///
/// The dictation transcriber rather than the newer speech transcriber: the
/// latter knows no Russian.
final class Listening: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    enum Source: String, CaseIterable { case mac, microphone }

    enum Failure: LocalizedError {
        case unsupported(String), noAudio, noPermission(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "macOS cannot transcribe \(name) on this Mac."
            case .noAudio: return "Could not reach the sound."
            case .noPermission(let what): return "SelectBar is not allowed to use \(what). Allow it in System Settings → Privacy & Security."
            }
        }
    }

    /// Called on the main thread: the text settled so far, and the words
    /// still being heard, which may yet change.
    var onText: (@MainActor (String, String) -> Void)?
    /// Called on the main thread if listening stops by itself.
    var onFailure: (@MainActor (Error) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "local.selectbar.listening")
    private var settled = ""

    // MARK: Start and stop

    func start(source: Source, locale: Locale) async throws {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupported(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let transcriber = DictationTranscriber(locale: supported, contentHints: [],
                                               transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults, .frequentFinalization],
                                               attributeOptions: [])
        // The language's model, downloaded the first time it is wanted.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudio
        }
        targetFormat = format

        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        settled = ""

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.settled = Self.join(self.settled, text)
                        self.publish(self.settled, "")
                    } else {
                        self.publish(self.settled, text)
                    }
                }
            } catch {
                self?.fail(error)
            }
        }
        try await analyzer.start(inputSequence: sequence)

        switch source {
        case .mac: try await startMacAudio()
        case .microphone: try startMicrophone()
        }
    }

    /// Stops listening; what was still being heard is settled first.
    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        await resultsTask?.value
        resultsTask = nil
        converter = nil
    }

    // MARK: Sources

    /// Everything the Mac plays, SelectBar's own sounds aside. The capture is
    /// of a display, as ScreenCaptureKit wants one, but as small and as
    /// seldom as it allows: only the sound is used.
    private func startMacAudio() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.noPermission("screen and system audio recording")
        }
        guard let display = content.displays.first else { throw Failure.noAudio }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func startMicrophone() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            throw Failure.noPermission("the microphone")
        }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Failure.noAudio }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.queue.async { self?.feed(buffer) }
        }
        try engine.start()
        self.engine = engine
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        feed(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail(error)
    }

    // MARK: Audio

    /// Into the format the analyzer asked for, and on to it.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let input, let targetFormat else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription,
              let asbd = description.audioStreamBasicDescription else { return nil }
        var streamDescription = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    // MARK: Results

    private static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return a }
        guard !a.isEmpty else { return b }
        return a + " " + b
    }

    private func publish(_ settled: String, _ volatile: String) {
        let handler = onText
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(settled, volatile) } }
    }

    private func fail(_ error: Error) {
        let handler = onFailure
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(error) } }
    }
}
