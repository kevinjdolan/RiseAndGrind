#!/usr/bin/env bash

# Converts the generated voice lines into small, iPhone-friendly bundled AAC files.

set -euo pipefail

source_dir="GeneratedSamples/motivational_lines"
output_dir="RiseAndGrind/Resources/MotivationalLines"

mkdir -p "$output_dir"

for source_file in "$source_dir"/*.mp3; do
  file_name="${source_file##*/}"
  stem="${file_name%.mp3}"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$source_file" \
    -vn \
    -ac 1 \
    -ar 24000 \
    -c:a aac \
    -profile:a aac_low \
    -b:a 40k \
    -movflags +faststart \
    "$output_dir/Motivational-$stem.m4a"
done
