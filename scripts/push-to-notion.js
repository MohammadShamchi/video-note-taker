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
  const title = process.argv[2]
    || `Tutorial Notes — ${new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })}`;

  console.log(`\n  push-to-notion.js`);
  console.log(`  Title: "${title}"\n`);

  const notesText      = readLastSession(NOTES_FILE);
  const transcriptText = readLastSession(TRANSCRIPT_FILE);

  if (!notesText && !transcriptText) {
    console.error('  No notes or transcript found. Run note-live.js first.\n');
    process.exit(1);
  }

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

main().catch(e => { console.error(e.message); process.exit(1); });
