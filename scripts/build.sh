#!/usr/bin/env bash
# フェーズ2 変換：data/raw の小地域 Shapefile → Web 配信用 GeoJSON
#   data/out/shochiiki.geojson           … 採用する簡略化レベル（DEFAULT_LEVEL）
#   data/out/variants/shochiiki_*.geojson … 比較用の各レベル（full = 簡略化なし）
# 除外・dissolve はしない（report.md の判断待ち）。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=data/raw/r2ka31202.shp
OUT=data/out
LEVELS=(full 75% 50% 30% 20% 10%)
DEFAULT_LEVEL=50%
mkdir -p "$OUT/variants"

build() {
  local level=$1 dest=$2 simplify=()
  [ "$level" != full ] && simplify=(-simplify "$level" keep-shapes)
  # snap：隣接区域の境界座標の微小なずれを吸収して境界線を共有させる（report.md 8章）
  npx mapshaper -i "$SRC" snap encoding=shift_jis \
    -proj wgs84 \
    -each 'code=KEY_CODE, name=S_NAME, kihon1=KIHON1' \
    -filter-fields code,name,kihon1 \
    ${simplify[@]+"${simplify[@]}"} \
    -o "$dest" format=geojson precision=0.000001 force
}

for level in "${LEVELS[@]}"; do
  build "$level" "$OUT/variants/shochiiki_${level%\%}.geojson"
done
cp "$OUT/variants/shochiiki_${DEFAULT_LEVEL%\%}.geojson" "$OUT/shochiiki.geojson"

# preview.html が読み込むレベル一覧
printf '%s\n' "${LEVELS[@]%\%}" | python3 -c 'import json,sys; print(json.dumps({"default": sys.argv[1], "levels": sys.stdin.read().split()}))' \
  "${DEFAULT_LEVEL%\%}" > "$OUT/variants/levels.json"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 主要道路：data/osm/roads.osm（npm run fetch-roads で取得済み）を市域で切り抜く。ネットワークは使わない
# データ © OpenStreetMap contributors, ODbL 1.0
ogr2ogr -f GeoJSON "$TMP/roads_raw.geojson" data/osm/roads.osm -dialect sqlite \
  -sql "SELECT highway, name, hstore_get_value(other_tags, 'ref') AS ref, GEOMETRY FROM lines WHERE highway IS NOT NULL"
npx mapshaper -i "$TMP/roads_raw.geojson" \
  -clip "$OUT/variants/shochiiki_full.geojson" \
  -simplify interval=3m \
  -filter-fields highway,name,ref \
  -o "$OUT/roads.geojson" format=geojson precision=0.000001 force

# flat.html：背景地図なしの境界図。TopoJSON を埋め込むので file:// でそのまま開ける
# （mapshaper の標準出力は 64KB で切れるので、一時ファイルを経由する）
npx mapshaper -i "$OUT/shochiiki.geojson" "$OUT/roads.geojson" combine-files \
  -o "$TMP/flat.topojson" format=topojson quantization=1000000
python3 -c 'import sys; t=open(sys.argv[1]).read(); sys.stdout.write(t.replace("/*__TOPOJSON__*/null", open(sys.argv[2]).read().strip()))' \
  scripts/flat.template.html "$TMP/flat.topojson" > "$OUT/flat.html"

echo "built: $OUT/shochiiki.geojson (simplify $DEFAULT_LEVEL)"
