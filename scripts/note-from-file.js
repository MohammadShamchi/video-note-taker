#!/usr/bin/env node
/**
 * note-from-file.js
 * Generate AI notes from a local video or audio file.
 *
 * How it works:
 *   video/audio file → ffmpeg (extract + split audio)
 *   → OpenAI Whisper (transcription) → GPT-4o-mini (notes)
 *   → tutorial_notes.md + tutorial_transcript.md
 *
 * Usage:
 *   node scripts/note-from-file.js /path/to/tutorial.mp4
 *   node scripts/note-from-file.js ~/Downloads/lecture.mp3
 *
 * Supports any format ffmpeg handles: mp4, mkv, mov, mp3, wav, m4a, etc.
 * Files larger than 25MB are automatically split into 15-minute chunks.
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { execSync } = require('child_process');
const fs   = require('fs');
const path = require('path');
const os   = require('os');

// ── Config ────────────────────────────────────────────────────────────────────
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const OUTPUT_FILE    = process.env.NOTES_FILE
  ? path.resolve(process.env.NOTES_FILE.replace('~', os.homedir()))
  : path.join(os.homedir(), 'tutorial_notes.md');
const TRANSCRIPT_FILE = process.env.TRANSCRIPT_FILE
  ? path.resolve(process.env.TRANSCRIPT_FILE.replace('~', os.homedir()))
  : path.join(os.homedir(), 'tutorial_transcript.md');
const CHUNK_MINS     = 15;
const MODEL          = process.env.NOTES_MODEL || 'gpt-4o-mini';
const SESSION_DIR    = path.join(os.homedir(), 'TutorScribe', 'transcripts');
const TMP_DIR        = fs.mkdtempSync(path.join(os.tmpdir(), 'notes-'));
// ─────────────────────────────────────────────────────────────────────────────

if (!OPENAI_API_KEY) {
  console.error('\n  ERROR: OPENAI_API_KEY is not set.');
  console.error('  Copy .env.example to .env and add your key.\n');
  process.exit(1);
}

const inputFile = process.argv[2];
if (!inputFile) {
  console.error('  Usage: node scripts/note-from-file.js /path/to/video.mp4');
  process.exit(1);
}
const resolvedInput = inputFile.replace(/^~/, os.homedir());
if (!fs.existsSync(resolvedInput)) {
  console.error(`  File not found: ${resolvedInput}`);
  process.exit(1);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async function whisperTranscribe(audioPath) {
  const buf      = fs.readFileSync(audioPath);
  const formData = new FormData();
  formData.append('file', new File([buf], path.basename(audioPath), { type: 'audio/mpeg' }));
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

async function generateNotes(transcript, label) {
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
- Key concepts or topics introduced
- Important steps, techniques, or workflows
- Specific commands, code snippets, file names, or values mentioned
- Tips, warnings, or things to remember

Format as bullet points under a short bold heading.
If nothing useful, reply with: (nothing noteworthy)`,
        },
        { role: 'user', content: `Segment: ${label}\n\nTranscript:\n${transcript}` },
      ],
    }),
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${await res.text()}`);
  const json = await res.json();
  return json.choices[0].message.content.trim();
}

// Infer a short, human-readable topic title from transcript text. Returns '' on failure.
async function inferTranscriptTitle(transcript) {
  try {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        temperature: 0.2,
        messages: [
          { role: 'system', content: 'You title tutorial recordings. Reply with ONLY a short, human-readable title of 3-8 words describing the topic. No quotes, no trailing punctuation, no markdown.' },
          { role: 'user', content: transcript.slice(0, 4000) },
        ],
      }),
    });
    if (!res.ok) return '';
    const json = await res.json();
    return (json.choices?.[0]?.message?.content || '').trim().replace(/^["']+|["']+$/g, '');
  } catch {
    return '';
  }
}

// Filesystem-safe, stable slug: lowercase ASCII, hyphen-separated, diacritics stripped, max 80 chars.
function slugifyTitle(title) {
  const slug = (title || '')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')   // strip diacritics
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80)
    .replace(/-+$/g, '');
  return slug || 'untitled';
}

function timestampForFilename(date) {
  const p = n => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}-${p(date.getHours())}-${p(date.getMinutes())}`;
}

function transcriptHeader(title, date) {
  const created = date.toLocaleString('en-GB', {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  });
  return `# ${title}\n\n_Created: ${created}_\n\n---\n`;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n  note-from-file.js`);
  console.log(`  Input      : ${resolvedInput}`);
  console.log(`  Notes      : ${OUTPUT_FILE}`);
  console.log(`  Transcript : ${TRANSCRIPT_FILE}\n`);

  // Get duration
  let duration = 0;
  try {
    const probe = execSync(
      `ffprobe -v error -show_entries format=duration -of csv=p=0 "${resolvedInput}"`,
      { encoding: 'utf8' }
    ).trim();
    duration = parseFloat(probe);
    console.log(`  Duration : ${Math.round(duration / 60)} minutes`);
  } catch {
    console.log('  Duration : unknown (will process as single chunk)');
  }

  const chunkSecs  = CHUNK_MINS * 60;
  const numChunks  = duration > 0 ? Math.ceil(duration / chunkSecs) : 1;
  const chunkPaths = [];

  console.log(`  Chunks   : ${numChunks}\n`);

  // Extract audio chunks
  for (let i = 0; i < numChunks; i++) {
    const start   = i * chunkSecs;
    const outPath = path.join(TMP_DIR, `chunk_${i}.mp3`);
    const timeArg = duration > 0 ? `-ss ${start} -t ${chunkSecs}` : '';
    process.stdout.write(`  Extracting chunk ${i + 1}/${numChunks}...`);
    try {
      execSync(
        `ffmpeg -y ${timeArg} -i "${resolvedInput}" -vn -ar 16000 -ac 1 -b:a 64k "${outPath}" 2>/dev/null`,
        { stdio: 'ignore' }
      );
      const sizeMB = (fs.statSync(outPath).size / 1024 / 1024).toFixed(1);
      console.log(` ${sizeMB} MB`);
      chunkPaths.push(outPath);
    } catch (e) {
      console.log(` failed: ${e.message}`);
    }
  }

  // Init notes + transcript files
  const title  = path.basename(resolvedInput);
  const stamp  = new Date().toLocaleString();
  fs.mkdirSync(path.dirname(OUTPUT_FILE), { recursive: true });
  fs.mkdirSync(path.dirname(TRANSCRIPT_FILE), { recursive: true });
  fs.writeFileSync(OUTPUT_FILE, `# Tutorial Notes — ${title}\n\n_Generated: ${stamp}_\n\n---\n`);
  fs.writeFileSync(TRANSCRIPT_FILE, `# Tutorial Transcript — ${title}\n\n_Generated: ${stamp}_\n\n---\n`);

  // Per-session transcript copy with a topic-based filename, created lazily after the
  // first successful transcript chunk gives us text to infer a topic from.
  const sessionDate = new Date();
  let sessionTranscriptPath = null;

  // Transcribe + notes per chunk
  let fullTranscript = '';
  for (let i = 0; i < chunkPaths.length; i++) {
    const label = numChunks > 1 ? `${i * CHUNK_MINS}–${(i + 1) * CHUNK_MINS} min` : 'Full video';
    console.log(`\n  [${i + 1}/${chunkPaths.length}] Transcribing ${label}...`);

    let transcript;
    try {
      transcript = await whisperTranscribe(chunkPaths[i]);
      console.log(`    ${transcript.split(' ').length} words`);
    } catch (e) {
      console.error(`    Transcription failed: ${e.message}`);
      continue;
    }

    fullTranscript += transcript + '\n\n';

    // Always save the raw transcript, even if notes generation fails below
    fs.appendFileSync(TRANSCRIPT_FILE, `\n## ${label}\n\n${transcript}\n`);

    // On the first successful chunk, infer the topic and open the per-session file.
    if (!sessionTranscriptPath) {
      try {
        const topic = (await inferTranscriptTitle(transcript))
          || path.basename(resolvedInput, path.extname(resolvedInput));
        fs.mkdirSync(SESSION_DIR, { recursive: true });
        sessionTranscriptPath = path.join(
          SESSION_DIR,
          `${timestampForFilename(sessionDate)}-${slugifyTitle(topic)}.md`
        );
        fs.writeFileSync(sessionTranscriptPath, transcriptHeader(topic, sessionDate));
      } catch (e) {
        console.error(`    Per-session transcript init failed: ${e.message}`);
      }
    }
    if (sessionTranscriptPath) {
      try { fs.appendFileSync(sessionTranscriptPath, `\n## ${label}\n\n${transcript}\n`); } catch {}
    }

    console.log(`  [${i + 1}/${chunkPaths.length}] Generating notes...`);
    let notes;
    try {
      notes = await generateNotes(transcript, label);
    } catch (e) {
      console.error(`    Notes failed: ${e.message}`);
      continue;
    }

    if (notes !== '(nothing noteworthy)') {
      fs.appendFileSync(OUTPUT_FILE, `\n## ${label}\n\n${notes}\n`);
      console.log('    ✓ saved');
    }
  }

  // Summary for longer videos
  if (numChunks > 1 && fullTranscript.trim().length > 100) {
    console.log('\n  Generating overall summary...');
    try {
      const summary = await generateNotes(fullTranscript.slice(0, 8000), 'Overall summary');
      fs.appendFileSync(OUTPUT_FILE, `\n---\n\n## Overall Summary\n\n${summary}\n`);
      console.log('  ✓ Summary saved');
    } catch (e) {
      console.error(`  Summary failed: ${e.message}`);
    }
  }

  // Cleanup
  chunkPaths.forEach(p => { try { fs.unlinkSync(p); } catch {} });
  try { fs.rmdirSync(TMP_DIR); } catch {}

  console.log(`\n  Done!`);
  console.log(`  Notes      → ${OUTPUT_FILE}`);
  console.log(`  Transcript → ${TRANSCRIPT_FILE}`);
  if (sessionTranscriptPath) console.log(`  Session    → ${sessionTranscriptPath}`);
  console.log('');
}

main().catch(e => { console.error(e.message); process.exit(1); });
