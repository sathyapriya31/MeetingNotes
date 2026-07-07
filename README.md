# MeetingNotes — On-Device AI Meeting Notetaker (macOS, native Swift)

Fully on-device pipeline: system-audio + mic capture → Whisper transcription →
speaker diarization → local LLM summary + action items. No cloud, no bot.

**Minimum target: macOS 14.4, Apple Silicon only.**
(14.4 = Core Audio process taps for bot-free system-audio capture. MLX and
WhisperKit require Apple Silicon.)

---

## Architecture

```
┌─────────────┐   ┌──────────────────┐
│ Mic          │   │ System audio      │  Core Audio process tap (14.4+)
│ AVAudioEngine│   │ (Zoom/Meet/Teams) │  = "you" vs "them" channels for free
└──────┬───────┘   └────────┬─────────┘
       └────── 16 kHz mono ──┘
                │
        VAD gate (FluidAudio / Silero)
                │
        WhisperKit (Core ML, ANE)         ← streaming-ish 15 s windows
                │
        FluidAudio diarization            ← who said what (system channel)
                │
        MLX LLM (Qwen2.5-3B-Instruct 4bit)← chunked map-reduce
                │
        Summary + decisions + action items (typed JSON)
```

## Swift Package dependencies (add in Xcode → Package Dependencies)

| Package | URL | Purpose |
|---|---|---|
| WhisperKit | https://github.com/argmaxinc/WhisperKit | On-device ASR (Core ML/ANE) |
| FluidAudio | https://github.com/FluidInference/FluidAudio | VAD + speaker diarization |
| mlx-swift-examples (MLXLLM/MLXLMCommon) | https://github.com/ml-explore/mlx-swift-examples | Local LLM inference |

> APIs in FluidAudio and MLXLLM move quickly — pin exact versions and check
> the call sites marked `// CHECK-API` against the current release.

## Project setup

1. Xcode → New → App (SwiftUI, Swift). Bundle a menu-bar style app.
2. Drop the `Sources/MeetingNotes` folders into the target.
3. Add the three package dependencies above.
4. Signing & Capabilities:
   - **App Sandbox** (fine to keep on, works with process taps)
   - **Audio Input** (mic)
   - **Outgoing network connections** (only needed for first-run model download)
5. Info.plist keys:
   - `NSMicrophoneUsageDescription` — "Records your side of the meeting."
   - `NSAudioCaptureUsageDescription` — "Records meeting audio from other apps."
     (This drives the macOS 14.4+ system-audio TCC prompt for process taps.)

## Models (downloaded on first run, cached in Application Support)

- ASR: `whisper-small` (~460 MB en/multilingual) — bump to `large-v3-turbo`
  (~1.5 GB) if accuracy matters more than latency.
- Diarization: FluidAudio pulls its segmentation + embedding models (~50 MB).
- LLM: `mlx-community/Qwen2.5-3B-Instruct-4bit` (~1.8 GB). On 16 GB+ Macs,
  `Qwen2.5-7B-Instruct-4bit` (~4.3 GB) gives noticeably better summaries.

<!--
## Distribution notes

- Direct distribution: Developer ID + notarization, nothing exotic here.
- App Store later: this stack is App Store-safe (Metal/Core ML only, no JIT
  tricks). Keep models as post-install downloads so the binary stays small.

## Known limitations / TODO

- Whisper windows are 15 s batches, not token-streaming; good enough for live
  captions with ~5–15 s lag. For true streaming swap in sherpa-onnx Zipformer.
- Diarization runs post-meeting (offline diarization is far more accurate than
  online). Live view shows "You / Them" from the two channels instead.
- Word-level timestamp alignment between Whisper segments and diarizer turns
  is nearest-overlap; refine if you need broadcast-grade attribution.
-->
