// Brand dot colors. Apple TV and Peacock use the text color so they show up in both themes.
export const PLATFORM_STYLES = {
  'Netflix': '#E50914',
  'Prime Video': '#00A8E1',
  'Apple TV': 'var(--label)',
  'Hulu': '#1CE783',
  'Max': '#002BE7',
  'Disney+': '#113CCF',
  'Peacock': 'var(--label)',
  'Paramount+': '#0064FF',
};
export const PLATFORMS = Object.keys(PLATFORM_STYLES);

export function PlatformDot({ name, size = 7 }) {
  return <span className="inline-block shrink-0 rounded-full" style={{ width: size, height: size, background: PLATFORM_STYLES[name] || 'var(--tertiary)' }} />;
}

export function PlatformBadge({ name, className = '' }) {
  if (!name) return null;
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap text-[12px] text-secondary ${className}`}>
      <PlatformDot name={name} />{name}
    </span>
  );
}
