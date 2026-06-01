#!/usr/bin/env node
/**
 * push-to-notion.js
 * Reads the latest session from tutorial_notes.md + tutorial_transcript.md
 * and creates a structured Notion page.
 *
 * Usage:
 *   node scripts/push-to-notion.js
 *   node scripts/push-to-notion.js "ZTM - Land Your Dream Job"
 *
 * Note: Notion MCP must be connected in Claude (Cowork) to create the page.
 * This script prepares the payload; Claude handles the final Notion API call.
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const OPENAI_API_KEY  = process.env.OPENAI_API_KEY;
const NOTES_FILE      = process.env.NOTES_FILE
  ? path.resolve(process.env.NOTES_FILE.replace('~', os.homedir()))
  : path.join(os.homedir(), 'tutorial_notes.md');
const TRANSCRIPT_FILE = process.env.TRANSCRIPT_FILE
  ? path.resolve(process.env.TRANSCRIPT_FILE.replace('~', os.homedir()))
  : path.join(os.homedir(), 'tutorial_transcript.md');
// Per-session, topic-named transcripts written by the note scripts (Feature 2).
const SESSION_DIR = path.join(os.homedir(), 'TutorScribe', 'transcripts');

if (!OPENAI_API_KEY) {
  console.error('\n  ERROR: OPENAI_API_KEY is not set.\n');
  process.exit(1);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function readLastSession(filePath) {
  if (!fs.existsSync(filePath)) return '';
  const content = fs.readFileSync(filePath, 'utf8');
  // Session boundary markers written by the note scripts:
  //   _Session started:  (initial header — note-live, both files)
  //   _New session:      (subsequent live runs)
  //   _Generated:        (file-mode header)
  const parts   = content.split(/\n_(?:New session|Session started|Generated): /);
  const last    = parts[parts.length - 1];
  // Drop the leading timestamp/separator tail so we start at the first segment.
  const firstSegment = last.indexOf('\n## ');
  return (firstSegment === -1 ? last : last.slice(firstSegment + 1)).trim();
}

// Reuse the topic inferred by Feature 2: the H1 of the newest per-session
// transcript file. Skips pending/placeholder headings. Returns '' if none found.
function readLatestSessionTitle() {
  if (!fs.existsSync(SESSION_DIR)) return '';
  const files = fs.readdirSync(SESSION_DIR)
    .filter(f => f.endsWith('.md') && !f.startsWith('pending-'));
  if (!files.length) return '';
  const newest = files
    .map(f => ({ f, m: fs.statSync(path.join(SESSION_DIR, f)).mtimeMs }))
    .sort((a, b) => b.m - a.m)[0].f;
  const first = fs.readFileSync(path.join(SESSION_DIR, newest), 'utf8').split('\n')[0];
  const h1 = first.startsWith('# ') ? first.slice(2).trim() : '';
  if (!h1 || /^Tutorial session/i.test(h1) || h1 === 'Tutorial Session') return '';
  return h1;
}

// Fallback when no per-session metadata exists: infer a title from the latest
// notes/transcript text. Mirrors inferTranscriptTitle() in note-live.js.
async function inferTitleFromText(text) {
  if (!text) return '';
  try {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: process.env.NOTES_MODEL || 'gpt-4o-mini',
        temperature: 0.2,
        messages: [
          { role: 'system', content: 'You title tutorial recordings. Reply with ONLY a short, human-readable title of 3-8 words describing the topic. No quotes, no trailing punctuation, no markdown.' },
          { role: 'user', content: text.slice(0, 4000) },
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

async function generateSummary(notesText) {
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: process.env.NOTES_MODEL || 'gpt-4o-mini',
      temperature: 0.3,
      messages: [
        {
          role: 'system',
          content: 'Write a 3-5 sentence plain-prose summary of what was covered in this tutorial session. No bullet points.',
        },
        { role: 'user', content: notesText },
      ],
    }),
  });
  const json = await res.json();
  return json.choices?.[0]?.message?.content?.trim() ?? '';
}

function buildNotionContent(notesText, transcriptText, summary) {
  const lines = [];

  if (summary) {
    lines.push(`> 📋 ${summary}`);
    lines.push('');
  }

  lines.push('## 📝 Notes by Segment');
  lines.push('');

  const noteSegments = notesText.split(/\n## /).filter(Boolean);
  for (const seg of noteSegments) {
    const [heading, ...rest] = seg.split('\n');
    const body = rest.join('\n').trim();
    if (body) {
      lines.push(`### ${heading}`);
      lines.push('');
      lines.push(body);
      lines.push('');
    }
  }

  if (transcriptText?.length > 50) {
    lines.push('---');
    lines.push('');
    lines.push('## 🎙 Full Transcript');
    lines.push('');
    const txSegments = transcriptText.split(/\n## /).filter(Boolean);
    for (const seg of txSegments) {
      const [heading, ...rest] = seg.split('\n');
      const body = rest.join('\n').trim();
      if (body) {
        lines.push(`### ${heading}`);
        lines.push('');
        body.split('\n').forEach(l => lines.push(l ? `> ${l}` : '>'));
        lines.push('');
      }
    }
  }

  return lines.join('\n');
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n  push-to-notion.js`);

  const notesText      = readLastSession(NOTES_FILE);
  const transcriptText = readLastSession(TRANSCRIPT_FILE);

  if (!notesText && !transcriptText) {
    console.error('  No notes or transcript found. Run note-live.js first.\n');
    process.exit(1);
  }

  // Title precedence: manual arg → inferred session topic (Feature 2) →
  // title inferred from the latest text → date fallback.
  const dateFallback = `Tutorial Notes — ${new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}`;
  const title = process.argv[2]
    || readLatestSessionTitle()
    || (await inferTitleFromText(notesText || transcriptText))
    || dateFallback;

  console.log(`  Title: "${title}"\n`);

  console.log('  Generating summary...');
  const summary = notesText ? await generateSummary(notesText) : '';

  console.log('  Building Notion page content...');
  const content = buildNotionContent(notesText, transcriptText, summary);

  // Save payload for Claude/Notion MCP to pick up
  const payload = { title, content, summary };
  const payloadPath = path.join(os.homedir(), '.notion_push_payload.json');
  fs.writeFileSync(payloadPath, JSON.stringify(payload, null, 2));

  console.log('\n  ✓ Payload ready');
  console.log(`  Tell Claude: "push to Notion" to create the page.\n`);
  console.log('── PREVIEW (first 500 chars) ──────────────────────');
  console.log(content.slice(0, 500) + (content.length > 500 ? '\n...' : ''));
  console.log('───────────────────────────────────────────────────\n');
}

if (require.main === module) {
  main().catch(e => { console.error(e.message); process.exit(1); });
}

module.exports = { readLastSession, readLatestSessionTitle, inferTitleFromText, buildNotionContent };
