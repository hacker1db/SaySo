import AVFoundation
import Foundation

/// Local speech-to-text with whisper.cpp. Audio never leaves this Mac.
final class LocalTranscriber {
    static let modelURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sayso/models/ggml-large-v3-turbo.bin")
    static let vadURL = modelURL.deletingLastPathComponent().appendingPathComponent("ggml-silero-v5.1.2.bin")
    static var modelInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    private let queue = DispatchQueue(label: "sayso.whisper")
    private var context: OpaquePointer?

    /// Loads the model in the background so the first dictation is not delayed.
    func preload() { queue.async { _ = self.loadContext() } }

    private func loadContext() -> OpaquePointer? {
        if let context = context { return context }
        guard LocalTranscriber.modelInstalled else { return nil }
        // Homebrew's whisper.cpp ships its Metal/CPU backends as plugins; load them before creating a context.
        ggml_backend_load_all()
        var params = whisper_context_default_params()
        params.use_gpu = true
        context = whisper_init_from_file_with_params(LocalTranscriber.modelURL.path, params)
        return context
    }

    /// Frees the model before exit; Metal asserts if a context is still alive at process teardown.
    func shutdown() { queue.sync { if let ctx = context { whisper_free(ctx); context = nil } } }

    static let phantoms: Set<String> = ["thank you", "thanks for watching", "thank you for watching", "thank you very much",
                                        "you", "bye", "thanks", "so", "okay", "oh", "music", "applause", "silence"]

    /// Loudest 30 ms window, as RMS. Whisper invents phrases ("Thank you.") from silence, so near-silent clips are skipped.
    static func peakLevel(_ samples: [Float]) -> Float {
        var peak: Float = 0, i = 0
        while i < samples.count {
            let end = min(i + 480, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            peak = max(peak, (sum / Float(end - i)).squareRoot()); i = end
        }
        return peak
    }

    /// `samples` are 16 kHz mono floats. Calls back on the main queue.
    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        let peak = LocalTranscriber.peakLevel(samples)
        trace("peak level %.4f", peak)
        guard peak >= 0.01 else { DispatchQueue.main.async { completion(.success("")) }; return }
        queue.async {
            let result: Result<String, Error>
            if let ctx = self.loadContext() {
                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.print_progress = false; params.print_realtime = false
                params.print_special = false; params.print_timestamps = false
                params.no_context = true; params.suppress_blank = true
                params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
                let code: Int32 = "en".withCString { lang in
                    "Sayso dictation.".withCString { prompt in
                        LocalTranscriber.vadURL.path.withCString { vad in
                            params.language = lang; params.initial_prompt = prompt
                            // Silero VAD removes non-speech first, so Whisper cannot invent text from silence or cancelled music.
                            if FileManager.default.fileExists(atPath: LocalTranscriber.vadURL.path) { params.vad = true; params.vad_model_path = vad }
                            return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
                        }
                    }
                }
                if code == 0 {
                    let text = (0..<whisper_full_n_segments(ctx)).map { String(cString: whisper_full_get_segment_text(ctx, $0)) }.joined()
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Whisper invents these from near-silence (e.g. when voice isolation removed the music).
                    let phantom = LocalTranscriber.phantoms.contains(clean.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
                    result = .success(phantom ? "" : clean)
                } else {
                    result = .failure(NSError(domain: "Sayso", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Local transcription failed (whisper error \(code))."]))
                }
            } else {
                result = .failure(NSError(domain: "Sayso", code: 1, userInfo: [NSLocalizedDescriptionKey: "The local Whisper model could not be loaded."]))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Converts microphone buffers to the 16 kHz mono float audio Whisper expects.
final class AudioCollector {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private let mono: AVAudioFormat
    private let lock = NSLock()
    private var samples: [Float] = []

    /// Uses only channel 0: with voice processing on, macOS delivers several channels and the cleaned voice is the first.
    init?(input: AVAudioFormat) {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: AudioCollector.format) else { return nil }
        self.mono = mono; self.converter = converter
    }

    func append(_ input: AVAudioPCMBuffer) {
        guard let source = input.floatChannelData?[0],
              let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength) else { return }
        buffer.frameLength = input.frameLength
        buffer.floatChannelData![0].update(from: source, count: Int(input.frameLength))
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioCollector.format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        lock.lock(); samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength))); lock.unlock()
    }

    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}
