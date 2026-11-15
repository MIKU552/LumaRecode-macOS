#!/usr/bin/env bash
# Real media checks based on Windows qa/FormatChecks/check_formats.py.
# Uses the actual native Swift CLI; no mocked ffprobe result.
set -euxo pipefail

WORK="$RUNNER_TEMP/luma-parity-$$"
mkdir -p "$WORK"
trap 'code=$?; echo "Media parity failed at line $LINENO: $BASH_COMMAND (exit $code)" >&2; for f in "$WORK"/*.jsonl; do if [ -f "$f" ]; then echo "== $f ==" >&2; tail -n 12 "$f" >&2; fi; done; exit "$code"' ERR
trap 'rm -rf "$WORK"' EXIT
CLI="$(swift build --package-path macOS/Packages/LumaCore --configuration release --show-bin-path)/lumarecode"
test -x "$CLI"

SOURCE="$WORK/two-audio.mp4"
ARCHIVE="$WORK/two-audio-archive.mkv"
OPUS="$WORK/two-audio-opus.mkv"
INVALID="$WORK/invalid-444.mkv"

# Preserve two independent audio tracks, not only the first.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=duration=0.8:size=160x96:rate=24' \
  -f lavfi -i 'sine=frequency=440:duration=0.8' \
  -f lavfi -i 'sine=frequency=880:duration=0.8' \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 \
  -c:v libx264 -pix_fmt yuv420p \
  -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' \
  -c:a aac -shortest "$SOURCE"

"$CLI" convert "$SOURCE" --purpose archive --codec hevc \
  --audio copy --output "$ARCHIVE" --json > "$WORK/copy.jsonl"
test -s "$ARCHIVE"
test "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$ARCHIVE" | wc -l | tr -d ' ')" -eq 2
test "$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$ARCHIVE" | grep -c '^aac$')" -eq 2
grep -q '"event":"done"' "$WORK/copy.jsonl"

"$CLI" convert "$SOURCE" --purpose archive --codec hevc \
  --audio opus --output "$OPUS" --json > "$WORK/opus.jsonl"
test -s "$OPUS"
test "$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$OPUS" | grep -c '^opus$')" -eq 2
grep -q '"event":"done"' "$WORK/opus.jsonl"

# Source 4:2:0 -> 4:4:4 must be rejected before output is published.
if "$CLI" convert "$SOURCE" --purpose archive --codec hevc \
  --sampling 444 --output "$INVALID" --json > "$WORK/invalid.jsonl"; then
  echo "ERROR: source chroma upsampling was accepted unexpectedly" >&2
  exit 1
fi
test ! -e "$INVALID"
grep -q '"event":"error"' "$WORK/invalid.jsonl"

# Sample range is a pixel conversion, not merely a metadata relabel.
FULL="$WORK/full-range.mp4"
LIMITED="$WORK/limited-range.mkv"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=duration=0.6:size=160x96:rate=24' \
  -vf 'format=yuv420p,setparams=range=full' \
  -c:v libx264 -pix_fmt yuv420p \
  -x264-params 'fullrange=on:colorprim=bt709:transfer=bt709:colormatrix=bt709' \
  -color_range pc "$FULL"
test "$(ffprobe -v error -select_streams v:0 -show_entries stream=color_range -of default=nw=1:nk=1 "$FULL")" = "pc"
"$CLI" convert "$FULL" --purpose archive --codec hevc \
  --range limited --output "$LIMITED" --json > "$WORK/limited.jsonl"
test "$(ffprobe -v error -select_streams v:0 -show_entries stream=color_range -of default=nw=1:nk=1 "$LIMITED")" = "tv"
grep -q '"event":"done"' "$WORK/limited.jsonl"

echo "PASS: two-track copy, two-track Opus, invalid chroma refusal, and full→limited conversion."
