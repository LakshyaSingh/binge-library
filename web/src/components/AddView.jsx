import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';
import Poster from './Poster.jsx';
import { PlatformDot, PLATFORMS } from '../platforms.jsx';

const CONCURRENCY = 2;
let nextKey = 1;

const Spinner = ({ size = 16 }) => (
  <span className="inline-block animate-spin rounded-full border-2 border-fill-strong border-t-secondary" style={{ width: size, height: size }} />
);

export default function AddView({ status, libraryKeys, onAdd, onPreview, onDone, toast }) {
  const [queue, setQueue] = useState([]);
  const [drag, setDrag] = useState(false);
  const inputRef = useRef(null);
  const pending = useRef([]);
  const active = useRef(0);

  const patch = (key, p) => setQueue((q) => q.map((c) => (c.key === key ? { ...c, ...p } : c)));

  function pump() {
    while (active.current < CONCURRENCY && pending.current.length) {
      const card = pending.current.shift();
      active.current++;
      patch(card.key, { state: 'working' });
      api.recognize([card.file])
        .then(([r]) => {
          if (r.error) return patch(card.key, { state: 'error', error: r.error });
          patch(card.key, { state: 'ready', result: r, pick: 0, platform: r.platform || '' });
        })
        .catch((e) => patch(card.key, { state: 'error', error: e.message }))
        .finally(() => { active.current--; pump(); });
    }
  }

  function addFiles(files) {
    const imgs = [...files].filter((f) => f.type.startsWith('image/'));
    if (!imgs.length) return toast('Those don’t look like images.', 'error');
    const cards = imgs.map((file) => ({ key: nextKey++, file, thumb: URL.createObjectURL(file), state: 'queued' }));
    setQueue((q) => [...cards, ...q]);
    pending.current.push(...cards);
    pump();
  }

  // Paste screenshots straight from the clipboard (⌘V).
  useEffect(() => {
    const onPaste = (e) => {
      const files = [...(e.clipboardData?.files || [])];
      if (files.some((f) => f.type.startsWith('image/'))) { e.preventDefault(); addFiles(files); }
    };
    window.addEventListener('paste', onPaste);
    return () => window.removeEventListener('paste', onPaste);
  }, []);

  useEffect(() => () => queue.forEach((c) => URL.revokeObjectURL(c.thumb)), []);

  async function addCard(card) {
    const r = card.result.candidates[card.pick];
    if (!r) return;
    patch(card.key, { state: 'adding' });
    const item = await onAdd(r, { spottedOn: card.platform || null, source: 'screenshot' });
    patch(card.key, { state: item ? 'added' : 'ready' });
  }

  const ready = queue.filter((c) => c.state === 'ready' && c.result?.candidates?.length);
  const working = queue.filter((c) => ['queued', 'working'].includes(c.state)).length;
  const allSettled = queue.length > 0 && queue.every((c) => ['added', 'skipped', 'error'].includes(c.state) || (c.state === 'ready' && !c.result?.candidates?.length));

  return (
    <div className="fade-in">
      <section className="pb-10 pt-14 text-center sm:pt-20">
        <h1 className="display text-[44px] sm:text-[56px]">Add to your list.</h1>
        <p className="mx-auto mt-3 max-w-xl text-[19px] leading-snug text-secondary sm:text-[21px]">
          Drop in screenshots from your streaming apps. Binge Library finds each title for you.
        </p>
      </section>

      <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
        <section className="min-w-0">
          <div
            onDragOver={(e) => { e.preventDefault(); setDrag(true); }}
            onDragLeave={() => setDrag(false)}
            onDrop={(e) => { e.preventDefault(); setDrag(false); addFiles(e.dataTransfer.files); }}
            onClick={() => inputRef.current?.click()}
            role="button" tabIndex={0} onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && inputRef.current?.click()}
            className={`grid cursor-pointer place-items-center rounded-[28px] px-6 py-16 text-center outline-none transition-all duration-300 focus-visible:ring-4 focus-visible:ring-blue/30 ${drag ? 'scale-[1.01] bg-blue/10 ring-2 ring-blue' : 'bg-bg-alt hover:bg-fill'}`}>
            <svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" className={drag ? 'text-blue' : 'text-tertiary'}>
              <rect x="3" y="4" width="18" height="14" rx="2.5" /><circle cx="8.5" cy="9" r="1.5" /><path d="M21 15l-5-5-8 8" />
            </svg>
            <p className="mt-4 text-[21px] font-semibold tracking-tight">Drop screenshots here.</p>
            <p className="mt-1 text-[15px] text-secondary">Or <span className="link">choose files</span>, or paste with ⌘V. Several at once is fine.</p>
            <p className="mt-4 text-[12px] text-tertiary">{status?.gemini ? 'Read by Gemini.' : 'Read on your Mac with Apple’s text recognition. Add a Gemini key in Settings for better accuracy.'}</p>
            <input ref={inputRef} type="file" accept="image/*" multiple hidden onChange={(e) => { addFiles(e.target.files); e.target.value = ''; }} />
          </div>

          {queue.length > 0 && (
            <div className="mt-10 flex flex-wrap items-center gap-3 border-b border-separator pb-3">
              <h2 className="text-[24px] font-semibold tracking-tight">Review</h2>
              <span className="flex items-center gap-2 text-[14px] text-secondary">
                {working ? <><Spinner size={12} /> Reading {working} screenshot{working > 1 ? 's' : ''}…</> : 'Check each match, then add it.'}
              </span>
              <div className="ml-auto flex gap-2">
                {ready.length > 1 && <button onClick={() => ready.forEach(addCard)} className="press btn-primary px-4 py-1.5 text-[14px]">Add All ({ready.length})</button>}
                {allSettled && <button onClick={onDone} className="press link text-[14px]">View Library ›</button>}
              </div>
            </div>
          )}

          <div className="divide-y divide-separator">
            {queue.filter((c) => c.state !== 'skipped').map((card) => (
              <ReviewRow key={card.key} card={card} libraryKeys={libraryKeys}
                onPick={(pick) => patch(card.key, { pick })}
                onPlatform={(platform) => patch(card.key, { platform })}
                onAdd={() => addCard(card)}
                onSkip={() => patch(card.key, { state: 'skipped' })}
                onPreview={onPreview} />
            ))}
          </div>
        </section>

        <aside className="lg:sticky lg:top-20 lg:self-start">
          <SearchAdd libraryKeys={libraryKeys} onAdd={onAdd} onPreview={onPreview} />
        </aside>
      </div>
    </div>
  );
}

function ReviewRow({ card, libraryKeys, onPick, onPlatform, onAdd, onSkip, onPreview }) {
  const r = card.result;
  const match = r?.candidates?.[card.pick];
  const inLib = match && libraryKeys.has(`${match.type}:${match.tmdbId}`);
  const method = r?.method === 'gemini' ? 'Gemini' : r?.method === 'ocr' ? 'text recognition' : 'Gemini and text recognition';

  return (
    <div className={`fade-in flex gap-5 py-5 transition-opacity ${card.state === 'added' ? 'opacity-50' : ''}`}>
      <img src={card.thumb} alt="" className="h-24 w-36 shrink-0 rounded-[10px] bg-fill object-cover object-top sm:h-28 sm:w-48" />
      <div className="flex min-w-0 flex-1 gap-4">
        {['queued', 'working'].includes(card.state) && (
          <div className="flex items-center gap-3 text-[15px] text-secondary">
            <Spinner /> {card.state === 'queued' ? 'Waiting…' : 'Reading screenshot…'}
          </div>
        )}
        {card.state === 'error' && (
          <div className="flex flex-1 items-start justify-between gap-3 text-[15px]">
            <p><span className="font-semibold">Couldn’t read this one.</span> <span className="text-secondary">{card.error}</span></p>
            <button onClick={onSkip} className="press link shrink-0 text-[14px]">Dismiss</button>
          </div>
        )}
        {r && !match && card.state !== 'error' && (
          <div className="flex flex-1 items-start justify-between gap-3 text-[15px]">
            <div>
              <p className="font-semibold">No match found.</p>
              <p className="mt-1 text-secondary">{r.detectedTitle ? <>It read “{r.detectedTitle}”. Try searching for it instead.</> : 'No title found in this screenshot.'}</p>
            </div>
            <button onClick={onSkip} className="press link shrink-0 text-[14px]">Dismiss</button>
          </div>
        )}
        {match && (
          <>
            <button onClick={() => onPreview(match)} className="press w-[60px] shrink-0 sm:w-[72px]" aria-label={`Preview ${match.title}`}>
              <Poster src={match.posterUrl} title={match.title} className="rounded-[8px] shadow-[var(--shadow)]" />
            </button>
            <div className="min-w-0 flex-1">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="truncate text-[17px] font-semibold tracking-tight">{match.title}</p>
                  <p className="text-[13px] text-secondary">{match.type === 'tv' ? 'Series' : 'Movie'}{match.year ? ` · ${match.year}` : ''} · Found by {method}</p>
                </div>
                {card.state === 'added' ? <span className="shrink-0 text-[14px] text-success">Added ✓</span> : (
                  <div className="flex shrink-0 items-center gap-3">
                    <button onClick={onSkip} className="press text-[14px] text-secondary hover:text-label">Skip</button>
                    <button disabled={card.state === 'adding'} onClick={onAdd} className="press btn-primary px-4 py-1.5 text-[14px]">
                      {card.state === 'adding' ? 'Adding…' : inLib ? 'Update' : 'Add'}
                    </button>
                  </div>
                )}
              </div>
              <div className="mt-3 flex flex-wrap items-center gap-2">
                {r.candidates.length > 1 && (
                  <select value={card.pick} onChange={(e) => onPick(Number(e.target.value))} disabled={card.state === 'added'} className="plain max-w-64 !text-[13px]" aria-label="Choose a different match">
                    {r.candidates.map((c, i) => <option key={`${c.type}${c.tmdbId}`} value={i}>{i === 0 ? '' : 'Or: '}{c.title}{c.year ? ` (${c.year})` : ''} · {c.type === 'tv' ? 'TV' : 'Movie'}</option>)}
                  </select>
                )}
                <span className="inline-flex items-center gap-2">
                  {card.platform && <PlatformDot name={card.platform} />}
                  <select value={card.platform} onChange={(e) => onPlatform(e.target.value)} disabled={card.state === 'added'} className="plain !text-[13px]" aria-label="Platform">
                    <option value="">Platform unknown</option>
                    {PLATFORMS.map((p) => <option key={p} value={p}>{p}</option>)}
                  </select>
                </span>
                {inLib && card.state !== 'added' && <span className="text-[13px] text-tertiary">Already in your library</span>}
              </div>
              {r.notes?.length > 0 && <p className="mt-2 text-[12px] text-tertiary">{r.notes.join(' ')}</p>}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function SearchAdd({ libraryKeys, onAdd, onPreview }) {
  const [q, setQ] = useState('');
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [adding, setAdding] = useState(null);

  useEffect(() => {
    if (q.trim().length < 2) { setResults([]); setError(''); setLoading(false); return; }
    setLoading(true);
    const ctrl = { cancelled: false };
    const t = setTimeout(() => {
      api.search(q).then((r) => !ctrl.cancelled && (setResults(r.slice(0, 12)), setError('')))
        .catch((e) => !ctrl.cancelled && setError(e.message))
        .finally(() => !ctrl.cancelled && setLoading(false));
    }, 300);
    return () => { ctrl.cancelled = true; clearTimeout(t); };
  }, [q]);

  return (
    <div className="rounded-[28px] bg-bg-alt p-6">
      <h2 className="text-[21px] font-semibold tracking-tight">Search for a title.</h2>
      <p className="mt-1 text-[14px] text-secondary">Every movie and show, on every platform.</p>
      <div className="relative mt-4">
        <svg className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-tertiary" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Movies and TV shows" aria-label="Search movies and TV shows" className="field !pl-10" />
        {loading && <span className="absolute right-3.5 top-1/2 -translate-y-1/2"><Spinner size={14} /></span>}
      </div>
      {error && <p className="mt-3 text-[14px] text-danger">{error}</p>}
      {results.length > 0 && (
        <ul className="-mx-2 mt-3 max-h-[60vh] overflow-y-auto">
          {results.map((r) => {
            const inLib = libraryKeys.has(`${r.type}:${r.tmdbId}`);
            return (
              <li key={`${r.type}${r.tmdbId}`} className="flex items-center gap-3 rounded-[14px] p-2 transition-colors hover:bg-fill">
                <button onClick={() => onPreview(r)} className="press w-10 shrink-0" aria-label={`Preview ${r.title}`}><Poster src={r.posterUrl} title="" className="rounded-[6px]" /></button>
                <button onClick={() => onPreview(r)} className="min-w-0 flex-1 text-left">
                  <p className="truncate text-[15px] font-medium tracking-tight">{r.title}</p>
                  <p className="text-[12px] text-secondary">{r.type === 'tv' ? 'Series' : 'Movie'}{r.year ? ` · ${r.year}` : ''}{r.rating ? ` · ★ ${r.rating}` : ''}</p>
                </button>
                {inLib ? (
                  <span className="shrink-0 px-2 text-[13px] text-success" aria-label="In library">✓</span>
                ) : (
                  <button disabled={adding === r.tmdbId} aria-label={`Add ${r.title}`}
                    onClick={async () => { setAdding(r.tmdbId); await onAdd(r, { source: 'search' }); setAdding(null); }}
                    className="press btn-secondary grid h-7 w-7 shrink-0 place-items-center text-[18px] leading-none text-blue">
                    {adding === r.tmdbId ? <Spinner size={12} /> : '+'}
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {!loading && q.trim().length >= 2 && !results.length && !error && <p className="mt-4 text-[14px] text-secondary">No results.</p>}
    </div>
  );
}
