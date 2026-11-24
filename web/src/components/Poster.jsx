export default function Poster({ src, title, className = '' }) {
  return src ? (
    <img src={src} alt={title} loading="lazy" className={`aspect-[2/3] w-full rounded-[12px] bg-fill object-cover ${className}`} />
  ) : (
    <div className={`grid aspect-[2/3] w-full place-items-center rounded-[12px] bg-fill p-3 text-center text-[13px] font-medium text-tertiary ${className}`}>{title}</div>
  );
}
