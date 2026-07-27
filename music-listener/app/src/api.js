export const BUCKET = import.meta.env.VITE_GCS_BUCKET || "rise-and-grind-music";

export function gcsUrl(objectName) {
  return `/storage/v1/b/${BUCKET}/o/${encodeURIComponent(objectName)}?alt=media`;
}

export async function fetchCatalog() {
  const response = await fetch(gcsUrl("catalog.json"));
  if (!response.ok) {
    throw new Error(`catalog.json fetch failed: ${response.status} ${response.statusText}`);
  }
  return response.json();
}
