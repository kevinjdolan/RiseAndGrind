import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { gcsUrl } from "../api.js";
import { CLIP_ICONS } from "../icons.jsx";

const TIER_ORDER = ["soothing", "relaxing", "motivating", "energizing", "abrasive"];
// Fallback for sets seeded before providers became per-set. v9 is
// ElevenLabs-only, so a set now declares which columns it actually has.
const DEFAULT_PROVIDERS = [
  { key: "lyria", label: "Lyria" },
  { key: "elevenlabs", label: "Eleven Labs" },
];
// The loop clip is the mastered loop stored once; the player repeats it so the
// seam is heard at the wrap instead of baked into a doubled file.
const CLIPS = [
  { field: "generated", label: "Clip" },
  { field: "loop", label: "Loop", repeat: true },
  { field: "seam", label: "Seam" },
];

// Collapse steps, applied in order until the table fits its container. A set
// with one provider survives at a narrower width than a two-provider set, so
// the level is measured per table rather than driven by a media query.
const MERGE_SONG = 1; // artist + title share one two-line column
const TIER_DOT = 2; // intensity becomes a lettered circle, header label drops
const HIDE_GENRE = 3; // genre column disappears
const MAX_COLLAPSE = HIDE_GENRE;

function tierLabel(tier) {
  return tier.charAt(0).toUpperCase() + tier.slice(1);
}

function useFitCollapse(wrapRef) {
  // `probe` only exists to force a re-measure: a width change resets the level
  // to 0, which is a no-op render when the table is already uncollapsed.
  const [fit, setFit] = useState({ level: 0, probe: 0 });
  const collapse = fit.level;
  const widthRef = useRef(0);

  // Tighten one step per render until the table stops overflowing. Runs before
  // paint, so the intermediate wider layouts are never shown.
  useLayoutEffect(() => {
    const wrap = wrapRef.current;
    if (!wrap) return;
    if (collapse < MAX_COLLAPSE && wrap.scrollWidth > wrap.clientWidth + 1) {
      // Target the next level rather than incrementing, so StrictMode's second
      // invocation of this effect is a no-op instead of a second step.
      setFit((current) =>
        current.level === collapse ? { ...current, level: collapse + 1 } : current
      );
    }
  });

  // A width change re-probes from the roomiest layout and the effect above
  // tightens again from there. Height changes are ignored: collapsing changes
  // row heights, and reacting to that would loop.
  useEffect(() => {
    const wrap = wrapRef.current;
    if (!wrap) return;
    widthRef.current = wrap.clientWidth;
    let frame = 0;
    function reprobe() {
      const width = wrap.clientWidth;
      if (width === widthRef.current) return;
      widthRef.current = width;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        setFit((current) => ({ level: 0, probe: current.probe + 1 }));
      });
    }
    const observer = new ResizeObserver(reprobe);
    observer.observe(wrap);
    window.addEventListener("resize", reprobe);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      window.removeEventListener("resize", reprobe);
    };
  }, [wrapRef]);

  return collapse;
}

export default function SetTable({ setData, activeSrc, onPlay, onDetail }) {
  const wrapRef = useRef(null);
  const collapse = useFitCollapse(wrapRef);
  const mergeSong = collapse >= MERGE_SONG;
  const tierDot = collapse >= TIER_DOT;
  const showGenre = collapse < HIDE_GENRE;

  const providers = setData.providers?.length ? setData.providers : DEFAULT_PROVIDERS;
  const songs = [...setData.songs].sort((a, b) => {
    const ta = TIER_ORDER.indexOf(a.tier);
    const tb = TIER_ORDER.indexOf(b.tier);
    if (ta !== tb) return ta - tb;
    return a.id.localeCompare(b.id);
  });

  return (
    <section className="set">
      <div className="set-head">
        <h2>{setData.label}</h2>
        <span className="set-badge">{setData.model}</span>
        <span className="set-badge">{setData.effort} effort</span>
        <span className="set-badge">{setData.songs.length} songs</span>
        {setData.note && <span className="set-badge">{setData.note}</span>}
      </div>

      <div className="table-wrap" ref={wrapRef}>
        <table>
          <thead>
            <tr className="group-row">
              <th rowSpan={2}>{tierDot ? "" : "Intensity"}</th>
              {mergeSong ? (
                <th rowSpan={2}>Song</th>
              ) : (
                <>
                  <th rowSpan={2}>Artist Name</th>
                  <th rowSpan={2}>Song Name</th>
                </>
              )}
              {showGenre && <th rowSpan={2}>Genre Name</th>}
              {providers.map(({ key, label }) => (
                <th colSpan={CLIPS.length} className="provider-head" key={key}>
                  {label}
                </th>
              ))}
            </tr>
            <tr>
              {providers.flatMap(({ key }) =>
                CLIPS.map(({ field, label }) => (
                  <th className="sub-head" key={`${key}-${field}`}>
                    {label}
                  </th>
                ))
              )}
            </tr>
          </thead>
          <tbody>
            {songs.map((song) => (
              <tr key={song.id}>
                <td>
                  {tierDot ? (
                    <span
                      className={`tier-dot tier-${song.tier}`}
                      title={tierLabel(song.tier)}
                      aria-label={song.tier}
                    >
                      {song.tier.charAt(0).toUpperCase()}
                    </span>
                  ) : (
                    <span className={`tier-chip tier-${song.tier}`}>{song.tier}</span>
                  )}
                </td>
                {mergeSong ? (
                  <td className="song-cell">
                    <button type="button" className="song-link" onClick={() => onDetail(song)}>
                      <span className="song-title">{song.title}</span>
                      <span className="song-artist">{song.artist}</span>
                    </button>
                  </td>
                ) : (
                  <>
                    <td className="artist-cell">{song.artist}</td>
                    <td className="title-cell">
                      <button type="button" className="song-link" onClick={() => onDetail(song)}>
                        {song.title}
                      </button>
                    </td>
                  </>
                )}
                {showGenre && <td className="genre-cell">{song.genre}</td>}
                {providers.map(({ key: providerKey, label: providerLabel }) =>
                  CLIPS.map(({ field, label: clipLabel, repeat }) => {
                    const objectName = song.providers[providerKey]?.[field];
                    if (!objectName) {
                      return <td className="cell-play" key={`${providerKey}-${field}`} />;
                    }
                    const src = gcsUrl(objectName);
                    const Icon = CLIP_ICONS[field];
                    const isActive = activeSrc === src;
                    return (
                      <td className="cell-play" key={`${providerKey}-${field}`}>
                        <button
                          type="button"
                          className={`play-btn${isActive ? " playing" : ""}`}
                          title={`${providerLabel} · ${clipLabel}`}
                          aria-label={`${providerLabel} · ${clipLabel}`}
                          onClick={() =>
                            onPlay({ song, providerLabel, clipLabel, src, repeat: !!repeat })
                          }
                        >
                          <Icon />
                        </button>
                      </td>
                    );
                  })
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export { tierLabel };
