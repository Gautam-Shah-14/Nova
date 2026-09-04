# Design — Nova (Mobile AI Companion, Android)

## Scope
Personal use, sideloaded on your own device. Background service only — no app
screens. A status icon (your image if supplied at build time, otherwise a
colored dot) is the entire visible surface. WhatsApp messaging limited to a
small, known allow-list of contacts.

## Tech Stack

| Layer | Choice | Why |
|---|---|---|
| App shell | Flutter (matches your GetX/Hive stack) | Fastest for you to build/maintain; no screens needed, just service bootstrapping |
| Background execution | Android foreground service | Required by Android for any persistent mic/LLM activity — comes with a mandatory notification, no way to hide it |
| Status indicator | Notification icon + floating overlay dot (`SYSTEM_ALERT_WINDOW`) | Two render targets, one state source |
| Wake word | openWakeWord (or Porcupine Android SDK), phrase: "Wake Up" | On-device, low battery cost at idle |
| Speech-to-text | whisper.cpp mobile build (tiny/base) | On-device, no cloud |
| **LLM (primary)** | **Qwen2.5-3B-Instruct, GGUF, Q4_K_M (~1.9GB)** | Best structured-JSON reliability at this size — matters since the dispatcher depends on clean JSON, not prose |
| **LLM (fallback)** | **Llama-3.2-1B-Instruct, Q4_K_M (~700MB)** | For lower-RAM devices; weaker on complex multi-step intents but fine for a 5-10 skill vocabulary |
| LLM runtime | llama.cpp Android bindings | More mature Android deploy path than MLC-LLM right now; revisit MLC-LLM later for GPU speed once core loop is proven |
| TTS | Piper, fine-tuned/few-shot on your recorded voice | On-device, low latency |
| Multi-app access | Android Accessibility Service, one generic driver reused across apps (Gmail, WhatsApp, any other installed app) | No APIs/OAuth needed — Nova reads/taps the app UI directly, same mechanism for everything |
| App opening | Generic intent resolution against the device's installed package list | Works for any app, no per-app hardcoding |
| Reasoning | `reasoning_engine.dart` — short stated rationale before acting, flags irreversible actions for confirmation | Sits between intent parsing and dispatch, not just personality flavor — actually gates risky actions |
| Local storage | Hive | Consistent with your existing stack |
| Task handling | FIFO queue + single worker loop | Supports commands stacking up while one is still executing |

## Feature List

### Phase 1 — Core loop
- Foreground service, no UI screens
- Status icon: green (available) / yellow (working) / red (sleeping) — custom
  image used if present at build time, else a generated dot
- "Wake Up" → chime/haptic confirms heard → enqueued
- Task queue worker: STT → LLM → dispatcher → skill → TTS, one at a time, FIFO
- 3-5 starter skills: battery, open app, flashlight, volume, note-to-self

### Phase 2 — Multi-app integrations
- **Battery/system controls** — trivial, standard APIs
- **Open any app** — generic intent resolution against the device's installed
  package list; you say the app name, Nova resolves and launches it, no
  per-app entry needed upfront
- **Gmail** — no API/OAuth: Accessibility Service reads/drives the Gmail app
  UI directly, the same mechanism as WhatsApp below. Honest trade-off vs. the
  official API: more fragile if Gmail's UI layout changes, and "send" actions
  specifically route through the reasoning engine's confirmation step, since
  a UI tap can't be validated the way a structured API call can
- **Chrome** — open URL / trigger search via Intents; reading Chrome's saved
  profile/history isn't achievable on Android regardless of permissions (sandboxed)
- **WhatsApp** — Accessibility Service reads/drives the WhatsApp UI (no official
  personal-use API exists). Scoped for your case:
  - Enabled once, manually, via Android Settings — Google requires explicit user grant
  - Dispatcher enforces a **hard allow-list** of your known contacts, independent
    of what the LLM outputs — a misheard name can't send outside that list
  - Fine for personal sideloaded use; wouldn't pass Play Store review without a
    justification case, and isn't something WhatsApp's ToS loves — non-issue at
    your current scale, just worth knowing if this ever grows beyond personal use
- **Any other app** — same generic Accessibility driver (`app_control_skill.dart`)
  reused rather than building a one-off integration per app
- **Meeting recording** (in-browser Meet) — `MediaProjection` capture, then an
  upload skill sends it wherever you specify (Drive, email, etc.). Consent-law
  note carries over from the desktop doc — worth a beat of thought before every
  call auto-records, even at small scale

### Phase 2.5 — Reasoning before action
Nova doesn't go straight from parsed intent to execution. A reasoning step
sits in between:
- States a short rationale for the chosen action (mainly useful for your own
  debugging/trust in early builds — doesn't need to be spoken aloud every time)
- Classifies the action as reversible (open app, check battery, read something)
  or irreversible (send message, send email, delete something)
- Irreversible actions require a lightweight confirmation before the skill
  actually executes — e.g. Nova states what it's about to send and to whom,
  and either a short spoken "yes"/"confirm" or a brief pause-and-proceed
  window, your call which — before committing
- This is also where a misheard WhatsApp contact name would get caught even
  before it hits the allow-list check

### Phase 3 — Personality polish
- Stark-attitude system prompt: sharp, dry, economical, calls you by name
  occasionally — shared verbatim with the desktop build so both feel like one
  continuous assistant, under the same name, Nova

## Status Icon Logic

```
Build time:
  if assets/icon/status.png exists -> bake into APK, tint per state
  else -> use generated colored dot (no asset needed)

Runtime states:
  AVAILABLE (green)  — queue empty, listening for wake word
  WORKING (yellow)   — queue non-empty; stays yellow across a whole
                        backlog of stacked commands, not just one task
  SLEEPING (red)     — listening paused (screen-off idle timeout, or
                        manual pause)
```

## Prompt Queue Behavior
- Each wake-word trigger pushes a task onto a FIFO queue rather than running immediately
- A single worker loop drains it one task at a time: STT → LLM → dispatcher → skill → TTS
- Icon reflects the whole queue's state, not per-task — one continuous "working"
  signal even across several stacked commands
- Optional safety net: cap the queue (e.g. 5 pending) and have Nova say "hold on,
  catching up" via TTS if commands stack faster than it can process, so a burst
  never feels like it silently dropped one

## Personality System Prompt

```
You are Nova, [Name]'s personal AI companion. Tone: sharp, witty, quietly
confident, economical with words — you respect the user's time and
intelligence. Dry humor over enthusiasm. You call the user by name
occasionally, not every line. You never pad responses with filler or
apologize excessively. When a command is ambiguous, you ask ONE crisp
clarifying question instead of guessing.

Before acting, briefly reason: what is the user actually asking for, which
skill matches, and is this action reversible or not. For irreversible actions
(sending a message/email, deleting something), state what you're about to do
and wait for confirmation before executing — don't skip this step even if the
command sounded clear.

You always output your action as JSON matching the provided skill schema —
no prose mixed into that output, aside from the stated reasoning/confirmation
step where applicable.
```

## Battery & Performance Reality Check
Always-on wake-word listening + a foreground service is the biggest battery cost.
- Wake word models are tiny (~1MB) — the *service staying alive* costs more than
  the listening itself
- Auto-pause (go to `sleeping`/red) on screen-off + idle timeout, re-arm on unlock
- Run LLM inference only on wake-word trigger, never speculatively

## Suggested Build Order
1. Foreground service + status icon (green/yellow/red) + wake word — validates
   the hardest platform-specific piece first
2. Task queue + whisper + Qwen2.5-3B + dispatcher with 3 dummy skills
3. Swap in your status icon image + voice model
4. Battery/system skills + generic app-open intent resolution
5. Reasoning engine (rationale + reversibility check + confirmation flow)
6. Generic Accessibility driver (`app_control_skill.dart`)
7. Gmail on top of the generic driver
8. WhatsApp send-to-allowlist on top of the generic driver
9. Meeting capture + upload
