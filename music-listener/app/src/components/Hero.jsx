export default function Hero({ sets }) {
  // Naming the sets by hand went stale the moment v9 landed; read them instead.
  const versions = sets?.length ? sets.map((set) => set.label).join(" / ") : "";
  return (
    <div className="hero">
      <div className="hero-icon">⏰</div>
      <div className="hero-text">
        <h1>Rise &amp; Grind</h1>
        <div className="hero-tag">{versions ? `${versions} Listening Room` : "Listening Room"}</div>
      </div>
    </div>
  );
}
