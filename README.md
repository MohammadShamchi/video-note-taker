# AI Tutorial Notes

> Automatically transcribe and take AI-powered notes from any tutorial video — live streams or local files — using OpenAI Whisper + GPT-4o-mini, with optional Notion export.

---

## Why I built this

I was going through the [Zero to Mastery](https://zerotomastery.io/) job hunting course and ran into a problem I'd had a dozen times before: the instructor is talking fast, I'm trying to keep up, I pause the video to write something down, I miss the next point, I fall behind, I stop taking notes altogether — and two days later I remember almost nothing.

I didn't want to buy another note-taking app or subscribe to a transcription service. I just wanted something that sat quietly in the background, listened to whatever I was watching, and handed me clean notes when I was done.

So I built it in a single afternoon.

The original plan was to use [Screenpipe](https://github.com/mediar-ai/screenpipe) as the audio capture layer — it runs locally, routes everything through Whisper, and seemed perfect. I spent a good chunk of time debugging it before discovering the core issue: Screenpipe's speaker-diarization models (`wespeaker_en_voxceleb_CAM++.onnx`) are stored in GitHub via Git LFS, but the download URLs serve **pointer files** (307 KB) instead of the actual models (~50 MB). Every audio recording thread crashes on parse failure, restarts, and within minutes you have 20+ concurrent threads fighting over a locked SQLite database.

Rather than patch Screenpipe, I cut it out entirely and built a simpler, more reliable pipeline:

```
Browser audio → BlackHole (virtual cable) → ffmpeg (60s chunks)
             → OpenAI Whisper API → GPT-4o-mini → Markdown notes
```

Three scripts, no database, no background daemon, no SaaS dependency beyond an OpenAI API key.

---

## What it does

| Script | Use case |
|--------|----------|
| `note-live.js` | Watch any online video (YouTube, Udemy, ZTM, Coursera…) and get notes every 60 seconds |
| `note-from-file.js` | Point it at a local mp4/mp3/mov file and get a full transcript + notes + summary |
| `push-to-notion.js` | Export the latest session to a structured Notion page |

Both live and file modes produce these files:

- **`~/tutorial_notes.md`** — AI-generated bullet points, one section per minute
- **`~/tutorial_transcript.md`** — full verbatim transcript with timestamps, so you can go back and verify anything
- **`~/TutorScribe/transcripts/<date>-<topic>.md`** — a per-session copy of the transcript, named after the topic inferred from the audio (e.g. `2026-06-01-21-30-react-hooks-deep-dive.md`). It opens with a `# Topic` heading and a `_Created: …_` timestamp, so past sessions are easy to find on disk. The two files above are still written unchanged for backward compatibility.

---

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│  LIVE MODE (browser video)                                   │
│                                                              │
│  Browser → Multi-Output Device → BlackHole 2ch              │
│         ↓                                                    │
│     ffmpeg records 60s WAV chunks                            │
│         ↓                                                    │
│     OpenAI Whisper API  (speech → text, ~$0.006/min)        │
│         ↓                                                    │
│     GPT-4o-mini         (text → bullet notes)               │
│         ↓                                                    │
│     tutorial_notes.md + tutorial_transcript.md               │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  FILE MODE (local video)                                     │
│                                                              │
│  video.mp4 → ffmpeg strips audio → 15-min mp3 chunks        │
│           → Whisper per chunk → GPT-4o-mini notes           │
│           → final summary                                   │
│           → tutorial_notes.md + tutorial_transcript.md       │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Why | Install |
|------|-----|---------|
| **Node.js ≥ 18** | Runs the scripts (uses built-in `fetch` and `FormData`) | [nodejs.org](https://nodejs.org) |
| **ffmpeg** | Records audio chunks / extracts audio from files | `brew install ffmpeg` |
| **BlackHole 2ch** | Virtual audio cable — lets ffmpeg record system audio while you still hear it | `brew install blackhole-2ch` |
| **OpenAI API key** | Whisper transcription + GPT-4o-mini note generation | [platform.openai.com](https://platform.openai.com/api-keys) |

> **Platform note:** Live mode is macOS only (BlackHole is macOS-specific). File mode works on any OS with Node.js + ffmpeg.

---

## Installation

```bash
git clone https://github.com/your-username/ai-tutorial-notes
cd ai-tutorial-notes
npm install
cp .env.example .env
# Open .env and add your OPENAI_API_KEY
```

---

## One-time audio setup (live mode only)

BlackHole creates a virtual audio device so ffmpeg can record what plays through your speakers — without you losing the sound.

**1. Install and reboot**

```bash
brew install blackhole-2ch
# A reboot is required for the audio driver to activate
```

**2. Create a Multi-Output Device**

Open **Audio MIDI Setup** (Spotlight → "Audio MIDI Setup"):
- Click `+` (bottom-left) → "Create Multi-Output Device"
- In the right panel, tick both:
  - `☑ Built-in Output` — so you still hear audio normally
  - `☑ BlackHole 2ch` — so ffmpeg can capture it

**3. Set it as your system output**

System Settings → Sound → Output → **Multi-Output Device**

**4. Confirm detection**

```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i black
# Expected output: [1] BlackHole 2ch  (index may vary)
```

**When your study session is over**, revert:
System Settings → Sound → Output → **Built-in Output**

---

## Usage

### Live mode

```bash
node scripts/note-live.js
# or
npm run live
```

Open your tutorial in the browser and press play. Every 60 seconds:
1. ffmpeg stops recording and saves a WAV chunk
2. Whisper transcribes it
3. GPT-4o-mini generates bullet-point notes
4. Both raw transcript and notes are appended to their files

Press `Ctrl+C` when the video ends — any remaining audio is processed before exit.

```
note-live.js
─────────────────────────────────────────
Audio device : BlackHole 2ch (index 1)
Chunk size   : 60s
Notes        : ~/tutorial_notes.md
Transcript   : ~/tutorial_transcript.md
─────────────────────────────────────────
Play your video. Press Ctrl+C when done.

  [9:01:05 PM] Recording 60s... done.   Transcribing... 57 words. Generating notes... ✓ saved
  [9:02:20 PM] Recording 60s... done.   Transcribing... 163 words. Generating notes... ✓ saved
  [9:03:29 PM] Recording 60s... done.   Transcribing... 148 words. Generating notes... ✓ saved
```

**Manual device override** (if auto-detect fails):

```bash
node scripts/note-live.js --device 2
```

---

### File mode

```bash
node scripts/note-from-file.js ~/Downloads/tutorial.mp4
# or
npm run file -- ~/Downloads/lecture.mp4
```

Supports any ffmpeg-compatible format: mp4, mkv, mov, mp3, wav, m4a, webm.
Files longer than ~50 minutes are automatically split into 15-minute chunks and processed in order, with an overall summary at the end.

Like live mode, file mode writes **`~/tutorial_notes.md`** (AI bullet notes per segment, plus an overall summary for multi-chunk videos), **`~/tutorial_transcript.md`** (the full verbatim transcript, one section per chunk), and a topic-named per-session copy under **`~/TutorScribe/transcripts/`**.

---

### Export to Notion

After watching, run:

```bash
node scripts/push-to-notion.js                      # uses the inferred session topic as the title
# or override the title:
node scripts/push-to-notion.js "ZTM - Land Your Dream Job"
npm run push-notion -- "Your course name here"
```

This builds a structured Notion page payload with an AI-generated summary. If you have the Notion MCP connected in Claude, just say **"push to Notion"** and it creates the page (as a sub-page of the connected parent) automatically.

When no title argument is given, the page name defaults to the **inferred session topic** (the same topic used to name the per-session transcript file). A passed title always overrides it.

The Notion page structure:
- 📋 AI session summary at the top
- 📝 Notes organised by time segment
- 🎙 Full raw transcript (in a separate section for reference)

---

## Configuration

All options live in `.env`:

```env
# Required
OPENAI_API_KEY=sk-proj-...

# Optional — output file locations (the compatibility files)
# A topic-named per-session transcript copy is always also written to
# ~/TutorScribe/transcripts/<date>-<topic>.md regardless of these overrides.
NOTES_FILE=~/tutorial_notes.md
TRANSCRIPT_FILE=~/tutorial_transcript.md

# Optional — recording chunk duration in seconds (default: 60)
CHUNK_SECS=60

# Optional — GPT model (default: gpt-4o-mini)
# Use gpt-4o for richer, more detailed notes at higher cost
NOTES_MODEL=gpt-4o-mini
```

---

## Output example

**`tutorial_notes.md`**
```markdown
# Tutorial Notes

_Session started: 31 May 2026, 21:01_

---

## Segment 1 — 9:02:20 PM

**Job Hunting Mindset**
- Internalise the four laws — keep them at the forefront throughout the process
- Treat progress like walking through fog: keep moving even when you can't see far ahead

## Segment 2 — 9:03:29 PM

**Presenting Yourself**
- Lead with your best self on resumes — no misrepresentation, but no underselling either
- Getting hired is step one; learning on the job is expected and normal
```

**`tutorial_transcript.md`**
```markdown
# Tutorial Transcript

_Session started: 31 May 2026, 21:01_

---

## Segment 1 — 9:02:20 PM

Welcome back everyone so in this section what we're going to cover
is the four laws of landing your dream job and I want you to really
internalise these because they're going to come up again and again...
```

---

## Cost estimate

| Session length | Whisper | GPT-4o-mini | Total |
|----------------|---------|-------------|-------|
| 30 min | ~$0.09 | ~$0.02 | **~$0.11** |
| 1 hour | ~$0.18 | ~$0.04 | **~$0.22** |
| 8 hours | ~$1.44 | ~$0.30 | **~$1.74** |

Rates: Whisper $0.006/min · GPT-4o-mini $0.15/1M input tokens.

---

## Troubleshooting

**BlackHole not detected**
Make sure you rebooted after install. Find the index manually:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i black
node scripts/note-live.js --device 2
```

**Empty transcriptions / no words detected**
- Confirm Multi-Output Device is set as system output in Sound settings
- Make sure the video volume is audible — Whisper needs a clear signal

**`OPENAI_API_KEY is not set`**
- Run `cp .env.example .env` and fill in your key
- Run scripts from the project root directory

**Notes feel too shallow**
Switch to a stronger model in `.env`:
```env
NOTES_MODEL=gpt-4o
```

---

## Project structure

```
ai-tutorial-notes/
├── scripts/
│   ├── note-live.js          # Live mode — any browser video
│   ├── note-from-file.js     # File mode — local video/audio
│   └── push-to-notion.js     # Notion export
├── .env                      # Your keys — never committed
├── .env.example              # Template for new users
├── .gitignore
├── package.json
└── README.md
```

---

## Ideas for extension

- **Windows/Linux support** — replace BlackHole + avfoundation with platform-native audio capture (VB-Audio on Windows, PulseAudio monitor on Linux)
- **Obsidian export** — write directly into your vault folder
- **Auto-title from browser tab** — use AppleScript to read the active tab title and name the session automatically
- **Live web UI** — show transcript and notes side-by-side as they generate in real time
- **Speaker detection** — integrate working diarization models for multi-speaker sessions

---

## License

MIT — use it, fork it, build on it.
