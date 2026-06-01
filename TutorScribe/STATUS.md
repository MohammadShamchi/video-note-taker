# TutorScribe — status and path to publish-ready

Last updated: 2026-06-01. Branch: `codex/live-transcription-reliability`.

## What this is

A native macOS menu bar app that captures live system audio, transcribes it
(OpenAI Whisper), turns it into bullet notes (GPT), saves to local markdown, and
pushes a session to Notion. It is a native port of the existing Node CLI
(`scripts/note-live.js`), reusing the same prompts, models, and file format.

## What is built and working (today)

| Area | State | Notes |
|------|-------|-------|
| Menu bar app shell | Done | SwiftUI `MenuBarExtra`, dock-less agent (`LSUIElement`). No 3rd-party deps. |
| Live audio capture | Done | `ffmpeg` + BlackHole, chunked WAV. Verified capturing from device. |
| Whisper transcription | Done | Native multipart upload, same as CLI. |
| GPT notes | Done | Same prompt/model (`gpt-4o-mini`) as CLI. |
| Local output | Done | `~/tutorial_notes.md` / `_transcript.md`, identical markdown to CLI. |
| Stop/drain lifecycle | Done | Stop flushes active recording and drains queued chunks before reporting idle. Build verified; full installed-app live run still pending. |
| Notion connector | Done | Access-token auth; creates one sub-page per session. Verified end to end. |
| Connector protocol | Done | Pluggable; other apps add by conforming + one Settings row. |
| Secrets | Done | Keychain (OpenAI key, Notion token). |
| Settings UI | Done | API key, model, chunk size, Notion connect + parent-page picker. |
| Build config | Done | Sandbox off (for ffmpeg), mic usage string, macOS 14.0 deployment target. |
| Personal install | Done | `npm run macos:install` builds Release and installs to `~/Applications/TutorScribeApp.app`. |
| Personal DMG | Done | `npm run macos:dmg` creates a simple local DMG at `dist/TutorScribeApp.dmg`. |

**Verified:** build succeeds; Notion push creates a real page; ffmpeg captures
from BlackHole. On 2026-06-01, `npm run macos:build`, `npm run macos:dmg`, and
`npm run macos:install` succeeded; the app is installed at
`~/Applications/TutorScribeApp.app`, and `hdiutil verify dist/TutorScribeApp.dmg`
passes. On 2026-06-01, the reliability branch also built successfully after
adding queue/drain processing and transcript-first writes. **Not yet confirmed by
a full run:** live audio -> notes -> Notion in one go from the installed app
(pending a real play-through with mic permission granted).

This is now a solid **personal installed / developer build**: run it from Xcode
while developing, or install the Release app locally for normal day-to-day use.
It is not yet something an ordinary person can download and use.

## The honest gap to "publish-ready for everyone"

Four things make the current build developer-only. Each is real work.

### 1. The BlackHole + ffmpeg dependency (biggest blocker)
Today a user must `brew install ffmpeg blackhole-2ch`, reboot, create a
Multi-Output Device, and route their audio. No normal user will do this.

Publish-ready means removing it:
- **Replace BlackHole** with native system-audio capture via **ScreenCaptureKit**
  (`SCStream` audio, macOS 13+). No virtual driver, no routing. This is a rewrite
  of the `Capture/` layer.
- **Bundle ffmpeg** inside the app (or drop it once ScreenCaptureKit gives PCM we
  encode natively), so nothing is installed separately.

Estimated effort: ~2-4 days.

### 2. Code signing, notarization, distribution
- Needs an **Apple Developer account** ($99/yr).
- Sign with **Developer ID** + **notarize** so Gatekeeper lets others open it.
  Ship as a `.dmg`.
- **Mac App Store is effectively out** unless we re-architect: MAS requires the
  sandbox, which forbids the ffmpeg subprocess. Direct distribution (Developer ID)
  allows the current design, so that is the realistic route.
- Add **auto-update** (Sparkle) for direct distribution.

Estimated effort: ~1-2 days once the account exists.

### 3. Auth and keys for non-developers
- **OpenAI key:** simplest public model is **bring-your-own-key** (what we have).
  A hosted proxy where you pay for everyone needs a backend, billing, auth, and
  abuse limits — a separate project. Recommend BYO-key for v1.
- **Notion:** access token is a manual paste. A polished "Connect" button needs
  **OAuth** (the popup we built then shelved — the code is still in
  `NotionConnector.authenticate()`, dormant). For public release, revive OAuth.

Estimated effort: OAuth revival ~1 day; BYO-key needs nothing.

### 4. Product polish (required for a real release)
- App icon (currently the default).
- First-run onboarding: explain mic permission, audio capture, where to get an
  OpenAI key.
- A **privacy policy** (mandatory: the app records audio and sends it to OpenAI).
- Cost transparency (Whisper + GPT cost per hour of audio).
- Basic tests; graceful handling of expired tokens, rate limits, offline.

Estimated effort: ~2-3 days.

## Suggested phases

- **Phase 0 — Personal use (DONE).** Works from Xcode with your keys.
- **Phase 0.5 — Personal installed app (DONE).** Builds a Release `.app`,
  installs it to `~/Applications`, and can create a simple unsigned personal
  `.dmg`. This avoids opening Xcode for daily use.
- **Phase 1 — Shareable with friends.** Sign + notarize a `.dmg`, bundle ffmpeg,
  add an icon and a minimal first-run screen. Still uses BlackHole. ~2-3 days.
- **Phase 2 — No-setup capture.** ScreenCaptureKit replaces BlackHole. This is the
  step that makes it usable by anyone. ~2-4 days.
- **Phase 3 — One-click Notion.** Revive OAuth so users just click Connect. ~1 day.
- **Phase 4 — Public release.** Website/landing, auto-update, privacy policy,
  support email. ~2-3 days.

Realistic total to a genuine public 1.0: **~2-3 weeks** of focused work, dominated
by Phase 2 (capture rewrite) and the Apple Developer / notarization setup.

## Decisions

1. **Distribution: DECIDED -> Developer ID `.dmg`.** Sign + notarize, keep the
   current (unsandboxed, ffmpeg-based) design. Needs an Apple Developer account.
   For personal use only, use the unsigned local install/DMG scripts.
2. **Keys:** open — bring-your-own OpenAI key (recommended, no backend) vs hosted
   proxy you pay for.
3. **Capture:** open — commit to the ScreenCaptureKit rewrite (removes BlackHole),
   the single highest-leverage change for public use.

## Current state: PERSONAL-INSTALL READY (2026-06-01)

Phase 0.5 is implemented for personal use. Generated app bundles, DMGs, and
DerivedData live under ignored `dist/` and `build/` directories.

Personal commands:

```bash
npm run macos:install   # builds Release and installs ~/Applications/TutorScribeApp.app
npm run macos:dmg       # builds Release and creates dist/TutorScribeApp.dmg
```

**Next high-leverage product task:** Phase 2 (ScreenCaptureKit capture). The one
loose end from Phase 0 is confirming a full live run from the installed app,
including Stop during active speech and final queued-chunk processing.

## Where the code lives

- App: `TutorScribeApp/` (Xcode project, synchronized-folder format).
- Source groups: `App`, `UI`, `Capture`, `Pipeline`, `Connectors`, `Support`.
- Reference: `TutorScribe/SETUP.md`, `Info.plist`, `TutorScribe.entitlements`.
