import { useEffect } from "react";
import { gcsUrl } from "../api.js";
import { DownloadIcon } from "../icons.jsx";
import { tierLabel } from "./SetTable.jsx";

function extOf(objectName) {
  const match = /\.([a-zA-Z0-9]+)$/.exec(objectName);
  return match ? match[1] : "audio";
}

function DownloadLink({ song, objectName, clipLabel }) {
  const filename = `${song.title} - ${clipLabel}.${extOf(objectName)}`;
  return (
    <a className="dl-link" href={gcsUrl(objectName)} download={filename}>
      <DownloadIcon />
      {clipLabel.split(" ")[1]}
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

  const lyria = song.providers.lyria;
  const eleven = song.providers.elevenlabs;
  const samePrompt = lyria.prompt === eleven.prompt;

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
          <div className="dl-group">
            <span className="dl-group-label">Lyria</span>
            <DownloadLink song={song} objectName={lyria.generated} clipLabel="Lyria Output" />
            <DownloadLink song={song} objectName={lyria.loopX2} clipLabel="Lyria Loop" />
            <DownloadLink song={song} objectName={lyria.seam} clipLabel="Lyria Seam" />
          </div>
          <div className="dl-group">
            <span className="dl-group-label">Eleven Labs</span>
            <DownloadLink song={song} objectName={eleven.generated} clipLabel="ElevenLabs Output" />
            <DownloadLink song={song} objectName={eleven.loopX2} clipLabel="ElevenLabs Loop" />
            <DownloadLink song={song} objectName={eleven.seam} clipLabel="ElevenLabs Seam" />
          </div>
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
                <h4>Generation prompt (Lyria &amp; ElevenLabs — identical)</h4>
                <div className="prompt-block">{lyria.prompt}</div>
              </>
            ) : (
              <>
                <h4>Generation prompt — Lyria</h4>
                <div className="prompt-block">{lyria.prompt}</div>
                <h4>Generation prompt — ElevenLabs</h4>
                <div className="prompt-block">{eleven.prompt}</div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
