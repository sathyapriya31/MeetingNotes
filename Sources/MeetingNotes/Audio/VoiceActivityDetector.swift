import Foundation

/// Lightweight energy-based Voice Activity Detector that compares mic energy
/// against system audio energy to determine whether the local user is actually
/// speaking, or whether the mic is just picking up speaker bleed-through from
/// the remote participants' audio.
///
/// **How it works**:
/// - Computes RMS energy of mic and system audio in small frames (~20 ms).
/// - Maintains an adaptive estimate of the *bleed ratio* — how much of the
///   system audio typically leaks into the mic given the current speaker
///   volume, mic gain, and physical distance.
/// - A mic frame is considered "user speaking" when its energy exceeds
///   `bleedRatio × systemEnergy + noiseFloor` by a configurable margin.
/// - A 300 ms hangover timer avoids choppy cuts mid-word.
final class VoiceActivityDetector {

    // MARK: - Configuration

    /// Frame size in samples at 16 kHz (~20 ms per frame).
    private let frameSize: Int = 320

    /// Minimum mic RMS energy to even consider as speech (below this is silence).
    private let noiseFloor: Float = 0.005

    /// How much louder the mic must be above estimated bleed to count as speech.
    /// A value of 2.0 means mic energy must be 2× the estimated bleed level.
    private let speechThreshold: Float = 2.0

    /// Smoothing factor for the adaptive bleed ratio (exponential moving average).
    /// Lower = slower adaptation, more stable. Range: 0.0 – 1.0.
    private let bleedAlpha: Float = 0.02

    /// Initial bleed ratio estimate (conservative: assume moderate bleed).
    private var bleedRatio: Float = 0.3

    /// Hangover duration in seconds — speech state persists this long after
    /// the last frame that exceeded the threshold, preventing mid-word cuts.
    private let hangoverSeconds: Double = 0.3

    /// Sample rate (must match the audio pipeline).
    private let sampleRate: Double = 16_000

    // MARK: - State

    /// Timestamp of the last frame that actively exceeded the speech threshold.
    private var lastSpeechTime: Double = -.infinity

    /// Running frame counter used to derive a pseudo-timestamp.
    private var frameCounter: Int = 0

    // MARK: - Ring Buffer for System Audio

    /// Recent system audio for comparison. Stores ~1 second of 16 kHz mono.
    private var systemRing: [Float] = []
    private let systemRingCapacity: Int = 16_000  // 1 second at 16 kHz

    /// Feed system audio samples so the VAD can compare against them.
    func feedSystem(_ samples: [Float]) {
        systemRing.append(contentsOf: samples)
        if systemRing.count > systemRingCapacity {
            systemRing.removeFirst(systemRing.count - systemRingCapacity)
        }
    }

    /// Evaluate whether the user is speaking in the given mic samples.
    /// Call this *before* forwarding mic samples to the transcriber.
    ///
    /// - Parameter micSamples: Raw 16 kHz mono mic samples (one buffer).
    /// - Returns: `true` if the user is likely speaking; `false` if it's
    ///   silence or system audio bleed-through.
    func isUserSpeaking(micSamples: [Float]) -> Bool {
        guard !micSamples.isEmpty else { return false }

        // Process in frames for granularity.
        var anySpeech = false
        var offset = 0
        while offset + frameSize <= micSamples.count {
            let micFrame = Array(micSamples[offset ..< offset + frameSize])
            let micRMS = rms(micFrame)

            // Grab a corresponding system frame from the ring tail.
            let sysRMS: Float
            if systemRing.count >= frameSize {
                let sysStart = max(0, systemRing.count - frameSize)
                let sysFrame = Array(systemRing[sysStart ..< sysStart + frameSize])
                sysRMS = rms(sysFrame)
            } else {
                sysRMS = 0
            }

            let estimatedBleed = bleedRatio * sysRMS
            let currentTime = Double(frameCounter) * Double(frameSize) / sampleRate
            frameCounter += 1

            if micRMS > noiseFloor && micRMS > estimatedBleed * speechThreshold {
                // Mic is significantly louder than bleed — user is speaking.
                lastSpeechTime = currentTime
                anySpeech = true
            } else if sysRMS > noiseFloor && micRMS > 0 && micRMS < sysRMS {
                // System is playing and mic is quieter — this is bleed.
                // Update the adaptive bleed ratio.
                let observedRatio = micRMS / max(sysRMS, 1e-10)
                bleedRatio = bleedRatio * (1 - bleedAlpha) + observedRatio * bleedAlpha
            }

            // Hangover: maintain speech state briefly after threshold crossing.
            if currentTime - lastSpeechTime <= hangoverSeconds {
                anySpeech = true
            }

            offset += frameSize
        }

        return anySpeech
    }

    /// Reset state (e.g., between meetings).
    func reset() {
        systemRing.removeAll()
        bleedRatio = 0.3
        lastSpeechTime = -.infinity
        frameCounter = 0
    }

    // MARK: - Helpers

    /// Root Mean Square energy of a signal buffer.
    private func rms(_ buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        let sumSquares = buffer.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(buffer.count))
    }
}
