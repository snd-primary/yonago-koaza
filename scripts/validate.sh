#!/usr/bin/env bash
# フェーズ2 検証：data/out の GeoJSON を入力と比べ、data/out/validation.md に書き出す
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=data/raw/r2ka31202.shp
OUT=data/out
REPORT=$OUT/validation.md
EXCLUDED=0   # 除外した件数（除外の指示があればここが変わる）

q() { ogr2ogr -f CSV /vsistdout/ "$2" -dialect sqlite -sql "$1" | tail -n +2; }

# 1レイヤ分の統計：件数, 空, 不正, 面積合計(m²), 隙間数, 1m²超の隙間, 重なり面積合計(m²), bbox
stats() {
  local f=$1 l
  l=$(ogrinfo -q -so "$f" | sed -n 's/^1: \([^ ]*\).*/\1/p')
  q "WITH RECURSIVE u AS (SELECT ST_Union(GEOMETRY) g FROM \"$l\"),
     r(i) AS (SELECT 1 WHERE ST_NRings(ST_GeometryN((SELECT g FROM u),1)) > 1
              UNION ALL SELECT i+1 FROM r,u WHERE i < ST_NRings(ST_GeometryN(u.g,1))-1),
     gaps AS (SELECT ST_Area(MakePolygon(ST_InteriorRingN(ST_GeometryN(u.g,1),i)),1) a FROM r,u),
     ov AS (SELECT ST_Area(CollectionExtract(ST_Intersection(a.GEOMETRY,b.GEOMETRY),3),1) a
            FROM \"$l\" a, \"$l\" b WHERE a.ROWID<b.ROWID AND ST_Overlaps(a.GEOMETRY,b.GEOMETRY))
     SELECT COUNT(*),
            SUM(GEOMETRY IS NULL OR ST_IsEmpty(GEOMETRY)),
            SUM(NOT ST_IsValid(GEOMETRY)),
            SUM(ST_Area(GEOMETRY,1)),
            (SELECT COUNT(*) FROM gaps), (SELECT COALESCE(SUM(a>1),0) FROM gaps),
            (SELECT COALESCE(SUM(a),0) FROM ov),
            MIN(MbrMinX(GEOMETRY)), MIN(MbrMinY(GEOMETRY)), MAX(MbrMaxX(GEOMETRY)), MAX(MbrMaxY(GEOMETRY))
     FROM \"$l\"" "$f"
}

IFS=, read -r N0 _ _ AREA0 _ _ _ X0 Y0 X1 Y1 < <(stats "$SRC")
EPS=0.000001  # 座標を 6 桁に丸めた分の許容

{
  echo "# フェーズ2 検証結果"
  echo
  echo "- 入力：\`$SRC\`（$N0 件）／除外：$EXCLUDED 件／除外後：$((N0 - EXCLUDED)) 件"
  echo "- 入力の bbox（米子市の範囲として使用）：$X0, $Y0 – $X1, $Y1"
  echo "- 面積は楕円体上で計算（m²）。入力の合計 $(printf '%.0f' "$AREA0") m²"
  echo
  echo "| ファイル | サイズ | 件数 | 空 | 不正 | 合計面積の変化 | 区域間の隙間（うち 1m² 超） | 重なり面積 | bbox が範囲内 |"
  echo "|---|---|---|---|---|---|---|---|---|"
  for f in "$OUT/shochiiki.geojson" "$OUT"/variants/shochiiki_*.geojson; do
    IFS=, read -r n empty invalid area gaps gaps1 ov x0 y0 x1 y1 < <(stats "$f")
    inside=$(python3 -c "
a=[float(v) for v in '$x0 $y0 $x1 $y1'.split()]; b=[float(v) for v in '$X0 $Y0 $X1 $Y1'.split()]; e=$EPS
print('○' if a[0]>=b[0]-e and a[1]>=b[1]-e and a[2]<=b[2]+e and a[3]<=b[3]+e else '×')")
    size=$(stat -f %z "$f")
    printf '| %s | %s KB | %s | %s | %s | %+.3f%% | %s (%s) | %.1f m² | %s |\n' \
      "${f#$OUT/}" "$((size / 1024))" "$n" "$empty" "$invalid" \
      "$(python3 -c "print(($area - $AREA0) / $AREA0 * 100)")" "$gaps" "$gaps1" "$ov" "$inside"
  done
  echo
  echo "## 名前の抜き出し（shochiiki.geojson）"
  echo
  echo '```'
  q "SELECT code, name, kihon1 FROM shochiiki WHERE code IN
     ('312020010','31202003001','31202048100','31202057203','312021110','31202117002','31202130006','31202132002')" \
    "$OUT/shochiiki.geojson"
  echo '```'
} > "$REPORT"

cat "$REPORT"
