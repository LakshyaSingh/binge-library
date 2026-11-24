import { useEffect, useState } from 'react';
import { api } from '../api.js';
import Poster from './Poster.jsx';
import Segmented from './Segmented.jsx';
import { PlatformBadge, PLATFORMS } from '../platforms.jsx';

function ProviderRow({ label, list }) {
  if (!list?.length) return null;
  return (
    <div>
      <div className="eyebrow mb-3">{label}</div>
      <div className="flex flex-wrap gap-x-5 gap-y-3">
        {list.map((p) => (
          <span key={p.name} className="flex items-center gap-2.5 text-[15px]">
            {p.logoUrl ? <img src={p.logoUrl} alt="" className="h-8 w-8 rounded-[8px]" /> : <span className="h-8 w-8 rounded-[8px] bg-fill" />}
            {p.name}
          </span>
        ))}
      </div>
    </div>
  );
}

export default function TitleDrawer({ item, preview, inLibrary, onClose, onUpdate, onRefresh, onRemove, onAdd }) {
  const [data, setData] = useState(item || null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (item) { setData(item); return; }
    api.details(preview.type, preview.tmdbId).then(setData).catch((e) => setError(e.message));
  }, [item, preview]);

  useEffect(() => {
    const onKey = (e) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const run = async (fn) => { setBusy(true); try { await fn(); } catch (e) { setError(e.message); } finally { setBusy(false); } };
  const d = data;
  const meta = d && [d.type === 'tv' ? 'Series' : 'Movie', d.year,
    d.runtime ? `${Math.floor(d.runtime / 60)} hr ${d.runtime % 60} min` : null,
    d.seasons ? `${d.seasons} season${d.seasons > 1 ? 's' : ''}` : null,
    d.rating ? `★ ${d.rating}` : null].filter(Boolean).join(' · ');
  const hasProviders = d?.providers?.stream?.length || d?.providers?.rent?.length || d?.providers?.buy?.length;

  return (
    <div className="fixed inset-0 z-40 flex justify-end">
      <div className="scrim-in absolute inset-0 bg-[var(--scrim)]" onClick={onClose} />
      <aside role="dialog" aria-modal="true" aria-label={d?.title || 'Title details'}
        className="sheet-in relative h-full w-full max-w-[480px] overflow-y-auto bg-bg shadow-[var(--shadow-lg)] sm:m-3 sm:h-[calc(100%-24px)] sm:rounded-[24px]">
        <button onClick={onClose} aria-label="Close"
          className="press material absolute right-4 top-4 z-10 grid h-8 w-8 place-items-center rounded-full text-secondary hover:text-label">
          <svg width="12" height="12" viewBox="0 0 12 12" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M2 2l8 8M10 2l-8 8"/></svg>
        </button>
        {!d && !error && <div className="grid h-64 place-items-center text-[15px] text-secondary">Loading…</div>}
        {error && <p className="m-6 mt-16 rounded-2xl bg-fill p-4 text-[14px] text-danger">{error}</p>}
        {d && (
          <>
            <div className="relative aspect-[16/9] bg-fill">
              {d.backdropUrl && <img src={d.backdropUrl} alt="" className="h-full w-full object-cover" />}
              <div className="absolute inset-x-0 bottom-0 h-1/2 bg-gradient-to-t from-[var(--bg)] to-transparent" />
            </div>
            <div className="relative -mt-16 px-7 pb-10">
              <div className="flex items-end gap-5">
                <div className="w-24 shrink-0 rounded-[12px] shadow-[var(--shadow-lg)]"><Poster src={d.posterUrl} title={d.title} /></div>
                <div className="min-w-0 pb-1">
                  <h2 className="display text-[28px]">{d.title}</h2>
                  <p className="mt-1.5 text-[14px] text-secondary">{meta}</p>
                </div>
              </div>

              {d.genres?.length > 0 && <p className="mt-5 text-[13px] text-secondary">{d.genres.join(' · ')}</p>}
              {d.tagline && <p className="mt-4 text-[19px] font-semibold leading-snug tracking-tight">{d.tagline}</p>}
              <p className="mt-2 text-[15px] leading-relaxed text-secondary">{d.overview || 'No summary available.'}</p>

              {item ? (
                <div className="mt-7 space-y-4">
                  <Segmented options={[['want', 'Up Next'], ['watching', 'Watching'], ['watched', 'Watched']]} value={item.status}
                    onChange={(k) => !busy && run(() => onUpdate(item.id, { status: k }))} className="flex w-full" />
                  <label className="flex items-center justify-between gap-3 text-[15px]">
                    <span className="text-secondary">Spotted on</span>
                    <select value={item.spottedOn || ''} onChange={(e) => run(() => onUpdate(item.id, { spottedOn: e.target.value }))} className="plain">
                      <option value="">Not set</option>
                      {PLATFORMS.map((p) => <option key={p}>{p}</option>)}
                    </select>
                  </label>
                </div>
              ) : (
                <button disabled={busy || inLibrary} onClick={() => run(() => onAdd({ tmdbId: d.tmdbId, type: d.type, title: d.title }))}
                  className="press btn-primary mt-7 w-full py-3 text-[17px]">
                  {inLibrary ? 'In Your Library ✓' : busy ? 'Adding…' : 'Add to Library'}
                </button>
              )}

              <section className="mt-9 border-t border-separator pt-7">
                <div className="flex items-baseline justify-between">
                  <h3 className="text-[21px] font-semibold tracking-tight">Where to watch</h3>
                  {item && <button disabled={busy} onClick={() => run(() => onRefresh(item.id))} className="press link text-[13px]">{busy ? 'Refreshing…' : 'Refresh'}</button>}
                </div>
                <p className="mt-0.5 text-[12px] text-tertiary">{d.region || 'US'} availability</p>
                <div className="mt-5 space-y-6">
                  {hasProviders ? (
                    <>
                      <ProviderRow label="Stream" list={d.providers.stream} />
                      <ProviderRow label="Rent" list={d.providers.rent} />
                      <ProviderRow label="Buy" list={d.providers.buy} />
                    </>
                  ) : (
                    <p className="text-[15px] text-secondary">No US streaming info right now.{item?.spottedOn && <> You spotted it on <PlatformBadge name={item.spottedOn} className="!text-[15px]" />.</>}</p>
                  )}
                </div>
                <p className="mt-6 text-[12px] text-tertiary">
                  Data from <a className="link" href={d.providers?.link || 'https://www.justwatch.com'} target="_blank" rel="noreferrer">JustWatch</a> via TMDB ·{' '}
                  <a className="link" href={`https://www.themoviedb.org/${d.type}/${d.tmdbId}`} target="_blank" rel="noreferrer">View on TMDB ›</a>
                </p>
              </section>

              {item && (
                <div className="mt-9 flex items-center justify-between border-t border-separator pt-5 text-[13px] text-tertiary">
                  <span>Added {new Date(item.addedAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })} from {item.source === 'screenshot' ? 'a screenshot' : 'search'}</span>
                  <button disabled={busy} onClick={() => confirm(`Remove “${item.title}” from your library?`) && run(() => onRemove(item.id))} className="press text-danger hover:underline">Remove</button>
                </div>
              )}
            </div>
          </>
        )}
      </aside>
    </div>
  );
}
