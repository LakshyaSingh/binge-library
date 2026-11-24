// Fallback recognition: Apple Vision OCR (on-device, free) via a small Swift helper.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const run = promisify(execFile);
const SRC = path.resolve(import.meta.dirname, 'ocr.swift');
const BIN = path.resolve(import.meta.dirname, '../bin/ocr');
let building = null;

async function ensureBinary() {
  try {
    const [b, s] = await Promise.all([fs.stat(BIN), fs.stat(SRC)]);
    if (b.mtimeMs >= s.mtimeMs) return BIN;
  } catch {}
  building ??= (async () => {
    await fs.mkdir(path.dirname(BIN), { recursive: true });
    await run('swiftc', ['-O', SRC, '-o', BIN], { timeout: 180_000 });
  })().finally(() => { building = null; });
  await building;
  return BIN;
}

export async function ocrLines(buffer, ext = '.png') {
  const bin = await ensureBinary();
  const tmp = path.join(os.tmpdir(), `binge-${crypto.randomUUID()}${ext}`);
  await fs.writeFile(tmp, buffer);
  try {
    const { stdout } = await run(bin, [tmp], { timeout: 30_000, maxBuffer: 10 * 1024 * 1024 });
    return JSON.parse(stdout);
  } finally {
    fs.rm(tmp, { force: true });
  }
}

const PLATFORM_HINTS = [
  [/netflix|only on netflix|^n\s*series$|^n\s*film$/i, 'Netflix'],
  [/prime video|included with prime|^prime$|amazon original|watch with prime/i, 'Prime Video'],
  [/apple tv\+?|^tv\+$|apple original/i, 'Apple TV'],
  [/\bhulu\b/i, 'Hulu'],
  [/hbo max|^max$|max original/i, 'Max'],
  [/disney\+|disney plus/i, 'Disney+'],
  [/peacock/i, 'Peacock'],
  [/paramount\+/i, 'Paramount+'],
];

// UI chrome that is never a title.
const NOISE = /^(play|resume|watch now|more info|my list|episodes?|trailers? (&|and) more|more like this|details|season \d+|s\d+:? ?e\d+|home|tv shows|movies|new (&|and) popular|search|browse|continue watching|top 10|trending|\d+%? match|tv-?(ma|14|pg|y7?|g)|pg(-13)?|r|nc-17|hd|4k|uhd|dolby|audio description|subtitles?|cc|ad|\d{4}|\d+h ?\d*m|\d+ seasons?|\d+ episodes?|cast:?.*|genres?:?.*|starring:?.*|director:?.*|creators?:?.*|this (show|movie) is:?.*|watch (later|offline)|download|rate|share|add to watchlist|watchlist|free trial|subscribe|start watching|included with.*|rent|buy|sign in|profile|kids|categories|store|for you|library|apple tv\+?|netflix|prime video|prime)$/i;

export function analyzeOcr(lines) {
  const all = lines.map((l) => l.text).join('\n');
  let platform = null;
  for (const [re, name] of PLATFORM_HINTS) {
    if (lines.some((l) => re.test(l.text.trim())) || re.test(all)) { platform = name; break; }
  }
  const candidates = lines
    .map((l) => ({ ...l, text: l.text.replace(/\s+/g, ' ').trim() }))
    .filter((l) => l.text.length >= 2 && l.text.length <= 60)
    .filter((l) => !NOISE.test(l.text))
    .filter((l) => !/\d+% match|\b(tv-(ma|14|pg|y7?|g)|pg-13)\b|^n\s+(series|film|documentary)$/i.test(l.text))
    .filter((l) => /[a-z]/i.test(l.text))
    .filter((l) => !/[.,;]$/.test(l.text)) // sentence fragments from descriptions
    .filter((l) => l.text.split(' ').length <= 9) // long lines are descriptions
    // Bigger text = more likely the title; slight bonus for being near the top and for confidence.
    .map((l) => ({ text: l.text, score: l.height * (1 + (1 - l.y) * 0.3) * (0.5 + l.confidence / 2) }))
    .sort((a, b) => b.score - a.score);
  const seen = new Set();
  const unique = candidates.filter((c) => { const k = c.text.toLowerCase(); if (seen.has(k)) return false; seen.add(k); return true; });
  return { platform, candidates: unique.slice(0, 5).map((c) => c.text) };
}
