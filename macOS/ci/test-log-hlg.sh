#!/usr/bin/env bash
# Uses user-installed ffmpeg-full on CI and byte-identical bundled Windows LUT.
# End-to-end Log -> HLG metadata, 10-bit precision, and incorrect-source refusal.
set -euxo pipefail
WORK="$RUNNER_TEMP/log-hlg-ci"
mkdir -p "$WORK"
trap 'status=$?; for f in "$WORK"/*.jsonl; do if [[ -f "$f" ]]; then echo "== $f ==" >&2; tail -n 25 "$f" >&2; fi; done; exit "$status"' EXIT
CLI="$(swift build --package-path macOS/Packages/LumaCore --configuration release --show-bin-path)/lumarecode"
SOURCE="$WORK/camera-log.mkv"
OUT="$WORK/hlg.mkv"
BAD="$WORK/invalid-log.mkv"
ffmpeg -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i 'testsrc2=duration=0.5:size=160x96:rate=12' \
  -vf 'format=yuv420p10le' -c:v libx265 -preset ultrafast \
  -x265-params 'log-level=error' -pix_fmt yuv420p10le \
  -an "$SOURCE"

# Unknown camera color must not be silently treated as Log.
if "$CLI" convert "$SOURCE" --purpose archive --codec hevc \
   --log-profile applelog --output "$BAD" > "$WORK/bad.jsonl"; then
   echo "ERROR: unconfirmed camera Log source was accepted" >&2
   exit 1
fi
test ! -e "$BAD"
grep -q '"event":"error"' "$WORK/bad.jsonl"

"$CLI" plan "$SOURCE" --purpose archive --codec hevc \
  --log-profile applelog --interpret-log --output "$OUT" > "$WORK/plan.jsonl"
grep -q 'lut3d=file=' "$WORK/plan.jsonl"
grep -q 'interp=tetrahedral' "$WORK/plan.jsonl"
grep -q '"log_profile":"applelog"' "$WORK/plan.jsonl"

"$CLI" convert "$SOURCE" --purpose archive --codec hevc \
  --log-profile applelog --interpret-log --output "$OUT" > "$WORK/convert.jsonl"
test -s "$OUT"
grep -q '"event":"done"' "$WORK/convert.jsonl"
python3 - "$OUT" <<'PY'
import json, subprocess, sys
data = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_streams", "-of", "json", sys.argv[1]
]))
stream = data["streams"][0]
assert stream["codec_name"] == "hevc", stream
assert stream["pix_fmt"] == "yuv420p10le", stream
assert stream["color_primaries"] == "bt2020", stream
assert stream["color_transfer"] == "arib-std-b67", stream
assert stream["color_space"] == "bt2020nc", stream
assert stream["color_range"] == "tv", stream
print("PASS: original Apple Log LUT -> 10-bit BT.2100 HLG", stream)
PY
