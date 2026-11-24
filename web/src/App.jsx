import { useCallback, useEffect, useState } from 'react';
import { api } from './api.js';
import SetupPanel from './components/SetupPanel.jsx';
import Library from './components/Library.jsx';
import AddView from './components/AddView.jsx';
import TitleDrawer from './components/TitleDrawer.jsx';
import Toasts, { useToasts } from './components/Toasts.jsx';

export default function App() {
  const [status, setStatus] = useState(null);
  const [items, setItems] = useState([]);
  const [view, setView] = useState('library');
  const [open, setOpen] = useState(null); // { item } or { preview: {type, tmdbId} }
  const [showSettings, setShowSettings] = useState(false);
  const toasts = useToasts();

  const loadLibrary = useCallback(() => api.library().then(setItems).catch((e) => toasts.push(e.message, 'error')), []);
  useEffect(() => { api.status().then(setStatus).catch(() => setStatus({ tmdb: false, gemini: false, offline: true })); loadLibrary(); }, []);

  const addTitle = useCallback(async ({ tmdbId, type, title }, extra = {}) => {
    try {
      const { item, duplicate } = await api.add({ tmdbId, type, ...extra });
      setItems((list) => (duplicate ? list.map((i) => (i.id === item.id ? item : i)) : [item, ...list]));
      toasts.push(duplicate ? `“${item.title}” is already in your library` : `Added “${item.title}”`, duplicate ? 'info' : 'success');
      return item;
    } catch (e) {
      toasts.push(`Couldn’t add ${title || 'title'}: ${e.message}`, 'error');
      return null;
    }
  }, []);

  const updateItem = useCallback(async (id, patch) => {
    const item = await api.update(id, patch);
    setItems((list) => list.map((i) => (i.id === id ? item : i)));
    setOpen((o) => (o?.item?.id === id ? { item } : o));
  }, []);

  const refreshItem = useCallback(async (id) => {
    const item = await api.refresh(id);
    setItems((list) => list.map((i) => (i.id === id ? item : i)));
    setOpen((o) => (o?.item?.id === id ? { item } : o));
  }, []);

  const removeItem = useCallback(async (id) => {
    await api.remove(id);
    setItems((list) => list.filter((i) => i.id !== id));
    setOpen(null);
    toasts.push('Removed from library', 'info');
  }, []);

  const libraryKeys = new Set(items.map((i) => `${i.type}:${i.tmdbId}`));
  const needsSetup = status && !status.tmdb;

  return (
    <div className="min-h-screen">
      <header className="material sticky top-0 z-30 border-b border-separator">
        <div className="mx-auto flex h-12 max-w-[1080px] items-center gap-6 px-4 sm:px-6">
          <button onClick={() => { setShowSettings(false); setView('library'); }} className="press flex items-center gap-2 text-[15px] font-semibold tracking-tight">
            <svg width="18" height="18" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="currentColor"/><path d="M12 10l10 6-10 6z" fill="var(--bg)"/></svg>
            Binge Library
          </button>
          <nav className="ml-auto flex items-center gap-5 text-[13px]">
            {[['library', 'Library'], ['add', 'Add']].map(([k, label]) => (
              <button key={k} onClick={() => { setShowSettings(false); setView(k); }}
                className={`press transition-colors ${view === k && !showSettings ? 'text-label' : 'text-secondary hover:text-label'}`}>
                {label}{k === 'library' && items.length ? <span className="ml-1 text-tertiary">{items.length}</span> : null}
              </button>
            ))}
            <button onClick={() => setShowSettings(true)} aria-label="Settings" title="Settings"
              className={`press transition-colors ${showSettings ? 'text-label' : 'text-secondary hover:text-label'}`}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>
            </button>
          </nav>
        </div>
      </header>

      <main className="mx-auto max-w-[1080px] px-4 pb-32 sm:px-6">
        {status?.offline && <p className="mt-6 rounded-2xl bg-fill p-4 text-[14px] text-danger">Can’t reach the Binge Library server. Is <code>npm start</code> running?</p>}
        {needsSetup || showSettings ? (
          <SetupPanel status={status} canClose={!needsSetup} onClose={() => setShowSettings(false)}
            onSaved={(s) => { setStatus((old) => ({ ...old, ...s })); setShowSettings(false); toasts.push('Keys saved', 'success'); }} />
        ) : view === 'library' ? (
          <Library items={items} onOpen={(item) => setOpen({ item })} onAdd={() => setView('add')} />
        ) : (
          <AddView status={status} libraryKeys={libraryKeys} onAdd={addTitle}
            onPreview={(r) => setOpen({ preview: r })} onDone={() => setView('library')} toast={toasts.push} />
        )}
      </main>

      <footer className="border-t border-separator bg-bg-alt">
        <p className="mx-auto max-w-[1080px] px-4 py-5 text-[12px] text-tertiary sm:px-6">
          Movie and TV data from TMDB. Streaming availability from JustWatch. This product uses the TMDB API but is not endorsed or certified by TMDB.
        </p>
      </footer>

      {open && (
        <TitleDrawer key={open.item?.id || `${open.preview?.type}:${open.preview?.tmdbId}`} {...open}
          inLibrary={open.preview && libraryKeys.has(`${open.preview.type}:${open.preview.tmdbId}`)}
          onClose={() => setOpen(null)} onUpdate={updateItem} onRefresh={refreshItem} onRemove={removeItem}
          onAdd={async (r) => { const item = await addTitle(r, { source: 'search' }); if (item) setOpen({ item }); }} />
      )}
      <Toasts toasts={toasts.list} />
    </div>
  );
}
