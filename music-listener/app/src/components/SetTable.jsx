import { gcsUrl } from "../api.js";
import { CLIP_ICONS } from "../icons.jsx";

const TIER_ORDER = ["soothing", "relaxing", "motivating", "energizing", "abrasive"];
const PROVIDERS = [
  { key: "lyria", label: "Lyria" },
  { key: "elevenlabs", label: "Eleven Labs" },
];
const CLIPS = [
  { field: "generated", label: "Output" },
  { field: "loopX2", label: "Loop" },
  { field: "seam", label: "Seam" },
];

function tierLabel(tier) {
  return tier.charAt(0).toUpperCase() + tier.slice(1);
}

export default function SetTable({ setData, activeSrc, onPlay, onDetail }) {
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
      </div>

      <div className="table-wrap">
        <table>
          <thead>
            <tr className="group-row">
              <th rowSpan={2}>Intensity</th>
              <th rowSpan={2}>Artist Name</th>
              <th rowSpan={2}>Song Name</th>
              <th rowSpan={2}>Genre Name</th>
              <th colSpan={3} className="provider-head">Lyria</th>
              <th colSpan={3} className="provider-head">Eleven Labs</th>
              <th rowSpan={2}>Detail</th>
            </tr>
            <tr>
              <th className="sub-head">Output</th>
              <th className="sub-head">Loop</th>
              <th className="sub-head">Seam</th>
              <th className="sub-head">Output</th>
              <th className="sub-head">Loop</th>
              <th className="sub-head">Seam</th>
            </tr>
          </thead>
          <tbody>
            {songs.map((song) => (
              <tr key={song.id}>
                <td>
                  <span className={`tier-chip tier-${song.tier}`}>{song.tier}</span>
                </td>
                <td className="artist-cell">{song.artist}</td>
                <td className="title-cell">{song.title}</td>
                <td>{song.genre}</td>
                {PROVIDERS.map(({ key: providerKey, label: providerLabel }) =>
                  CLIPS.map(({ field, label: clipLabel }) => {
                    const objectName = song.providers[providerKey][field];
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
                            onPlay(song, providerKey, providerLabel, field, clipLabel, src)
                          }
                        >
                          <Icon />
                        </button>
                      </td>
                    );
                  })
                )}
                <td className="cell-play">
                  <button type="button" className="detail-btn" onClick={() => onDetail(song)}>
                    Detail
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export { tierLabel };
