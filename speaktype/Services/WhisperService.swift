import Foundation
import WhisperKit

@Observable
class WhisperService {
    // Shared singleton instance - use this everywhere
    static let shared = WhisperService()

    var pipe: WhisperKit?
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false

    var currentModelVariant: String = ""  // No default - must be explicitly set

    enum TranscriptionError: Error {
        case notInitialized
        case fileNotFound
        case alreadyLoading
    }

    // Init is internal to allow testing, but prefer using .shared in production
    init() {}

    // Default initialization (loads default or saved model)
    func initialize() async throws {
        // You might want to pull from UserDefaults here if you want persistence in Service
        // For now, allow the View to drive the variant selection via loadModel
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading
    func loadModel(variant: String) async throws {
        // Already loaded this exact model
        if isInitialized && variant == currentModelVariant && pipe != nil {
            print("✅ Model \(variant) already loaded, skipping")
            return
        }

        // Prevent concurrent loading
        guard !isLoading else {
            print("⚠️ Model loading already in progress, skipping")
            throw TranscriptionError.alreadyLoading
        }

        print("🔄 Initializing WhisperKit with model: \(variant)...")
        isLoading = true
        isInitialized = false

        // Release existing model to free memory
        if pipe != nil {
            print("🗑️ Releasing previous model from memory...")
            pipe = nil
        }

        do {
            pipe = try await WhisperKit(model: variant)
            currentModelVariant = variant
            isInitialized = true
            print("✅ WhisperKit initialized successfully with \(variant)")

            // Force cold-start warmup so the first real transcription isn't slow
            await warmup()

            isLoading = false
            print("✅ Model warmed up and ready: \(variant)")
        } catch {
            isLoading = false
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }
    }

    /// Run a minimal transcription to force the model's cold-start (first inference is always slow).
    /// This keeps `isLoading = true` so the UI shows "Warming up model..." during the delay.
    private func warmup() async {
        guard let pipe = pipe else { return }

        print("🔥 Warming up model with dummy transcription...")
        do {
            // Generate ~1 second of silence as a temporary audio file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "warmup_silence.wav")
            generateSilentWAV(at: tempURL, durationSeconds: 1.0)

            // Run a throwaway transcription to prime the model pipeline
            _ = try await pipe.transcribe(audioPath: tempURL.path)

            // Clean up
            try? FileManager.default.removeItem(at: tempURL)
            print("🔥 Warmup transcription complete")
        } catch {
            print("⚠️ Warmup transcription failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Generate a minimal silent WAV file for warmup purposes
    private func generateSilentWAV(at url: URL, durationSeconds: Double) {
        let sampleRate: Int = 16000
        let numSamples = Int(durationSeconds * Double(sampleRate))
        let dataSize = numSamples * 2  // 16-bit samples = 2 bytes each
        let fileSize = 44 + dataSize  // WAV header is 44 bytes

        var data = Data()

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        data.append(
            contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM format
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })  // sample rate
        data.append(
            contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })  // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits per sample

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(Data(count: dataSize))  // silence (all zeros)

        try? data.write(to: url)
    }

    func transcribe(audioFile: URL) async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw TranscriptionError.fileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }  // Ensure flag is reset even on error

        print("Starting transcription for: \(audioFile.lastPathComponent)")

        do {
            // Transcribe the audio file
            // Note: WhisperKit 0.9.x API might vary, assuming standard transcribe flow
            let results = try await pipe.transcribe(audioPath: audioFile.path)

            // Combine all segments into a single string
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(
                in: .whitespacesAndNewlines)

            print("Transcription complete: \(text.prefix(50))...")
            return text
        } catch {
            print("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }
}
