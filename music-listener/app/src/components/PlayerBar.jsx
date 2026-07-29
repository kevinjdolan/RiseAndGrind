import { useEffect, useRef, useState } from "react";

const FLASH_MS = 280;

function fmtTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0;
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s < 10 ? "0" : ""}${s}`;
}

// HTML <audio loop> re-decodes/re-seeks at the wrap, which audibly clicks or
// gaps on compressed sources. Web Audio's AudioBufferSourceNode loops the
// decoded PCM buffer itself with no re-decode and no seek, so the wrap is
// sample-accurate and silent — this is the only reliably gapless approach in
// a browser.
export default function PlayerBar({ playback, onEnded }) {
  const contextRef = useRef(null);
  const bufferRef = useRef(null);
  const sourceRef = useRef(null);
  const repeatRef = useRef(false);
  const requestIdRef = useRef(0);
  const isPlayingRef = useRef(false);
  const startContextTimeRef = useRef(0);
  const startOffsetRef = useRef(0);
  const lastLapRef = useRef(0);
  const suppressEndedRef = useRef(false);
  const rafRef = useRef(null);
  const flashTimerRef = useRef(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [errorMessage, setErrorMessage] = useState("");
  const [flashing, setFlashing] = useState(false);

  useEffect(() => {
    if (!playback) return;
    loadAndPlay(playback.src, !!playback.repeat);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playback?.nonce]);

  useEffect(
    () => () => {
      cancelAnimationFrame(rafRef.current);
      clearTimeout(flashTimerRef.current);
      stopSource();
      contextRef.current?.close();
    },
    []
  );

  function ensureContext() {
    if (!contextRef.current) {
      contextRef.current = new (window.AudioContext || window.webkitAudioContext)();
    }
    return contextRef.current;
  }

  function stopSource() {
    const source = sourceRef.current;
    if (!source) return;
    suppressEndedRef.current = true;
    source.onended = null;
    try {
      source.stop();
    } catch {
      // already stopped
    }
    source.disconnect();
    sourceRef.current = null;
  }

  function stopTicking() {
    cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
  }

  // Restart the animation even if a previous flash is still running.
  function flashSeek() {
    clearTimeout(flashTimerRef.current);
    setFlashing(false);
    requestAnimationFrame(() => setFlashing(true));
    flashTimerRef.current = setTimeout(() => setFlashing(false), FLASH_MS);
  }

  // Elapsed buffer-seconds since this play/seek started, unwrapped (can
  // exceed duration many times over on a long-looping track).
  function rawElapsed() {
    if (!bufferRef.current) return 0;
    if (!isPlayingRef.current) return startOffsetRef.current;
    return (
      startOffsetRef.current +
      (contextRef.current.currentTime - startContextTimeRef.current)
    );
  }

  function wrappedOffset() {
    const total = bufferRef.current?.duration || 0;
    if (!total) return 0;
    const raw = rawElapsed();
    return repeatRef.current ? raw % total : Math.min(raw, total);
  }

  function tick() {
    const total = bufferRef.current?.duration || 0;
    if (total > 0) {
      const raw = rawElapsed();
      const lap = Math.floor(raw / total);
      if (repeatRef.current && lap > lastLapRef.current) {
        lastLapRef.current = lap;
        flashSeek();
      }
      setCurrentTime(wrappedOffset());
    }
    rafRef.current = requestAnimationFrame(tick);
  }

  function startPlaybackFrom(offset) {
    const context = ensureContext();
    if (context.state === "suspended") context.resume();
    stopSource();

    const source = context.createBufferSource();
    source.buffer = bufferRef.current;
    source.loop = repeatRef.current;
    source.onended = () => {
      if (suppressEndedRef.current) {
        suppressEndedRef.current = false;
        return;
      }
      isPlayingRef.current = false;
      setIsPlaying(false);
      stopTicking();
      onEnded();
    };
    source.connect(context.destination);
    source.start(0, offset);
    sourceRef.current = source;

    startContextTimeRef.current = context.currentTime;
    startOffsetRef.current = offset;
    lastLapRef.current = Math.floor(offset / (bufferRef.current.duration || 1));
    isPlayingRef.current = true;
    setIsPlaying(true);
    setCurrentTime(offset);
    stopTicking();
    rafRef.current = requestAnimationFrame(tick);
  }

  async function loadAndPlay(src, repeat) {
    const requestId = ++requestIdRef.current;
    stopSource();
    stopTicking();
    isPlayingRef.current = false;
    setIsPlaying(false);
    setErrorMessage("");
    setDuration(0);
    setCurrentTime(0);
    setIsLoading(true);
    repeatRef.current = repeat;

    try {
      const context = ensureContext();
      const response = await fetch(src);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const arrayBuffer = await response.arrayBuffer();
      const decoded = await context.decodeAudioData(arrayBuffer);
      if (requestId !== requestIdRef.current) return; // a newer track was picked meanwhile
      bufferRef.current = decoded;
      setDuration(decoded.duration);
      setIsLoading(false);
      startPlaybackFrom(0);
    } catch (error) {
      if (requestId !== requestIdRef.current) return;
      setIsLoading(false);
      setErrorMessage(`Could not play (${error?.message || "error"})`);
    }
  }

  function togglePlay() {
    if (!playback || !bufferRef.current) return;
    if (isPlayingRef.current) {
      const offset = wrappedOffset();
      stopSource();
      stopTicking();
      startOffsetRef.current = offset;
      isPlayingRef.current = false;
      setIsPlaying(false);
      setCurrentTime(offset);
    } else {
      startPlaybackFrom(startOffsetRef.current);
    }
  }

  function handleSeek(event) {
    if (!duration || !bufferRef.current) return;
    const offset = (Number(event.target.value) / 1000) * duration;
    if (isPlayingRef.current) {
      startPlaybackFrom(offset);
    } else {
      startOffsetRef.current = offset;
      setCurrentTime(offset);
    }
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
          {errorMessage ||
            (isLoading ? "Loading…" : playback ? playback.sub : "Pick a track from a table above")}
        </div>
      </div>
      <div className="scrub">
        <span>{fmtTime(currentTime)}</span>
        <input
          id="seek"
          className={flashing ? "flash" : ""}
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
    </div>
  );
}
