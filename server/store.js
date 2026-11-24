// Tiny JSON-file store for the library.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const FILE = path.resolve(import.meta.dirname, '../data/library.json');
let cache = null;
let writing = Promise.resolve();

async function load() {
  if (cache) return cache;
  try { cache = JSON.parse(await fs.readFile(FILE, 'utf8')); }
  catch (e) { if (e.code !== 'ENOENT') throw e; cache = { items: [] }; }
  return cache;
}

function save() {
  // Serialize writes and write atomically (temp file + rename).
  writing = writing.then(async () => {
    await fs.mkdir(path.dirname(FILE), { recursive: true });
    const tmp = `${FILE}.${process.pid}.tmp`;
    await fs.writeFile(tmp, JSON.stringify(cache, null, 2));
    await fs.rename(tmp, FILE);
  });
  return writing;
}

export async function list() { return (await load()).items; }

export async function find(type, tmdbId) {
  return (await load()).items.find((i) => i.type === type && i.tmdbId === Number(tmdbId));
}

export async function add(item) {
  const db = await load();
  const existing = db.items.find((i) => i.type === item.type && i.tmdbId === item.tmdbId);
  if (existing) {
    // Re-adding merges in any newly spotted platform instead of duplicating.
    if (item.spottedOn && !existing.spottedOn) existing.spottedOn = item.spottedOn;
    await save();
    return { item: existing, duplicate: true };
  }
  const full = { id: crypto.randomUUID(), status: 'want', addedAt: new Date().toISOString(), ...item };
  db.items.unshift(full);
  await save();
  return { item: full, duplicate: false };
}

export async function update(id, patch) {
  const db = await load();
  const item = db.items.find((i) => i.id === id);
  if (!item) return null;
  Object.assign(item, patch, { id: item.id });
  await save();
  return item;
}

export async function remove(id) {
  const db = await load();
  const before = db.items.length;
  db.items = db.items.filter((i) => i.id !== id);
  if (db.items.length === before) return false;
  await save();
  return true;
}
