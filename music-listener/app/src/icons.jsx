export function SparkleIcon() {
  return (
    <svg viewBox="0 0 24 24" className="icon-fill">
      <path d="M12 2.5c.4 3.1 1 4.9 2.1 6.1 1.2 1.2 3 1.8 6.4 2.2-3.4.4-5.2 1-6.4 2.2-1.1 1.2-1.7 3-2.1 6.1-.4-3.1-1-4.9-2.1-6.1-1.2-1.2-3-1.8-6.4-2.2 3.4-.4 5.2-1 6.4-2.2 1.1-1.2 1.7-3 2.1-6.1z" />
      <path d="M19 3.2c.2 1.1.5 1.8.9 2.2.4.4 1.1.7 2.2.9-1.1.2-1.8.5-2.2.9-.4.4-.7 1.1-.9 2.2-.2-1.1-.5-1.8-.9-2.2-.4-.4-1.1-.7-2.2-.9 1.1-.2 1.8-.5 2.2-.9.4-.4.7-1.1.9-2.2z" />
    </svg>
  );
}

export function RepeatIcon() {
  return (
    <svg viewBox="0 0 24 24">
      <path d="M4 7h11a4 4 0 014 4v1" />
      <path d="M9 3L4 7l5 4" />
      <path d="M20 17H9a4 4 0 01-4-4v-1" />
      <path d="M15 21l5-4-5-4" />
    </svg>
  );
}

export function NeedleIcon() {
  return (
    <svg viewBox="0 0 24 24">
      <path d="M4 20L17 7" />
      <circle cx="18.5" cy="5.5" r="1.6" />
      <path d="M15 10c1.2 1.8-1 2.6 0 4.4s2.8.8 2 3.1" />
    </svg>
  );
}

export function DownloadIcon() {
  return (
    <svg viewBox="0 0 24 24">
      <path d="M12 3v12m0 0l-4.5-4.5M12 15l4.5-4.5" />
      <path d="M4 19h16" />
    </svg>
  );
}

export const CLIP_ICONS = {
  generated: SparkleIcon,
  loopX2: RepeatIcon,
  seam: NeedleIcon,
};
