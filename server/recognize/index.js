// Orchestrates recognition: Gemini first (if configured), Apple OCR as fallback, then TMDB matching.
import path from 'node:path';
import { recognizeWithGemini, hasGemini } from './gemini.js';
import { ocrLines, analyzeOcr } from './ocr.js';
import { normalizePlatform } from './platforms.js';
import { search } from '../tmdb.js';

const norm = (s) => String(s || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, ' ').trim();

function similarity(a, b) {
  a = norm(a); b = norm(b);
  if (!a || !b) return 0;
  if (a === b) return 1;
  const ta = new Set(a.split(' ')), tb = new Set(b.split(' '));
  const inter = [...ta].filter((t) => tb.has(t)).length;
  const jacc = inter / new Set([...ta, ...tb]).size;
  // Containment counts, scaled by how much of the longer title the shorter one covers.
  const contains = a.includes(b) || b.includes(a) ? 0.5 + 0.5 * Math.min(a.length, b.length) / Math.max(a.length, b.length) : 0;
  return Math.max(jacc, contains);
}

function dedupe(list) {
  const seen = new Set();
  return list.filter((r) => { const k = `${r.type}:${r.tmdbId}`; if (seen.has(k)) return false; seen.add(k); return true; });
}

async function matchFromGemini(g) {
  const results = await search(g.title, { type: g.type, year: g.year });
  let pool = results.length ? results : await search(g.title);
  // Prefer the closest title, then popularity.
  pool = pool
    .map((r) => ({ r, s: similarity(r.title, g.title) * 2 + Math.log10(1 + r.popularity) / 4 + (g.year && r.year === g.year ? 0.5 : 0) }))
    .sort((a, b) => b.s - a.s)
    .map((x) => x.r);
  const alts = [];
  for (const t of (g.alternates || []).slice(0, 2)) {
    try { const [first] = await search(t); if (first) alts.push(first); } catch {}
  }
  return dedupe([...pool.slice(0, 4), ...alts]).slice(0, 6);
}

async function matchFromOcr(candidates) {
  const scored = [];
  for (const [rank, text] of candidates.slice(0, 4).entries()) {
    let results = [];
    try { results = await search(text); } catch (e) { if (e.status === 401) throw e; }
    for (const r of results.slice(0, 5)) {
      const sim = Math.max(similarity(r.title, text), similarity(r.originalTitle, text));
      if (sim < 0.7) continue;
      scored.push({ r, s: sim * 3 - rank * 0.4 + Math.log10(1 + r.popularity) / 4 });
    }
  }
  return dedupe(scored.sort((a, b) => b.s - a.s).map((x) => x.r)).slice(0, 6);
}

export async function recognize(file) {
  const out = { filename: file.originalname, method: null, platform: null, detectedTitle: null, candidates: [], notes: [] };
  if (hasGemini()) {
    try {
      const g = await recognizeWithGemini(file.buffer, file.mimetype);
      out.method = 'gemini';
      out.platform = normalizePlatform(g.platform);
      out.detectedTitle = g.title || null;
      if (g.title) out.candidates = await matchFromGemini(g);
      if (out.candidates.length) return out;
      out.notes.push(g.title ? `Gemini read “${g.title}” but no database match — trying OCR.` : 'Gemini found no title — trying OCR.');
    } catch (e) {
      if (e.status === 401) throw e;
      out.notes.push(e.status === 429 ? 'Gemini free quota reached — used on-device OCR.' : `Gemini failed (${e.message.slice(0, 80)}) — used on-device OCR.`);
    }
  }
  const ext = path.extname(file.originalname || '') || '.png';
  const lines = await ocrLines(file.buffer, ext);
  const { platform, candidates } = analyzeOcr(lines);
  out.method = out.method ? `${out.method}+ocr` : 'ocr';
  out.platform ||= platform;
  out.detectedTitle ||= candidates[0] || null;
  out.candidates = await matchFromOcr(candidates);
  return out;
}
