#!/usr/bin/env bash
# OpenStreetMap から米子市周辺の主要道路を取得し、data/osm/ に保存する（ネットワークを使うのはこのスクリプトだけ）
# データ © OpenStreetMap contributors, ODbL 1.0
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=data/osm
ENDPOINT=https://overpass-api.de/api/interpreter
# 小地域データの範囲（133.227–133.481, 35.374–35.501）に少し余白を足したもの。市域での切り抜きは build で行う
BBOX="35.36,133.21,35.52,133.50"
HIGHWAY='^(motorway|trunk|primary|secondary)(_link)?$'
mkdir -p "$OUT"

QUERY="[out:xml][timeout:90];
way[\"highway\"~\"$HIGHWAY\"]($BBOX);
(._;>;);
out body;"

curl -sS --fail --retry 2 --data-urlencode "data=$QUERY" -A "yonago-koaza (github.com/snd-primary/yonago-koaza)" \
  "$ENDPOINT" -o "$OUT/roads.osm.tmp"
grep -q '<way ' "$OUT/roads.osm.tmp" || { echo "道路が取得できなかった" >&2; rm -f "$OUT/roads.osm.tmp"; exit 1; }
mv "$OUT/roads.osm.tmp" "$OUT/roads.osm"

cat > "$OUT/roads.meta.json" <<EOF
{
  "source": "OpenStreetMap via Overpass API ($ENDPOINT)",
  "license": "ODbL 1.0 — © OpenStreetMap contributors",
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bbox_lat_lon": "$BBOX",
  "highway": "$HIGHWAY"
}
EOF
echo "saved $OUT/roads.osm ($(grep -c '<way ' "$OUT/roads.osm") ways)"
