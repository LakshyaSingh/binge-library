export const PLATFORMS = ['Netflix', 'Prime Video', 'Apple TV', 'Hulu', 'Max', 'Disney+', 'Peacock', 'Paramount+'];

export function normalizePlatform(p) {
  if (!p) return null;
  const s = String(p).toLowerCase();
  if (s.includes('netflix')) return 'Netflix';
  if (s.includes('prime') || s.includes('amazon')) return 'Prime Video';
  if (s.includes('apple')) return 'Apple TV';
  if (s.includes('hulu')) return 'Hulu';
  if (s === 'max' || s.includes('hbo')) return 'Max';
  if (s.includes('disney')) return 'Disney+';
  if (s.includes('peacock')) return 'Peacock';
  if (s.includes('paramount')) return 'Paramount+';
  return null;
}
