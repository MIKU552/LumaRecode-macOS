#!/usr/bin/env bash
# HDR10 Mastering Display / MaxCLL / MaxFALL retention with external FFmpeg.
set -euxo pipefail

WORK="$RUNNER_TEMP/luma-static-hdr10-$$"
mkdir -p "$WORK"
trap 'status=$?; for f in "$WORK"/*.jsonl; do if [[ -f "$f" ]]; then echo "== $f ==" >&2; tail -n 20 "$f" >&2; fi; done; exit "$status"' EXIT
CLI="$(swift build --package-path macOS/Packages/LumaCore --configuration release --show-bin-path)/lumarecode"
test -x "$CLI"
SOURCE="$WORK/source-hdr10.mkv"
OUT="$WORK/retained-hdr10.mkv"
DENY="$WORK/unverified-av1.mkv"

# Exact HEVC SEI units: BT.2020 primaries, 1000 nit peak, .005 nit black.
MASTER='G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)'
ffmpeg -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i 'testsrc2=duration=0.7:size=160x96:rate=12' \
  -vf 'format=yuv420p10le' \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
  -x265-params "log-level=error:hdr10=1:hdr10-opt=1:repeat-headers=1:master-display=$MASTER:max-cll=1000,400:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -color_range tv -an "$SOURCE"

"$CLI" probe "$SOURCE" > "$WORK/probe.json"
python3 - "$WORK/probe.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf8") as f:
    meta = json.load(f)
assert meta["sourceColor"] == "pq", meta
assert meta["staticHDRMetadataPresent"] is True, meta
m = meta["hdrStaticMetadata"]
assert m is not None, meta
assert abs(m["masteringDisplay"]["red_x"] - 0.68) < 1e-8, m
assert abs(m["masteringDisplay"]["max_luminance"] - 1000) < 1e-8, m
assert m["contentLight"] == {"max_content": 1000, "max_average": 400}, m
PY

"$CLI" plan "$SOURCE" --codec hevc --purpose archive \
  --output "$OUT" > "$WORK/plan.jsonl"
grep -Fq "master-display=$MASTER" "$WORK/plan.jsonl"
grep -Fq "max-cll=1000,400" "$WORK/plan.jsonl"

"$CLI" convert "$SOURCE" --codec hevc --purpose archive \
  --output "$OUT" > "$WORK/output.jsonl"
test -s "$OUT"
grep -q '"event":"done"' "$WORK/output.jsonl"

python3 - "$SOURCE" "$OUT" <<'PY'
import json, subprocess, sys
def metadata(path):
    raw = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-read_intervals", "%+#2", "-show_frames", "-of", "json", path
    ])
    doc = json.loads(raw)
    result = {}
    for side in doc["frames"][0]["side_data_list"]:
        if side["side_data_type"] in (
            "Mastering display metadata", "Content light level metadata"
        ):
            result[side["side_data_type"]] = side
    return result
source, out = metadata(sys.argv[1]), metadata(sys.argv[2])
assert "Mastering display metadata" in source, source
assert "Content light level metadata" in source, source
assert source == out, (source, out)
stream = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams",
    "-of", "json", sys.argv[2]
]))["streams"][0]
assert stream["codec_name"] == "hevc", stream
assert stream["color_primaries"] == "bt2020", stream
assert stream["color_transfer"] == "smpte2084", stream
assert stream["color_space"] == "bt2020nc", stream
assert stream["pix_fmt"] == "yuv420p10le", stream
print("PASS: static HDR10 mastering display and content light unchanged", out)
PY

if "$CLI" convert "$SOURCE" --codec av1 --purpose archive \
  --output "$DENY" > "$WORK/rejected.jsonl"; then
  echo "Unexpectedly accepted static-HDR AV1 path" >&2
  exit 1
fi
test ! -e "$DENY"
grep -q '"event":"error"' "$WORK/rejected.jsonl"
