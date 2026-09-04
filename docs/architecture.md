# Architecture — Nova (Mobile AI Companion, Android)

No visible app screens. Nova runs as a background service with a status icon —
not a UI app. Android only (iOS blocks persistent overlays + background mic
listening at the platform level, not something workaroundable).

## Folder Structure

> Target/reference layout below. The code as built uses a **flat `lib/`** (one
> level of folders: `config/ models/ controllers/ services/ skills/ utils/`) for
> readability — see the README's "Project layout (as built)". Same components,
> flatter tree.

```
nova_mobile/
├── architecture.md
├── design.md
├── pubspec.yaml
│
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml            # SYSTEM_ALERT_WINDOW, FOREGROUND_SERVICE,
│       │                                   # RECORD_AUDIO, QUERY_ALL_PACKAGES perms
│       └── kotlin/.../
│           ├── OverlayService.kt           # floating status-dot window (native service)
│           ├── WakeWordForegroundService.kt # persistent notification + mic listener
│           └── AccessibilityBridge.kt       # WhatsApp UI read/drive (no official API)
│
├── lib/
│   ├── main.dart                           # boots Nova's services only, no screens
│   │
│   ├── status/
│   │   ├── status_icon_controller.dart     # single source of truth: available/
│   │   │                                     working/sleeping -> drives both
│   │   │                                     notification icon + overlay dot
│   │   └── status_icon_resolver.dart       # build-time check: custom asset vs
│   │                                         generated colored dot
│   │
│   ├── core/
│   │   ├── wake_word_listener.dart         # openWakeWord/Porcupine, on-device
│   │   ├── stt_service.dart                # whisper.cpp mobile build
│   │   ├── tts_service.dart                # Piper, your voice model, on-device
│   │   ├── local_llm_client.dart           # llama.cpp bindings, Qwen2.5-3B primary
│   │   ├── reasoning_engine.dart           # NEW — reasons over the parsed intent
│   │   │                                     before dispatch: why this action, is
│   │   │                                     it reversible, does it need confirmation
│   │   ├── task_queue.dart                 # FIFO queue, worker loop, status-driving
│   │   └── dispatcher.dart                 # reasoned intent -> skill, permission-gated
│   │
│   ├── skills/
│   │   ├── skill_registry.dart
│   │   ├── system_skill.dart               # battery, volume, flashlight
│   │   ├── app_launcher_skill.dart         # NEW — generic "open any app": resolves
│   │   │                                     spoken app name against the device's
│   │   │                                     installed package list at runtime,
│   │   │                                     launches via intent. No per-app
│   │   │                                     hardcoding needed.
│   │   ├── app_control_skill.dart          # NEW — generic Accessibility-based
│   │   │                                     read/tap/type driver, reused by Gmail,
│   │   │                                     WhatsApp, and any other app instead of
│   │   │                                     one-off per-app API integrations
│   │   ├── whatsapp_skill.dart               # thin config on top of app_control_skill:
│   │   │                                     hard allow-list of contacts
│   │   ├── gmail_skill.dart                 # thin config on top of app_control_skill:
│   │   │                                     no OAuth/API — reads/drives the Gmail
│   │   │                                     app UI directly, same as WhatsApp
│   │   ├── chrome_skill.dart                 # open URL/search via Android intents
│   │   │                                     # (NOT profile/history reading — sandboxed)
│   │   ├── meetings_skill.dart               # MediaProjection capture + upload
│   │   └── notes_skill.dart
│   │
│   └── models/
│       ├── llm/qwen2.5-3b-instruct-q4_k_m.gguf     # primary
│       ├── llm/llama-3.2-1b-instruct-q4_k_m.gguf   # low-RAM fallback
│       ├── whisper/                                 # tiny/base model
│       └── tts_voice/                                # your voice model
│
└── assets/
    └── icon/
        └── status.png            # optional — your custom Nova icon, used if
                                    # present at build time, else generated dot
```

## Component Flow

```
┌────────────────────────────────────────────────────────────────┐
│  WakeWordForegroundService (persistent notification — mandatory  │
│  Android requirement, cannot be hidden)                          │
│  Mic stream → wake word model, always on, on-device               │
└───────────────────────────▲───────────────────────────────────┘
                             │ "Wake Up" detected
                             │ (chime/haptic confirms Nova heard you)
                             ▼
                    task_queue.dart.enqueue(transcript)
                             │
                 status_icon_controller -> WORKING (yellow)
                 stays yellow until queue fully drains,
                 not just per-task
                             │
        ┌────────────────────▼────────────────────┐
        │           Worker loop (FIFO)              │
        │  1. stt_service.dart (if not already text)│
        │  2. local_llm_client.dart                  │
        │     Qwen2.5-3B-Instruct -> structured JSON │
        │  3. reasoning_engine.dart                   │
        │     - states WHY this action, in short       │
        │     - flags reversibility (send/delete/etc.) │
        │     - irreversible actions -> confirmation    │
        │       step (spoken or a second wake-word       │
        │       "confirm") before proceeding              │
        │  4. dispatcher.dart                        │
        │     - validates against skill schema        │
        │     - enforces allow-lists (e.g. WhatsApp)  │
        │  5. skills/*.dart executes                  │
        │     (app_launcher_skill for "open X app",    │
        │      app_control_skill for Gmail/WhatsApp)    │
        │  6. tts_service.dart speaks result           │
        └────────────────────┬────────────────────┘
                             │ queue empty
                             ▼
                 status_icon_controller -> AVAILABLE (green)
```

## Status Icon System

Single enum (`available` / `working` / `sleeping`) drives two render targets:
notification small-icon tint, and the floating overlay dot (`SYSTEM_ALERT_WINDOW`).

- **Build-time resolution**: if `assets/icon/status.png` exists at build time,
  it's baked into the APK and tinted per state; if absent, a plain generated
  colored dot is used instead. Decided once at build, not evaluated on-device.
- **Green** = available, listening for wake word
- **Yellow** = working — queue is non-empty (covers the whole backlog, not
  just the single task currently running)
- **Red** = sleeping — listening paused (screen-off idle timeout or manual pause)

## Multi-App Access — What's Actually Possible on Android

| Target | Mechanism | Notes |
|---|---|---|
| Battery, volume, flashlight | Native Android APIs | No caveats |
| Open any app | Generic intent resolution against installed package list | No per-app hardcoding — works for any app on the device |
| Gmail | Accessibility Service (no API/OAuth) | Reads/drives the Gmail app UI directly, same mechanism as WhatsApp. Trade-off vs the official API: more fragile if Gmail's UI changes, and "send" actions go through the reasoning engine's confirmation step since a bad tap can't be validated the way a structured API call can |
| Chrome | Android Intents (open URL, search) | Cannot read Chrome's internal profile/history — sandboxed, no permission unlocks this on Android |
| WhatsApp (send to known contacts) | Accessibility Service | Reads/drives the on-screen UI. Gated by a hard allow-list at the dispatcher level, independent of what the LLM outputs |
| Any other installed app | Accessibility Service, generic driver | Same `app_control_skill.dart` reused rather than one-off integrations per app |
| Meeting recording (Meet in browser) | `MediaProjection` API | Capture, then upload skill sends to a destination you specify |

## Data Boundaries
- Wake word, STT, LLM inference, TTS: 100% on-device, nothing leaves the phone
- Gmail: talks directly to Google's API
- WhatsApp skill: entirely on-device UI automation, no external server involved
- OAuth tokens: encrypted via Android Keystore, never plaintext
