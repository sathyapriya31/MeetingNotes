# MeetingNotes — On-Device AI Meeting Notetaker (macOS, native Swift)

Fully on-device pipeline: system-audio + mic capture → Voz transcription →
speaker diarization → local LLM summary + action items → semantic search & Q&A
over past meetings. No cloud, no bot.

**Minimum target: macOS 14.4, Apple Silicon only.**
(14.4 = Core Audio process taps for bot-free system-audio capture. MLX and
desert-ant-core (Voz/Who) require Apple Silicon.)

---

## Features

- **Live capture** of your mic ("You") and system audio ("Them") — no meeting bot.
- **Live transcript and live summary** while the meeting runs.
- **After Stop:** remote speakers separated ("Speaker 1", "Speaker 2", …), then a
  final summary, key decisions and action items (owner, task, due date).
- **History:** every meeting saved locally; rename speakers and meeting titles,
  filter the transcript by speaker, tick off action items, delete one or all meetings.
- **Search & Ask:** search past meetings by keyword or meaning, and ask questions
  answered from your own meeting notes.
- **Appearance:** Light, Dark or System (⌘, or the icon in the window header).
- **Recording menu:** ⌥N starts / stops a recording; Pause / Resume.

## Architecture

The mic and system-audio channels stay separate until transcription is done, so
"You" vs "Them" comes for free. Steps above **Stop** run live; the rest run once
the meeting ends.

```
┌───────────────┐            ┌────────────────────┐
│ Mic           │            │ System audio       │  Core Audio process tap (14.4+)
│ AVAudioEngine │            │ (Zoom/Meet/Teams)  │
└───────┬───────┘            └─────────┬──────────┘
        │ 16 kHz mono                  │ 16 kHz mono
        ▼                              │
  Bleed VAD ◄──── system energy ───────┤   mic frames that are only speaker
  (mic only)                           │   leak-through → silence
        │                              │
        ▼                              ▼
  Voz "You" channel            Voz "Them" channel     ← 3 s windows, 0.5 s overlap (ANE)
        └──────────────┬───────────────┘
                       ▼
            Live transcript ──► Live summary (Qwen2.5-3B, ≥45 s apart)
                       │
  ──────────────────── Stop ───────────────────────────────────────────
                       ▼
            Transcript dedup        ← drop mic copies of system speech
                       ▼
            Who diarization         ← system channel → "Speaker 1, 2…"
                       ▼
            Final notes (Qwen2.5-3B, 10-min chunks → JSON:
                        summary, decisions, action items)
                       ▼
            Meetings/<id>.json      ← ~/Library/Application Support/MeetingNotes
                       ▼
            Semantic index          ← EmbeddingGemma-300M → embeddings.json
                       ▼
            Search & Ask            ← top passages → Qwen answers
```

| Stage | Source |
|---|---|
| Mic / system-audio capture | `Audio/MicCapture.swift`, `Audio/SystemAudioTap.swift` |
| Bleed VAD | `Audio/VoiceActivityDetector.swift` |
| Transcription (Voz) | `Transcription/TranscriptionService.swift` |
| Dedup | `Transcription/TranscriptDeduplicator.swift` |
| Diarization (Who) | `Diarization/DiarizationService.swift` |
| Summary, action items, Ask answers (Qwen) | `Summarization/SummarizationService.swift` |
| Persistence | `Persistence/MeetingStore.swift` |
| Semantic index & search (EmbeddingGemma) | `Search/SemanticSearchService.swift` |
| Orchestration | `App.swift` (`MeetingCoordinator`) |

## Swift Package dependencies

Declared in `Package.swift` (swift-tools 5.9):

| Package | URL | Products used | Purpose |
|---|---|---|---|
| desert-ant-core | https://github.com/Desert-Ant-Labs/desert-ant-core | `Voz`, `Who` | On-device speech recognition & speaker diarization |
| mlx-swift-lm | https://github.com/ml-explore/mlx-swift-lm | `MLXLLM`, `MLXLMCommon`, `MLXEmbedders`, `MLXHuggingFace` | Local LLM inference and text embeddings |
| mlx-swift | https://github.com/ml-explore/mlx-swift | `MLX` | Direct MLX array access (already a dependency of mlx-swift-lm) |
| swift-huggingface | https://github.com/huggingface/swift-huggingface | `HuggingFace` | Model download from the Hugging Face hub |
| swift-transformers | https://github.com/huggingface/swift-transformers | `Transformers` | Tokenizers |

> APIs in desert-ant-core and MLX move quickly — pin exact versions and check
> the call sites marked `// CHECK-API` against the current release.

## Build & run

```
scripts/bundle.sh          # or: scripts/bundle.sh release
open MeetingNotes.app
```

- The bundle (not the bare SwiftPM binary) is required so macOS attributes the
  microphone / system-audio permissions to the app itself.
- `bundle.sh` builds a menu-bar app (`LSUIElement`) with an **ad-hoc signature**.
  Every rebuild changes the signature, so macOS asks for **Microphone** and
  **System Audio Recording** access again on the next recording.
- The main window opens from the menu-bar icon → **Open Meeting Notes**.
- The first recording after launch takes up to about a minute while the models
  load (the window shows a loading state); later recordings start almost at once.

## Project setup (Xcode alternative)

1. Xcode → New → App (SwiftUI, Swift). Bundle a menu-bar style app
   (`LSUIElement = YES`).
2. Drop the `Sources/MeetingNotes` folders into the target.
3. Add the five package dependencies above.
4. Signing & Capabilities:
   - **Audio Input** (mic)
   - **Outgoing network connections** (only needed for first-run model downloads)
   - **App Sandbox** has not been tested with this project (`bundle.sh` doesn't
     sandbox the app). If you enable it, the model caches move into the app's
     container instead of the paths listed under *Models*.
5. Info.plist keys:
   - `NSMicrophoneUsageDescription` — "Records your side of the meeting."
   - `NSAudioCaptureUsageDescription` — "Records meeting audio from other apps."
     (This drives the macOS 14.4+ system-audio TCC prompt for process taps.)

## Models

Downloaded on first use, then loaded from disk. Quitting the app only unloads
them from memory.

| Model | Used for | Cached at | Size on disk |
|---|---|---|---|
| Voz (desert-ant-core) | Speech recognition | `~/Library/Caches/desert-ant-models/desert-ant-labs/voz` | ~320 MB |
| Who (desert-ant-core) | Speaker diarization | `~/Library/Caches/desert-ant-models/desert-ant-labs/who` | ~80 MB |
| `mlx-community/Qwen2.5-3B-Instruct-4bit` | Summaries, action items, Ask answers | `~/.cache/huggingface/hub/` | ~1.6 GB |
| `mlx-community/embeddinggemma-300m-8bit` | Semantic search & Ask retrieval | `~/.cache/huggingface/hub/` | ~345 MB |

- macOS may clear `~/Library/Caches` when the disk is nearly full; Voz and Who
  are then downloaded again on the next recording (needs internet).
- On 16 GB+ Macs, `Qwen2.5-7B-Instruct-4bit` (~4.3 GB) gives noticeably better
  summaries.

## Data

- Meetings: one JSON file each in `~/Library/Application Support/MeetingNotes/Meetings/`.
- Search index: `~/Library/Application Support/MeetingNotes/embeddings.json`,
  keyed by a fingerprint of each meeting's text so only new or edited meetings
  are re-embedded.

<!--
## Distribution notes

- Direct distribution: Developer ID + notarization, nothing exotic here.
- App Store later: this stack is App Store-safe (Metal/Core ML only, no JIT
  tricks). Keep models as post-install downloads so the binary stays small.

## Known limitations / TODO

- Voz windows are 3 s batches, not token-streaming; live captions lag roughly
  3–6 s. For true streaming swap in sherpa-onnx Zipformer.
- Diarization runs post-meeting (offline diarization is far more accurate than
  online). Live view shows "You / Them" from the two channels instead.
- Dedup runs only after Stop, so the live view can still show mic copies of
  remote speech.
- Word-level timestamp alignment between Voz segments and diarizer turns
  is nearest-overlap; refine if you need broadcast-grade attribution.
-->
