import { useEffect, useRef, useState } from "react";

function fmtTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0;
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s < 10 ? "0" : ""}${s}`;
}

export default function PlayerBar({ playback, onEnded }) {
  const audioRef = useRef(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    if (!playback) return;
    const audio = audioRef.current;
    audio.src = playback.src;
    setErrorMessage("");
    audio.play().catch((error) => {
      setErrorMessage(`Could not play (${error?.message || "error"})`);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playback?.nonce]);

  function togglePlay() {
    const audio = audioRef.current;
    if (!playback) return;
    if (audio.paused) audio.play();
    else audio.pause();
  }

  function handleSeek(event) {
    const audio = audioRef.current;
    if (!duration) return;
    audio.currentTime = (Number(event.target.value) / 1000) * duration;
  }

  const seekValue = duration ? (currentTime / duration) * 1000 : 0;

  return (
    <div id="player-bar">
      <button
        id="playPauseBtn"
        type="button"
        disabled={!playback}
        onClick={togglePlay}
      >
        {isPlaying ? "⏸" : "▶"}
      </button>
      <div className="np">
        <div className="np-title">{playback ? playback.title : "Nothing playing"}</div>
        <div className="np-sub">
          {errorMessage || (playback ? playback.sub : "Pick a track from a table above")}
        </div>
      </div>
      <div className="scrub">
        <span>{fmtTime(currentTime)}</span>
        <input
          id="seek"
          type="range"
          min="0"
          max="1000"
          value={seekValue}
          disabled={!playback}
          onChange={handleSeek}
        />
        <span className="right">{fmtTime(duration)}</span>
      </div>
      <div className="src-tag">{playback ? playback.tag : "—"}</div>
      <audio
        ref={audioRef}
        preload="none"
        onPlay={() => setIsPlaying(true)}
        onPause={() => setIsPlaying(false)}
        onEnded={() => {
          setIsPlaying(false);
          onEnded();
        }}
        onLoadedMetadata={(event) => setDuration(event.currentTarget.duration)}
        onTimeUpdate={(event) => setCurrentTime(event.currentTarget.currentTime)}
      />
    </div>
  );
}
