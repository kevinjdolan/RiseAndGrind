import { useEffect, useRef, useState } from "react";
import { fetchCatalog } from "./api.js";
import Hero from "./components/Hero.jsx";
import SetTable, { tierLabel } from "./components/SetTable.jsx";
import PlayerBar from "./components/PlayerBar.jsx";
import DetailModal from "./components/DetailModal.jsx";

export default function App() {
  const [catalog, setCatalog] = useState(null);
  const [loadError, setLoadError] = useState("");
  const [playback, setPlayback] = useState(null);
  const [detailSong, setDetailSong] = useState(null);
  const nonceRef = useRef(0);

  useEffect(() => {
    fetchCatalog()
      .then(setCatalog)
      .catch((error) => setLoadError(error.message));
  }, []);

  function handlePlay({ song, providerLabel, clipLabel, src, repeat }) {
    nonceRef.current += 1;
    setPlayback({
      src,
      repeat,
      title: `${song.title} — ${song.artist}`,
      sub: `${tierLabel(song.tier)} · ${song.genre}`,
      tag: `${providerLabel} · ${clipLabel}`,
      nonce: nonceRef.current,
    });
  }

  return (
    <>
      <Hero sets={catalog?.sets} />

      {loadError && <p className="status-line error">Could not load catalog.json: {loadError}</p>}
      {!catalog && !loadError && <p className="status-line">Loading catalog…</p>}

      {catalog?.sets.map((setData) => (
        <SetTable
          key={setData.key}
          setData={setData}
          activeSrc={playback?.src ?? null}
          onPlay={handlePlay}
          onDetail={setDetailSong}
        />
      ))}

      <PlayerBar playback={playback} onEnded={() => setPlayback(null)} />
      <DetailModal song={detailSong} onClose={() => setDetailSong(null)} />
    </>
  );
}
