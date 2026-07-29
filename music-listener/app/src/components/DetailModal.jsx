import { useEffect } from "react";
import { gcsUrl } from "../api.js";
import { DownloadIcon } from "../icons.jsx";
import { tierLabel } from "./SetTable.jsx";

function extOf(objectName) {
  const match = /\.([a-zA-Z0-9]+)$/.exec(objectName);
  return match ? match[1] : "audio";
}

const PROVIDER_LABELS = { lyria: "Lyria", elevenlabs: "Eleven Labs" };
const CLIP_KINDS = [
  { field: "generated", label: "Clip" },
  { field: "loop", label: "Loop" },
  { field: "seam", label: "Seam" },
];

function DownloadLink({ song, objectName, providerLabel, kind }) {
  const filename = `${song.title} - ${providerLabel} ${kind}.${extOf(objectName)}`;
  return (
    <a className="dl-link" href={gcsUrl(objectName)} download={filename}>
      <DownloadIcon />
      {kind}
    </a>
  );
}

export default function DetailModal({ song, onClose }) {
  useEffect(() => {
    if (!song) return;
    function handleKeyDown(event) {
      if (event.key === "Escape") onClose();
    }
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [song, onClose]);

  if (!song) return null;

  // A set declares its own providers (v9 is ElevenLabs-only), so render
  // whichever ones this song actually carries.
  const entries = Object.entries(song.providers).map(([key, clips]) => ({
    key,
    label: PROVIDER_LABELS[key] || key,
    clips,
  }));
  const samePrompt = entries.every((entry) => entry.clips.prompt === entries[0].clips.prompt);

  return (
    <div
      className="modal-backdrop open"
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div className="modal">
        <button className="modal-close" type="button" onClick={onClose}>
          ×
        </button>
        <h3>{song.title}</h3>
        <div className="modal-sub">
          {song.artist} · {song.genre} · {tierLabel(song.tier)}
        </div>

        <div className="downloads">
          {entries.map(({ key, label, clips }) => (
            <div className="dl-group" key={key}>
              <span className="dl-group-label">{label}</span>
              {CLIP_KINDS.map(({ field, label: kind }) => (
                <DownloadLink
                  key={field}
                  song={song}
                  objectName={clips[field]}
                  providerLabel={label}
                  kind={kind}
                />
              ))}
            </div>
          ))}
        </div>

        <div className="modal-columns">
          <div className="modal-col">
            <dl>
              <dt>Vocalist</dt>
              <dd>{song.vocalist}</dd>
              <dt>Tempo</dt>
              <dd>{song.bpm} BPM, {song.meter}, {song.bars} bars</dd>
              <dt>Key</dt>
              <dd>{song.key}</dd>
              <dt>Instrumentation</dt>
              <dd>{song.instrumentation}</dd>
              <dt>Rhythm</dt>
              <dd>{song.rhythm}</dd>
              <dt>Loop seam</dt>
              <dd>{song.loopSeam}</dd>
            </dl>
            <h4>Premise</h4>
            <div className="premise">{song.premise}</div>
            <h4>Lyrics</h4>
            <div className="lyrics">{song.lyrics.join("\n")}</div>
          </div>

          <div className="modal-col">
            <h4>Structure</h4>
            <ul className="structure">
              {song.structure.map((line, index) => (
                <li key={index}>{line}</li>
              ))}
            </ul>

            {samePrompt ? (
              <>
                <h4>
                  Generation prompt
                  {entries.length > 1
                    ? ` (${entries.map((entry) => entry.label).join(" & ")} — identical)`
                    : ` — ${entries[0].label}`}
                </h4>
                <div className="prompt-block">{entries[0].clips.prompt}</div>
              </>
            ) : (
              entries.map(({ key, label, clips }) => (
                <div key={key}>
                  <h4>Generation prompt — {label}</h4>
                  <div className="prompt-block">{clips.prompt}</div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
