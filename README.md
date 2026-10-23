# MeetingNotes — On-Device AI Meeting Notetaker (macOS, native Swift)

Fully on-device pipeline: system-audio + mic capture → Voz transcription →
speaker diarization → local LLM summary + action items. No cloud, no bot.

**Minimum target: macOS 14.4, Apple Silicon only.**
(14.4 = Core Audio process taps for bot-free system-audio capture. MLX and
desert-ant-core (Voz/Who) require Apple Silicon.)

---

## Architecture

```
┌─────────────┐   ┌──────────────────┐
│ Mic          │   │ System audio      │  Core Audio process tap (14.4+)
│ AVAudioEngine│   │ (Zoom/Meet/Teams) │  = "you" vs "them" channels for free
└──────┬───────┘   └────────┬─────────┘
       └────── 16 kHz mono ──┘
                │
        Bleed-through VAD (mic vs system energy) ← mic-only speaker leak is silenced
                │
        Voz (desert-ant-core, ANE)        ← 3 s windows, 0.5 s overlap
                │
        Transcript dedup                  ← drops mic copies of system speech
                │
        Who diarization (desert-ant-core) ← who said what (system channel, post-meeting)
                │
        MLX LLM (Qwen2.5-3B-Instruct 4bit)← chunked map-reduce (live every ≥45 s + final)
                │
        Summary + decisions + action items (typed JSON)
```

## Swift Package dependencies (add in Xcode → Package Dependencies)

| Package | URL | Purpose |
|---|---|---|
| Voz & Who (desert-ant-core) | https://github.com/Desert-Ant-Labs/desert-ant-core | On-device speech recognition & speaker diarization |
| mlx-swift-lm (MLXLLM/MLXLMCommon) | https://github.com/ml-explore/mlx-swift-lm | Local LLM inference |

> APIs in desert-ant-core and MLXLLM move quickly — pin exact versions and check
> the call sites marked `// CHECK-API` against the current release.

## Build & run

```
scripts/bundle.sh          # or: scripts/bundle.sh release
open MeetingNotes.app
```

The bundle (not the bare SwiftPM binary) is required so macOS attributes the
microphone / system-audio permissions to the app itself.

## Project setup (Xcode alternative)

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

- ASR: Voz (desert-ant-core) downloads its model on first use.
- Diarization: Who (desert-ant-core) downloads its models on first use.
- LLM: `mlx-community/Qwen2.5-3B-Instruct-4bit` (~1.8 GB). On 16 GB+ Macs,
  `Qwen2.5-7B-Instruct-4bit` (~4.3 GB) gives noticeably better summaries.

<!--
## Distribution notes

- Direct distribution: Developer ID + notarization, nothing exotic here.
- App Store later: this stack is App Store-safe (Metal/Core ML only, no JIT
  tricks). Keep models as post-install downloads so the binary stays small.

## Known limitations / TODO

- Voz windows are 3 s batches, not token-streaming; good enough for live
  captions with ~5–15 s lag. For true streaming swap in sherpa-onnx Zipformer.
- Diarization runs post-meeting (offline diarization is far more accurate than
  online). Live view shows "You / Them" from the two channels instead.
- Word-level timestamp alignment between Voz segments and diarizer turns
  is nearest-overlap; refine if you need broadcast-grade attribution.
-->
