#!/usr/bin/env bash

# Converts the generated voice lines into small, iPhone-friendly bundled AAC files.

set -euo pipefail

source_dir="${1:-scratch_data/motivational_lines_2}"
output_dir="RiseAndGrind/Resources/MotivationalLines"

if [[ ! -d "$source_dir" ]]; then
  echo "Motivational-line source directory not found: $source_dir" >&2
  exit 1
fi

shopt -s nullglob
source_files=("$source_dir"/*.mp3)
if ((${#source_files[@]} == 0)); then
  echo "No MP3 files found in: $source_dir" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/riseandgrind-motivational.XXXXXX")"
trap 'find "$staging_dir" -type f -delete 2>/dev/null || true; rmdir "$staging_dir" 2>/dev/null || true' EXIT

for source_file in "${source_files[@]}"; do
  file_name="${source_file##*/}"
  stem="${file_name%.mp3}"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$source_file" \
    -vn \
    -ac 1 \
    -ar 24000 \
    -af "silenceremove=start_periods=1:start_duration=0.04:start_threshold=-45dB:start_silence=0.05,areverse,silenceremove=start_periods=1:start_duration=0.08:start_threshold=-45dB:start_silence=0.10,areverse,loudnorm=I=-18:LRA=7:TP=-1.5" \
    -c:a aac \
    -profile:a aac_low \
    -b:a 40k \
    -movflags +faststart \
    "$staging_dir/Motivational-$stem.m4a"
done

encoded_files=("$staging_dir"/Motivational-*.m4a)
if ((${#encoded_files[@]} != ${#source_files[@]})); then
  echo "Expected ${#source_files[@]} clips, encoded ${#encoded_files[@]}." >&2
  exit 1
fi

mkdir -p "$output_dir"
find "$output_dir" -maxdepth 1 -type f -name 'Motivational-*.m4a' -delete
mv "${encoded_files[@]}" "$output_dir"/

echo "Prepared ${#encoded_files[@]} motivational clips in $output_dir"
