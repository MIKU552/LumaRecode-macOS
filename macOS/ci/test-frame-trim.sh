#!/usr/bin/env bash
# End-to-end parity test: actual Swift CLI + FFmpeg, not argument snapshots.
# Verify decoded display-frame counts on H.264 B-frame input, trimmed audio,
# and refusal to copy uncut audio or publish an invalid output.
set -euxo pipefail

WORK="\${RUNNER_TEMP:-/tmp}/luma-frame-trim-$$"
mkdir -p "$WORK"
trap 'status=$?; for f in "$WORK"/*.jsonl; do if [[ -f "$f" ]]; then echo "== $f ==" >&2; tail -n 20 "$f" >&2; fi; done; rm -rf "$WORK"; exit "$status"' EXIT
CLI="$(swift build --package-path macOS/Packages/LumaCore \
  --configuration release --show-bin-path)/lumarecode"
test -x "$CLI"

SOURCE="$WORK/source-bframes.mp4"
CLIP="$WORK/trim-frames.mkv"
TIME_CLIP="$WORK/trim-time.mkv"
BAD="$WORK/uncut-audio.mkv"

# Thirty-six distinct 24-fps frames, with B frames and an AAC audio track.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=duration=1.5:size=160x96:rate=24' \
  -f lavfi -i 'sine=frequency=880:duration=1.5' \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset medium -bf 3 -g 12 -pix_fmt yuv420p \
  -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' \
  -c:a aac -b:a 128k "$SOURCE"

"$CLI" frames "$SOURCE" > "$WORK/source-index.json"
python3 - "$WORK/source-index.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as file:
    frames = json.load(file)
assert frames["frames"] == 36, frames
assert frames["time_base"], frames
print("PTS index:", frames)
PY

# CLI frame numbers are zero-based, with end excluded: [6,19) = 13 frames.
"$CLI" plan "$SOURCE" --purpose archive --codec hevc \
  --start-frame 6 --end-frame 19 --output "$CLIP" > "$WORK/plan.jsonl"
grep -q 'trim=start_frame=6:end_frame=19' "$WORK/plan.jsonl"
grep -q '"expected_frames":13' "$WORK/plan.jsonl"
grep -q '"effective_audio":"aac"' "$WORK/plan.jsonl"

"$CLI" convert "$SOURCE" --purpose archive --codec hevc \
  --start-frame 6 --end-frame 19 --output "$CLIP" > "$WORK/clip.jsonl"
test -s "$CLIP"
COUNT="$(ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$CLIP")"
test "$COUNT" = "13"
AUDIO="$(ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name -of default=nw=1:nk=1 "$CLIP")"
test "$AUDIO" = "aac"
grep -q '"event":"done"' "$WORK/clip.jsonl"
grep -q '"frames":13' "$WORK/clip.jsonl"

# Time-based range is mapped through the source PTS index, never frameRate * t.
"$CLI" plan "$SOURCE" --purpose archive --codec hevc \
  --start-time 0.25 --end-time 0.7916666667 \
  --output "$TIME_CLIP" > "$WORK/time-plan.jsonl"
grep -q '"expected_frames":13' "$WORK/time-plan.jsonl"

# A trim cannot stream-copy audio; fail before writing any output.
if "$CLI" convert "$SOURCE" --purpose archive --codec hevc \
  --audio copy --start-frame 6 --end-frame 19 \
  --output "$BAD" > "$WORK/invalid.jsonl"; then
  echo "ERROR: frame trim unexpectedly copied uncut audio" >&2
  exit 1
fi
test ! -e "$BAD"
grep -q '"event":"error"' "$WORK/invalid.jsonl"
echo "PASS: exact 13-frame B-frame trim, re-encoded audio, PTS/time mapping, failure isolation."
