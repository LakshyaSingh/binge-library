// Thin TMDB client: search, details, and "where to watch" providers.
const BASE = 'https://api.themoviedb.org/3';
const IMG = 'https://image.tmdb.org/t/p';

export const hasTmdb = () => Boolean(process.env.TMDB_API_KEY);
const region = () => (process.env.REGION || 'US').toUpperCase();

async function tmdb(path, params = {}) {
  const key = process.env.TMDB_API_KEY;
  if (!key) throw Object.assign(new Error('TMDB_API_KEY is not set'), { status: 400 });
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== '') url.searchParams.set(k, v);
  const headers = { accept: 'application/json' };
  // v4 read-access tokens are long JWTs; v3 keys are 32 hex chars.
  if (key.length > 40) headers.authorization = `Bearer ${key}`;
  else url.searchParams.set('api_key', key);
  const res = await fetch(url, { headers });
  if (!res.ok) {
    const body = await res.text();
    throw Object.assign(new Error(`TMDB ${res.status}: ${body.slice(0, 200)}`), { status: res.status === 401 ? 401 : 502 });
  }
  return res.json();
}

const yearOf = (d) => (d ? Number(String(d).slice(0, 4)) || null : null);

export function toResult(r, typeHint) {
  const type = r.media_type || typeHint;
  return {
    tmdbId: r.id,
    type,
    title: type === 'tv' ? r.name : r.title,
    originalTitle: type === 'tv' ? r.original_name : r.original_title,
    year: yearOf(type === 'tv' ? r.first_air_date : r.release_date),
    posterUrl: r.poster_path ? `${IMG}/w342${r.poster_path}` : null,
    overview: r.overview || '',
    rating: r.vote_average ? Math.round(r.vote_average * 10) / 10 : null,
    popularity: r.popularity || 0,
  };
}

export async function search(query, { type, year } = {}) {
  if (!query?.trim()) return [];
  if (type === 'movie' || type === 'tv') {
    const params = { query, include_adult: 'false' };
    if (year) params[type === 'tv' ? 'first_air_date_year' : 'year'] = year;
    let data = await tmdb(`/search/${type}`, params);
    if (!data.results.length && year) data = await tmdb(`/search/${type}`, { query, include_adult: 'false' });
    return data.results.map((r) => toResult(r, type));
  }
  const data = await tmdb('/search/multi', { query, include_adult: 'false' });
  return data.results.filter((r) => r.media_type === 'movie' || r.media_type === 'tv').map((r) => toResult(r));
}

// Map TMDB provider names onto the friendly names the app uses for badges.
const PROVIDER_ALIASES = [
  [/^netflix/i, 'Netflix'],
  [/amazon prime video|^prime video/i, 'Prime Video'],
  [/^amazon video$/i, 'Amazon Video'],
  [/^apple tv/i, 'Apple TV'],
  [/^hulu/i, 'Hulu'],
  [/^(max|hbo max)/i, 'Max'],
  [/^disney/i, 'Disney+'],
  [/^peacock/i, 'Peacock'],
  [/^paramount/i, 'Paramount+'],
];
export function normalizeProvider(name) {
  // "Apple TV Amazon Channel", "Max Roku Premium Channel" → same service.
  name = name.replace(/\s+(amazon|roku premium|apple tv) channel$/i, '').trim();
  for (const [re, label] of PROVIDER_ALIASES) if (re.test(name)) return label;
  return name;
}

function providers(wp) {
  const r = wp?.results?.[region()];
  if (!r) return { stream: [], rent: [], buy: [], link: null };
  const map = (list = []) => {
    const seen = new Map();
    for (const p of list) {
      const name = normalizeProvider(p.provider_name);
      if (!seen.has(name)) seen.set(name, { name, logoUrl: p.logo_path ? `${IMG}/w92${p.logo_path}` : null });
    }
    return [...seen.values()];
  };
  return { stream: map([...(r.flatrate || []), ...(r.free || []), ...(r.ads || [])]), rent: map(r.rent), buy: map(r.buy), link: r.link || null };
}

export async function details(type, id) {
  if (type !== 'movie' && type !== 'tv') throw Object.assign(new Error('type must be movie or tv'), { status: 400 });
  const d = await tmdb(`/${type}/${id}`, { append_to_response: 'watch/providers' });
  const base = toResult(d, type);
  return {
    ...base,
    backdropUrl: d.backdrop_path ? `${IMG}/w1280${d.backdrop_path}` : null,
    genres: (d.genres || []).map((g) => g.name),
    runtime: type === 'movie' ? d.runtime || null : null,
    seasons: type === 'tv' ? d.number_of_seasons || null : null,
    episodes: type === 'tv' ? d.number_of_episodes || null : null,
    tagline: d.tagline || '',
    providers: providers(d['watch/providers']),
    region: region(),
  };
}
