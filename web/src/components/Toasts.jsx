import { useCallback, useState } from 'react';

export function useToasts() {
  const [list, setList] = useState([]);
  const push = useCallback((text, kind = 'info') => {
    const id = Math.random().toString(36).slice(2);
    setList((l) => [...l.slice(-2), { id, text, kind }]);
    setTimeout(() => setList((l) => l.filter((t) => t.id !== id)), 3000);
  }, []);
  return { list, push };
}

export default function Toasts({ toasts }) {
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-6 z-50 flex flex-col items-center gap-2 px-4" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className="fade-in material flex items-center gap-2 rounded-full border border-separator px-5 py-2.5 text-[14px] font-medium text-label shadow-[var(--shadow-lg)]">
          {t.kind === 'success' && <span className="text-success">✓</span>}
          {t.kind === 'error' && <span className="text-danger">!</span>}
          {t.text}
        </div>
      ))}
    </div>
  );
}
