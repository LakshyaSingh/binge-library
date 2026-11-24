import { useMemo, useState } from 'react';
import Poster from './Poster.jsx';
import Segmented from './Segmented.jsx';
import { PlatformBadge, PlatformDot, PLATFORMS } from '../platforms.jsx';

const STATUSES = [['want', 'Up Next'], ['watching', 'Watching'], ['watched', 'Watched'], ['all', 'All']];
const HEADLINES = { want: 'Up next.', watching: 'Still watching.', watched: 'Watched.', all: 'Everything.' };
const SORTS = [['added', 'Recently Added'], ['rating', 'Top Rated'], ['title', 'A–Z'], ['year', 'Newest']];

// Where a title can be watched: the platform it was spotted on, plus any US streaming providers.
const platformsOf = (i) => [...new Set([i.spottedOn, ...(i.providers?.stream || []).map((p) => p.name)].filter(Boolean))];

function loadPref(key, fallback) { try { return localStorage.getItem(`bl:${key}`) || fallback; } catch { return fallback; } }
function savePref(key, v) { try { localStorage.setItem(`bl:${key}`, v); } catch {} }

export default function Library({ items, onOpen, onAdd }) {
  const [status, setStatusRaw] = useState(() => loadPref('status', 'want'));
  const [platform, setPlatform] = useState('all');
  const [type, setType] = useState('all');
  const [sort, setSortRaw] = useState(() => loadPref('sort', 'added'));
  const [q, setQ] = useState('');
  const setStatus = (v) => { setStatusRaw(v); savePref('status', v); };
  const setSort = (v) => { setSortRaw(v); savePref('sort', v); };

  const counts = useMemo(() => Object.fromEntries(STATUSES.map(([k]) => [k, k === 'all' ? items.length : items.filter((i) => i.status === k).length])), [items]);
  const presentPlatforms = useMemo(() => {
    const set = new Set(items.flatMap(platformsOf));
    return PLATFORMS.filter((p) => set.has(p)); // only the major services, not every free/ad channel
  }, [items]);

  const shown = useMemo(() => {
    const list = items.filter((i) => (status === 'all' || i.status === status)
      && (type === 'all' || i.type === type)
      && (platform === 'all' || platformsOf(i).includes(platform))
      && (!q || i.title.toLowerCase().includes(q.toLowerCase())));
    const by = {
      added: (a, b) => b.addedAt.localeCompare(a.addedAt),
      rating: (a, b) => (b.rating || 0) - (a.rating || 0),
      title: (a, b) => a.title.localeCompare(b.title),
      year: (a, b) => (b.year || 0) - (a.year || 0),
    }[sort];
    return [...list].sort(by);
  }, [items, status, type, platform, sort, q]);

  if (!items.length) {
    return (
      <section className="fade-in mx-auto max-w-2xl py-28 text-center sm:py-36">
        <p className="eyebrow">Binge Library</p>
        <h1 className="display mt-3 text-[48px] sm:text-[64px]">Everything you want to watch. In one place.</h1>
        <p className="mx-auto mt-5 max-w-lg text-[19px] leading-snug text-secondary sm:text-[21px]">
          Drop in screenshots from Netflix, Prime Video or Apple TV, or search for any movie or show.
        </p>
        <div className="mt-8 flex items-center justify-center gap-6">
          <button onClick={onAdd} className="press btn-primary px-6 py-3 text-[17px]">Add titles</button>
        </div>
      </section>
    );
  }

  const n = shown.length;
  return (
    <div className="fade-in">
      <section className="pb-8 pt-14 sm:pt-20">
        <h1 className="display text-[44px] sm:text-[56px]">{HEADLINES[status]}</h1>
        <p className="mt-2 text-[19px] text-secondary sm:text-[21px]">
          {n === 0 ? 'Nothing here yet.' : `${n} ${n === 1 ? 'title' : 'titles'}${status === 'want' ? ' waiting for you' : ''}.`}
        </p>
        <div className="mt-8 flex flex-wrap items-center gap-3">
          <Segmented options={STATUSES.map(([k, l]) => [k, l, counts[k]])} value={status} onChange={setStatus} />
          <div className="ml-auto flex flex-wrap items-center gap-2">
            <div className="relative">
              <svg className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-tertiary" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
              <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search library" aria-label="Search library"
                className="w-44 rounded-full bg-fill py-1.5 pl-8 pr-3 text-[14px] outline-none placeholder:text-tertiary focus:ring-[3px] focus:ring-blue/30" />
            </div>
            <select value={type} onChange={(e) => setType(e.target.value)} className="plain" aria-label="Type">
              <option value="all">Movies & TV</option><option value="movie">Movies</option><option value="tv">TV Shows</option>
            </select>
            <select value={sort} onChange={(e) => setSort(e.target.value)} className="plain" aria-label="Sort">
              {SORTS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
            </select>
          </div>
        </div>
        {presentPlatforms.length > 1 && (
          <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 text-[14px]">
            {[['all', 'All Platforms'], ...presentPlatforms.map((p) => [p, p])].map(([k, label]) => (
              <button key={k} onClick={() => setPlatform(platform === k ? 'all' : k)}
                className={`press inline-flex items-center gap-2 border-b-2 pb-1 transition-colors ${platform === k ? 'border-label text-label' : 'border-transparent text-secondary hover:text-label'}`}>
                {k !== 'all' && <PlatformDot name={k} />}{label}
              </button>
            ))}
          </div>
        )}
      </section>

      {n ? (
        <div className="grid grid-cols-2 gap-x-5 gap-y-9 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
          {shown.map((i) => (
            <button key={i.id} onClick={() => onOpen(i)} className="press group self-start text-left">
              <div className="relative overflow-hidden rounded-[12px] shadow-[var(--shadow)] transition-shadow duration-300 group-hover:shadow-[var(--shadow-lg)]">
                <Poster src={i.posterUrl} title={i.title} className="transition-transform duration-500 ease-out group-hover:scale-[1.03]" />
                {i.status !== 'want' && (
                  <span className="material absolute left-2 top-2 rounded-full px-2 py-0.5 text-[11px] font-medium text-label">
                    {i.status === 'watched' ? 'Watched' : 'Watching'}
                  </span>
                )}
              </div>
              <div className="mt-3 line-clamp-1 text-[15px] font-semibold tracking-tight">{i.title}</div>
              <div className="mt-0.5 text-[13px] text-secondary">
                {i.type === 'tv' ? 'Series' : 'Movie'}{i.year ? ` · ${i.year}` : ''}{i.rating ? ` · ★ ${i.rating}` : ''}
              </div>
              {i.spottedOn && <PlatformBadge name={i.spottedOn} className="mt-1.5" />}
            </button>
          ))}
        </div>
      ) : (
        <p className="py-24 text-center text-[17px] text-secondary">Nothing matches these filters.</p>
      )}
    </div>
  );
}
