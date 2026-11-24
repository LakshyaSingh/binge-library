// Apple-style segmented control.
export default function Segmented({ options, value, onChange, className = '', size = 'md' }) {
  const pad = size === 'sm' ? 'px-3 py-1 text-[13px]' : 'px-4 py-1.5 text-[14px]';
  return (
    <div role="tablist" className={`inline-flex rounded-full bg-fill p-[3px] ${className}`}>
      {options.map(([k, label, count]) => (
        <button key={k} role="tab" aria-selected={value === k} onClick={() => onChange(k)}
          className={`press flex-1 whitespace-nowrap rounded-full ${pad} transition-all ${value === k ? 'bg-surface font-medium text-label shadow-[0_1px_4px_rgba(0,0,0,0.12)]' : 'text-secondary hover:text-label'}`}>
          {label}{count !== undefined && <span className="ml-1.5 text-tertiary">{count}</span>}
        </button>
      ))}
    </div>
  );
}
