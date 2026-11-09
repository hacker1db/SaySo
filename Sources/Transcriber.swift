import AVFoundation
import Foundation

/// Local speech-to-text with whisper.cpp. Audio never leaves this Mac.
final class LocalTranscriber {
    static let modelURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sayso/models/ggml-large-v3-turbo.bin")
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

    /// `samples` are 16 kHz mono floats. Calls back on the main queue.
    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
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
                        params.language = lang; params.initial_prompt = prompt
                        return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
                    }
                }
                if code == 0 {
                    let text = (0..<whisper_full_n_segments(ctx)).map { String(cString: whisper_full_get_segment_text(ctx, $0)) }.joined()
                    result = .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
    private let lock = NSLock()
    private var samples: [Float] = []

    init?(input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: AudioCollector.format) else { return nil }
        self.converter = converter
    }

    func append(_ buffer: AVAudioPCMBuffer) {
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
