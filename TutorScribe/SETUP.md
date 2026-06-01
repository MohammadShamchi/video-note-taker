# TutorScribe — setup

A native macOS menu bar app that does the `note-live.js` pipeline (live system
audio → Whisper → GPT notes → local markdown) and pushes a session to Notion via
a real OAuth popup. Connectors are pluggable — Notion ships now, other apps drop
in by conforming to the `Connector` protocol.

All Swift source lives in this `TutorScribe/` folder. You create the Xcode app
shell; everything else is here ready to add.

## 1. Create the Xcode project

1. Xcode → **File ▸ New ▸ Project ▸ macOS ▸ App**.
2. Product name **TutorScribe**, Interface **SwiftUI**, Language **Swift**.
3. Save it anywhere (e.g. inside this repo). Delete the auto-generated
   `ContentView.swift` and the generated `TutorScribeApp.swift` (this folder has its own).
4. **Deployment target: macOS 14.0** (`MenuBarExtra` needs 13, `SettingsLink` needs 14).

## 2. Add the source

Drag the `App`, `UI`, `Capture`, `Pipeline`, `Connectors`, and `Support` folders
into the project navigator (check *Copy items if needed* and add to the
TutorScribe target).

## 3. Target settings — already configured

These are set in the project (`project.pbxproj`), no action needed:

- `INFOPLIST_KEY_LSUIElement = YES` — menu-bar-only app, no dock icon.
- `ENABLE_APP_SANDBOX = NO` — so the app can run the `ffmpeg` binary.

The OAuth `tutorscribe://` redirect does **not** need an Info.plist URL Type —
`ASWebAuthenticationSession` captures the callback itself.

## 4. External requirements (same as the CLI)

```bash
brew install ffmpeg blackhole-2ch
```

Then Audio MIDI Setup → create a Multi-Output Device (Built-in Output +
BlackHole 2ch) and select it as the system output, so the app can hear playback.

## 5. Run from Xcode

Build & run. A waveform icon appears in the menu bar.

- **Settings (⌘,):** paste your OpenAI API key.
- Click **Start Transcript**, play a tutorial → segment count climbs and
  `~/tutorial_notes.md` / `~/tutorial_transcript.md` grow (same format as the CLI).
- **Stop**, then **Push to Notion**.

## 6. Install for personal use

After the app builds from Xcode once, you can install and run a Release build
without opening Xcode:

```bash
npm run macos:install
```

This installs the app to `~/Applications/TutorScribeApp.app`. You can launch it
from Finder, Spotlight, or:

```bash
open ~/Applications/TutorScribeApp.app
```

To create a simple personal DMG:

```bash
npm run macos:dmg
```

The DMG is written to `dist/TutorScribeApp.dmg`. This is for personal use only:
it is not Developer ID signed, notarized, or ready for public distribution.

## 7. Notion OAuth

1. Create an integration at <https://www.notion.com/my-integrations> →
   **New integration ▸ Public** (OAuth). Add redirect URI **`tutorscribe://oauth`**.
2. In Settings ▸ Connectors ▸ Notion, paste the **Client ID** and **Client Secret**,
   click **Connect** → the OAuth popup opens; authorize and pick which pages to share.
3. Choose a **Parent page** (the picker lists pages the integration can access).
4. **Push to Notion** creates a page there with the session's summary, notes, and
   full transcript.

**Redirect fallback:** Notion may reject custom-scheme redirects for some
integrations. If `Connect` fails on the redirect, switch `Config.notionRedirectURI`
to a loopback (`http://127.0.0.1:<port>/callback`), register that URI in Notion,
and run a tiny local listener to capture the `code` (replace the
`ASWebAuthenticationSession` call in `NotionConnector.authenticate()`).

## Notes

- The embedded client secret (Keychain-stored) is fine for personal use, not for
  App Store distribution.
- v1 is live-audio only. File import and additional connectors are deliberately deferred.
