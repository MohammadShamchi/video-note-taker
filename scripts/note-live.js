#!/usr/bin/env node
/**
 * note-live.js
 * Real-time AI note-taker for any online video (browser, streaming platforms).
 *
 * How it works:
 *   Browser audio → BlackHole (virtual cable) → ffmpeg (60s chunks)
 *   → OpenAI Whisper (transcription) → GPT-4o-mini (notes)
 *   → tutorial_notes.md + tutorial_transcript.md
 *
 * Prerequisites (one-time setup):
 *   1. brew install blackhole-2ch
 *   2. Reboot
 *   3. Audio MIDI Setup → Create Multi-Output Device
 *      → tick "Built-in Output" + "BlackHole 2ch"
 *   4. System Settings → Sound → Output → "Multi-Output Device"
 *
 * Usage:
 *   node scripts/note-live.js                  # auto-detect BlackHole
 *   node scripts/note-live.js --device 2       # manual device index
 *
 * Press Ctrl+C to stop — flushes any remaining audio before exit.
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { execSync, spawn } = require('child_process');
const fs   = require('fs');
const path = require('path');
const os   = require('os');

// ── Config (overridable via .env) ─────────────────────────────────────────────
const OPENAI_API_KEY  = process.env.OPENAI_API_KEY;
const OUTPUT_FILE     = process.env.NOTES_FILE
  ? path.resolve(process.env.NOTES_FILE.replace('~', os.homedir()))
  : path.join(os.homedir(), 'tutorial_notes.md');
const TRANSCRIPT_FILE = process.env.TRANSCRIPT_FILE
  ? path.resolve(process.env.TRANSCRIPT_FILE.replace('~', os.homedir()))
  : path.join(os.homedir(), 'tutorial_transcript.md');
const CHUNK_SECS      = parseInt(process.env.CHUNK_SECS || '60', 10);
const MODEL           = process.env.NOTES_MODEL || 'gpt-4o-mini';
const MIN_WORDS       = 15;
const TMP_DIR         = fs.mkdtempSync(path.join(os.tmpdir(), 'live-notes-'));
// ─────────────────────────────────────────────────────────────────────────────

if (!OPENAI_API_KEY) {
  console.error('\n  ERROR: OPENAI_API_KEY is not set.');
  console.error('  Copy .env.example to .env and add your key.\n');
  process.exit(1);
}

let totalSegments  = 0;
let isShuttingDown = false;

// ── Device detection ──────────────────────────────────────────────────────────

function detectBlackholeDevice() {
  const manualIdx = process.argv.indexOf('--device');
  if (manualIdx !== -1) return process.argv[manualIdx + 1];

  try {
    const out = execSync(
      'ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true',
      { encoding: 'utf8' }
    );
    for (const line of out.split('\n')) {
      const m = line.match(/\[(\d+)\]\s+BlackHole/i);
      if (m) return m[1];
    }
  } catch {}
  return null;
}

// ── OpenAI helpers ────────────────────────────────────────────────────────────

async function whisperTranscribe(audioPath) {
  const buf      = fs.readFileSync(audioPath);
  const formData = new FormData();
  formData.append('file', new File([buf], 'audio.wav', { type: 'audio/wav' }));
  formData.append('model', 'whisper-1');
  formData.append('response_format', 'text');

  const res = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}` },
    body: formData,
  });
  if (!res.ok) throw new Error(`Whisper ${res.status}: ${await res.text()}`);
  return (await res.text()).trim();
}

async function generateNotes(transcript) {
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0.3,
      messages: [
        {
          role: 'system',
          content: `You are a concise note-taker for tutorial videos.
Extract from the transcript:
- Key concepts introduced
- Steps, techniques, or workflows explained
- Specific commands, code, file names, or values mentioned
- Tips or warnings from the instructor

Bullet points under a short bold heading. Skip filler and repetition.
If nothing useful, reply with just a dash "-".`,
        },
        { role: 'user', content: transcript },
      ],
    }),
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${await res.text()}`);
  const json = await res.json();
  return json.choices[0].message.content.trim();
}

// ── Recording ─────────────────────────────────────────────────────────────────

function recordChunk(deviceIdx, outPath) {
  return new Promise((resolve, reject) => {
    const args = [
      '-y', '-f', 'avfoundation', '-i', `:${deviceIdx}`,
      '-t', String(CHUNK_SECS), '-ar', '16000', '-ac', '1', outPath,
    ];
    const proc = spawn('ffmpeg', args, { stdio: 'ignore' });
    proc.on('close', code => (code === 0 || code === 255 ? resolve() : reject(new Error(`ffmpeg exit ${code}`))));
    proc.on('error', reject);
    recordChunk._proc = proc;
  });
}
recordChunk._proc = null;

// ── Processing ────────────────────────────────────────────────────────────────

async function processChunk(audioPath) {
  const sizeMB = (fs.statSync(audioPath).size / 1024 / 1024).toFixed(2);
  if (parseFloat(sizeMB) < 0.005) {
    process.stdout.write('  (silence — skipped)\n');
    return;
  }

  process.stdout.write('  Transcribing...');
  let transcript;
  try {
    transcript = await whisperTranscribe(audioPath);
  } catch (e) {
    console.log(` failed: ${e.message}`);
    return;
  }

  const words = transcript.split(/\s+/).filter(Boolean).length;
  if (words < MIN_WORDS) {
    process.stdout.write(` (only ${words} words — skipped)\n`);
    return;
  }
  process.stdout.write(` ${words} words. Generating notes...`);

  let notes;
  try {
    notes = await generateNotes(transcript);
  } catch (e) {
    console.log(` failed: ${e.message}`);
    return;
  }

  // Always save raw transcript
  const time = new Date().toLocaleTimeString();
  totalSegments++;
  fs.appendFileSync(TRANSCRIPT_FILE, `\n## Segment ${totalSegments} — ${time}\n\n${transcript}\n`);

  if (notes === '-') {
    process.stdout.write(' (nothing noteworthy)\n');
    return;
  }

  fs.appendFileSync(OUTPUT_FILE, `\n## Segment ${totalSegments} — ${time}\n\n${notes}\n`);
  console.log(' ✓ saved');
}

// ── Graceful shutdown ─────────────────────────────────────────────────────────

process.on('SIGINT', async () => {
  if (isShuttingDown) return;
  isShuttingDown = true;
  if (recordChunk._proc) {
    try { recordChunk._proc.kill('SIGTERM'); } catch {}
  }
  console.log('\n\n  Stopping — processing last chunk...');
  console.log(`\n  Done! ${totalSegments} segment(s) saved.`);
  console.log(`  Notes      → ${OUTPUT_FILE}`);
  console.log(`  Transcript → ${TRANSCRIPT_FILE}\n`);
  process.exit(0);
});

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const deviceIdx = detectBlackholeDevice();

  if (!deviceIdx) {
    console.error(`
  BlackHole not found. Complete one-time setup:

    1.  brew install blackhole-2ch
    2.  Reboot
    3.  Open: Audio MIDI Setup (Spotlight search)
        → "+" → "Create Multi-Output Device"
        → tick: ☑ Built-in Output   ☑ BlackHole 2ch
    4.  System Settings → Sound → Output → "Multi-Output Device"
    5.  Get device index:
          ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i black
    6.  node scripts/note-live.js --device <INDEX>
`);
    process.exit(1);
  }

  const sessionStamp = new Date().toLocaleString();
  const initHeader   = (label) => `# Tutorial ${label}\n\n_Session started: ${sessionStamp}_\n\n---\n`;

  if (!fs.existsSync(OUTPUT_FILE)) fs.writeFileSync(OUTPUT_FILE, initHeader('Notes'));
  else fs.appendFileSync(OUTPUT_FILE, `\n\n---\n\n_New session: ${sessionStamp}_\n\n---\n`);

  if (!fs.existsSync(TRANSCRIPT_FILE)) fs.writeFileSync(TRANSCRIPT_FILE, initHeader('Transcript'));
  else fs.appendFileSync(TRANSCRIPT_FILE, `\n\n---\n\n_New session: ${sessionStamp}_\n\n---\n`);

  console.log(`
  note-live.js
  ─────────────────────────────────────────
  Audio device : BlackHole 2ch (index ${deviceIdx})
  Model        : ${MODEL}
  Chunk size   : ${CHUNK_SECS}s
  Notes        : ${OUTPUT_FILE}
  Transcript   : ${TRANSCRIPT_FILE}
  ─────────────────────────────────────────
  Play your video. Press Ctrl+C when done.
`);

  let chunkNum = 0;
  while (!isShuttingDown) {
    const outPath = path.join(TMP_DIR, `chunk_${chunkNum++}.wav`);
    process.stdout.write(`  [${new Date().toLocaleTimeString()}] Recording ${CHUNK_SECS}s...`);
    try {
      await recordChunk(deviceIdx, outPath);
      process.stdout.write(' done. ');
      await processChunk(outPath);
      try { fs.unlinkSync(outPath); } catch {}
    } catch (e) {
      if (!isShuttingDown) console.error(` error: ${e.message}`);
    }
  }
}

main().catch(e => { console.error(e.message); process.exit(1); });
