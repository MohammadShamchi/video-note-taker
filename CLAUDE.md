# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A zero-build Node.js CLI that transcribes tutorial videos (live browser audio or local files) via OpenAI Whisper, turns the transcript into bullet notes via a GPT model, and optionally exports to Notion. Three standalone scripts, no framework, no database, no daemon. The only runtime dependency is `dotenv`.

## Commands

```bash
npm install                                    # installs dotenv only
node scripts/note-live.js                      # live mode (macOS) — auto-detects BlackHole
node scripts/note-live.js --device 2           # manual avfoundation device index
node scripts/note-from-file.js <path>          # file mode (any OS) — mp4/mkv/mov/mp3/wav/m4a/webm
node scripts/push-to-notion.js "Title"         # prepare Notion payload from last session

npm run live | npm run file -- <path> | npm run push-notion -- "Title"
```

There is no build step, no linter, and no test suite. Verify changes by running the scripts directly.

## External requirements

- **Node ≥ 18** — scripts rely on the built-in global `fetch`, `FormData`, and `File`. Do not add `node-fetch` or `form-data`.
- **ffmpeg / ffprobe** on PATH — all audio capture, extraction, chunking, and duration probing shell out to these.
- **BlackHole 2ch** — live mode only, macOS only. Captured via `ffmpeg -f avfoundation`.
- **OPENAI_API_KEY** in `.env` (loaded from project root, not cwd). Optional overrides: `NOTES_FILE`, `TRANSCRIPT_FILE`, `CHUNK_SECS`, `NOTES_MODEL`.

## Architecture notes

**Three independent scripts, no shared module.** `whisperTranscribe()` and `generateNotes()` are duplicated near-verbatim in `note-live.js` and `note-from-file.js`. A change to the API call shape, model params, or note prompt usually needs applying in both. There is intentionally no `lib/` — keep each script self-contained.

**Output goes to the home directory, not the repo.** Defaults are `~/tutorial_notes.md` and `~/tutorial_transcript.md`. Paths from `.env` are tilde-expanded manually via `.replace('~', os.homedir())`, so only a leading `~` works.

**The three scripts are coupled through markdown text conventions, not data structures:**
- Note/transcript files are segmented with `## Segment N — <time>` headings and separated across runs by `---\n\n_New session: <stamp>_` blocks.
- `push-to-notion.js#readLastSession` recovers the latest run by splitting on `/---\n\n_(?:New session|Started):/`, then `buildNotionContent` re-parses segments by splitting on `\n## `. If you change a heading format or session delimiter in the note scripts, update this parser or the Notion export silently breaks.

**`push-to-notion.js` does not call Notion.** It writes a payload to `~/.notion_push_payload.json` and prints "Tell Claude: push to Notion". The actual page creation is expected to happen through the Notion MCP in a Claude session — so when the user says "push to Notion" after running it, read that JSON and create the page via the Notion tools.

**Live mode specifics (`note-live.js`):** infinite record→transcribe→note loop writing 16kHz mono WAV chunks to a temp dir. SIGINT flushes and exits; `recordChunk._proc` holds the active ffmpeg child so the handler can `SIGTERM` it (ffmpeg exit code `255` from that kill is treated as success). Chunks under ~0.005MB or transcripts under `MIN_WORDS` (15) are skipped to avoid spending API calls on silence. A note result of `-` means "nothing noteworthy" and is dropped from notes but the transcript is still saved.

**File mode specifics (`note-from-file.js`):** `ffprobe` gets duration, then audio is extracted as 15-min mono 64k mp3 chunks (sized to stay under Whisper's 25MB upload limit). Each chunk is transcribed and noted independently; multi-chunk videos get an extra overall-summary pass on the first 8000 chars of the combined transcript.
