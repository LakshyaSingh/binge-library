import { useState } from 'react';
import { api } from '../api.js';

function Field({ label, ok, value, set, placeholder, help }) {
  return (
    <label className="block">
      <div className="mb-2 flex items-center gap-2 text-[15px] font-semibold tracking-tight">
        {label}
        {ok && <span className="text-[13px] font-normal text-success">Connected ✓</span>}
      </div>
      <input type="password" autoComplete="off" value={value} onChange={(e) => set(e.target.value)}
        placeholder={ok ? 'Leave blank to keep the current key' : placeholder} className="field" />
      <p className="mt-2 text-[13px] leading-relaxed text-secondary">{help}</p>
    </label>
  );
}

export default function SetupPanel({ status, canClose, onClose, onSaved }) {
  const [tmdb, setTmdb] = useState('');
  const [gemini, setGemini] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  async function save(e) {
    e.preventDefault();
    setSaving(true); setError('');
    try {
      const body = {};
      if (tmdb.trim()) body.TMDB_API_KEY = tmdb;
      if (gemini.trim()) body.GEMINI_API_KEY = gemini;
      const s = await api.saveSettings(body);
      if (body.TMDB_API_KEY) await api.search('test'); // validate the key right away
      onSaved(s);
    } catch (err) { setError(err.message); } finally { setSaving(false); }
  }

  return (
    <div className="fade-in mx-auto max-w-[560px] py-14 sm:py-20">
      <h1 className="display text-center text-[40px] sm:text-[48px]">{canClose ? 'Settings.' : 'Let’s get started.'}</h1>
      <p className="mx-auto mt-3 max-w-md text-center text-[17px] text-secondary">
        Binge Library uses two free services. Your keys stay on this Mac.
      </p>
      <form onSubmit={save} className="mt-10 space-y-7 rounded-[28px] bg-bg-alt p-7 sm:p-9">
        <Field label="TMDB" ok={status?.tmdb} value={tmdb} set={setTmdb} placeholder="API key or read access token"
          help={<>Required. Provides posters, summaries and where to watch. Get one at <a className="link" href="https://www.themoviedb.org/settings/api" target="_blank" rel="noreferrer">themoviedb.org</a>.</>} />
        <Field label="Google Gemini" ok={status?.gemini} value={gemini} set={setGemini} placeholder="API key (optional)"
          help={<>Optional. Reads screenshots most accurately, including stylized title logos. The free tier is plenty. Get one at <a className="link" href="https://aistudio.google.com/apikey" target="_blank" rel="noreferrer">aistudio.google.com</a>.</>} />
        {error && <p className="text-[14px] text-danger">{error}</p>}
        <div className="flex items-center gap-5 pt-1">
          <button disabled={saving || (!tmdb.trim() && !gemini.trim())} className="press btn-primary px-6 py-2.5 text-[15px]">
            {saving ? 'Saving…' : 'Save'}
          </button>
          {canClose && <button type="button" onClick={onClose} className="press link text-[15px]">Cancel</button>}
        </div>
      </form>
    </div>
  );
}
