#!/usr/bin/env node
// Builds catalog.json from the plan/audio JSON under scratch_data, then
// uploads it plus every referenced audio file into the fake-gcs-server
// bucket used by the listening-room app.

import { readFile, stat } from "node:fs/promises";
import path from "node:path";

const GCS_BASE = process.env.GCS_BASE_URL || "http://gcs:4443";
const BUCKET = process.env.GCS_BUCKET || "rise-and-grind-music";
const SCRATCH_ROOT = process.env.SCRATCH_ROOT || "/data/scratch_data";
const TMP_ROOT = process.env.TMP_ROOT || "/data/tmp";
const CONCURRENCY = Number(process.env.SEED_CONCURRENCY || 12);

const TIERS = ["soothing", "relaxing", "motivating", "energizing", "abrasive"];
const PROVIDERS = ["lyria", "elevenlabs"];

const SETS = [
  { key: "v7", dir: "music_v7", previewsDir: "music_v7_previews", label: "v7", model: "Claude Sonnet 5", effort: "high" },
  { key: "v8", dir: "music_v8", previewsDir: "music_v8_previews", label: "v8", model: "Claude Opus 5", effort: "high" },
  { key: "v6", dir: "music_v6", previewsDir: "v6_previews", label: "v6", model: "Claude Fable 5", effort: "high" },
];

function slugify(name) {
  return name.replace(/[^A-Za-z0-9]+/g, "") || "song";
}

async function waitForGcs(timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${GCS_BASE}/storage/v1/b`);
      if (response.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`fake-gcs-server not ready after ${timeoutMs}ms at ${GCS_BASE}`);
}

async function ensureBucket() {
  const existing = await fetch(`${GCS_BASE}/storage/v1/b/${BUCKET}`);
  if (existing.ok) return;
  const response = await fetch(`${GCS_BASE}/storage/v1/b?project=test`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: BUCKET }),
  });
  if (!response.ok && response.status !== 409) {
    throw new Error(`bucket create failed: ${response.status} ${await response.text()}`);
  }
}

async function uploadObject(objectName, data, contentType) {
  const url =
    `${GCS_BASE}/upload/storage/v1/b/${BUCKET}/o` +
    `?uploadType=media&name=${encodeURIComponent(objectName)}`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": contentType },
    body: data,
  });
  if (!response.ok) {
    throw new Error(`upload failed for ${objectName}: ${response.status} ${await response.text()}`);
  }
}

async function pMap(items, mapper, concurrency) {
  const results = new Array(items.length);
  let cursor = 0;
  async function worker() {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await mapper(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return results;
}

async function fileExists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

async function buildCatalog() {
  const uploads = [];
  const sets = [];

  for (const cfg of SETS) {
    const songs = [];
    for (const tier of TIERS) {
      const planPath = path.join(SCRATCH_ROOT, cfg.dir, "plan_v2", `${tier}.json`);
      const planSongs = JSON.parse(await readFile(planPath, "utf8"));

      for (const song of planSongs) {
        const slug = slugify(song.title);
        const providers = {};

        for (const provider of PROVIDERS) {
          const genLocal = path.join(SCRATCH_ROOT, cfg.dir, "audio", provider, tier, `${song.id}.mp3`);
          const sidecarLocal = path.join(SCRATCH_ROOT, cfg.dir, "audio", provider, tier, `${song.id}.json`);
          const loopLocal = path.join(TMP_ROOT, cfg.previewsDir, tier, `${slug}_${provider}_x2.m4a`);
          const seamLocal = path.join(TMP_ROOT, cfg.previewsDir, tier, `${slug}_${provider}_seam.m4a`);

          const genObject = `${cfg.dir}/audio/${provider}/${tier}/${song.id}.mp3`;
          const loopObject = `${cfg.dir}/previews/${tier}/${slug}_${provider}_x2.m4a`;
          const seamObject = `${cfg.dir}/previews/${tier}/${slug}_${provider}_seam.m4a`;

          let prompt = "";
          if (await fileExists(sidecarLocal)) {
            const sidecar = JSON.parse(await readFile(sidecarLocal, "utf8"));
            prompt = sidecar.prompt || "";
          }

          providers[provider] = { generated: genObject, loopX2: loopObject, seam: seamObject, prompt };

          uploads.push({ local: genLocal, object: genObject, contentType: "audio/mpeg" });
          uploads.push({ local: loopLocal, object: loopObject, contentType: "audio/mp4" });
          uploads.push({ local: seamLocal, object: seamObject, contentType: "audio/mp4" });
        }

        songs.push({
          id: song.id,
          tier,
          title: song.title,
          artist: song.artist,
          genre: song.genre,
          vocalist: song.vocalist,
          bpm: song.bpm,
          meter: song.meter,
          bars: song.bars,
          key: song.key,
          instrumentation: song.instrumentation,
          rhythm: song.rhythm,
          structure: song.structure,
          loopSeam: song.loopSeam,
          lyrics: song.lyrics,
          premise: song.premise,
          providers,
        });
      }
    }
    sets.push({ key: cfg.key, label: cfg.label, model: cfg.model, effort: cfg.effort, songs });
  }

  return { catalog: { sets }, uploads };
}

async function main() {
  console.log(`Waiting for fake-gcs-server at ${GCS_BASE}...`);
  await waitForGcs();
  await ensureBucket();
  console.log(`Bucket "${BUCKET}" ready.`);

  console.log("Reading plan/audio JSON from scratch_data...");
  const { catalog, uploads } = await buildCatalog();
  const songCount = catalog.sets.reduce((sum, s) => sum + s.songs.length, 0);
  console.log(`Built catalog: ${catalog.sets.length} sets, ${songCount} songs, ${uploads.length} audio files.`);

  const missing = [];
  let uploaded = 0;
  await pMap(
    uploads,
    async ({ local, object, contentType }) => {
      if (!(await fileExists(local))) {
        missing.push({ object, local });
        return;
      }
      const data = await readFile(local);
      await uploadObject(object, data, contentType);
      uploaded += 1;
      if (uploaded % 150 === 0) console.log(`  uploaded ${uploaded}/${uploads.length}...`);
    },
    CONCURRENCY
  );

  await uploadObject("catalog.json", Buffer.from(JSON.stringify(catalog)), "application/json");
  console.log(`Uploaded ${uploaded}/${uploads.length} audio files and catalog.json.`);

  if (missing.length) {
    console.error(`ERROR: ${missing.length} source file(s) were missing on disk:`);
    for (const item of missing.slice(0, 20)) console.error(`  ${item.object} <- ${item.local}`);
    if (missing.length > 20) console.error(`  ...and ${missing.length - 20} more`);
    process.exitCode = 1;
    return;
  }

  console.log("Seed complete.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
