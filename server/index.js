import 'dotenv/config';
import fs from 'node:fs/promises';
import path from 'node:path';
import express from 'express';
import multer from 'multer';
import * as tmdb from './tmdb.js';
import * as store from './store.js';
import { recognize } from './recognize/index.js';
import { hasGemini } from './recognize/gemini.js';

const app = express();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 25 * 1024 * 1024, files: 30 } });
app.use(express.json());

const wrap = (fn) => (req, res, next) => fn(req, res, next).catch(next);

app.get('/api/status', (req, res) => {
  res.json({ tmdb: tmdb.hasTmdb(), gemini: hasGemini(), region: (process.env.REGION || 'US').toUpperCase() });
});

// Save keys from the setup screen into .env (local app only).
const ENV_FILE = path.resolve(import.meta.dirname, '../.env');
app.post('/api/settings', wrap(async (req, res) => {
  const allowed = ['TMDB_API_KEY', 'GEMINI_API_KEY'];
  let text = '';
  try { text = await fs.readFile(ENV_FILE, 'utf8'); } catch {}
  for (const k of allowed) {
    if (typeof req.body[k] !== 'string') continue;
    const v = req.body[k].trim();
    process.env[k] = v;
    const line = `${k}=${v}`;
    text = new RegExp(`^${k}=.*$`, 'm').test(text) ? text.replace(new RegExp(`^${k}=.*$`, 'm'), line) : `${text.trimEnd()}\n${line}\n`.trimStart();
  }
  await fs.writeFile(ENV_FILE, text);
  res.json({ tmdb: tmdb.hasTmdb(), gemini: hasGemini() });
}));

app.get('/api/search', wrap(async (req, res) => {
  res.json(await tmdb.search(String(req.query.q || '')));
}));

app.get('/api/title/:type/:id', wrap(async (req, res) => {
  res.json(await tmdb.details(req.params.type, req.params.id));
}));

app.post('/api/recognize', upload.array('images'), wrap(async (req, res) => {
  const results = [];
  for (const file of req.files || []) {
    try { results.push(await recognize(file)); }
    catch (e) {
      if (e.status === 401) throw e;
      results.push({ filename: file.originalname, error: e.message, candidates: [] });
    }
  }
  res.json(results);
}));

app.get('/api/library', wrap(async (req, res) => res.json(await store.list())));

app.post('/api/library', wrap(async (req, res) => {
  const { tmdbId, type, spottedOn = null, source = 'search' } = req.body;
  const d = await tmdb.details(type, tmdbId);
  const { popularity, originalTitle, ...rest } = d;
  const result = await store.add({ ...rest, spottedOn, source, refreshedAt: new Date().toISOString() });
  res.status(result.duplicate ? 200 : 201).json(result);
}));

app.post('/api/library/:id/refresh', wrap(async (req, res) => {
  const item = (await store.list()).find((i) => i.id === req.params.id);
  if (!item) return res.status(404).json({ error: 'Not found' });
  const { popularity, originalTitle, ...rest } = await tmdb.details(item.type, item.tmdbId);
  res.json(await store.update(item.id, { ...rest, refreshedAt: new Date().toISOString() }));
}));

app.patch('/api/library/:id', wrap(async (req, res) => {
  const patch = {};
  if (['want', 'watching', 'watched'].includes(req.body.status)) patch.status = req.body.status;
  if ('spottedOn' in req.body) patch.spottedOn = req.body.spottedOn || null;
  const item = await store.update(req.params.id, patch);
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json(item);
}));

app.delete('/api/library/:id', wrap(async (req, res) => {
  if (!(await store.remove(req.params.id))) return res.status(404).json({ error: 'Not found' });
  res.status(204).end();
}));

app.use((err, req, res, next) => {
  const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 500;
  if (status >= 500) console.error(err);
  res.status(status).json({ error: status === 401 ? 'TMDB rejected the API key — check it in Settings.' : err.message });
});

const PORT = Number(process.env.API_PORT) || 3001;
app.listen(PORT, '127.0.0.1', () => console.log(`Binge Library API on http://127.0.0.1:${PORT}`));
