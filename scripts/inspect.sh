#!/usr/bin/env bash
# フェーズ1 調査：data/raw の小地域 Shapefile を調べ、結果を data/inspect/ に書き出す。
# data/raw は読み取りのみ。report.md の数値はこの出力が根拠。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=data/raw/r2ka31202.shp
LAYER=r2ka31202
OUT=data/inspect
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

q() { ogr2ogr -f CSV /vsistdout/ "${2:-$SRC}" -dialect sqlite -sql "$1"; }

# 共通：あるレイヤの「全区域を合わせた形」に残る隙間（穴）の数と面積
gaps_sql() {
  cat <<SQL
WITH RECURSIVE u AS (SELECT ST_Union(GEOMETRY) g FROM $1),
r(i) AS (SELECT 1 WHERE ST_NRings(ST_GeometryN((SELECT g FROM u),1)) > 1
         UNION ALL SELECT i+1 FROM r,u WHERE i < ST_NRings(ST_GeometryN(u.g,1))-1)
SELECT (SELECT ST_NumGeometries(g) FROM u) union_parts, COUNT(a) gaps,
       MAX(a) max_m2, SUM(a) sum_m2, COALESCE(SUM(a>1),0) gaps_over_1m2
FROM (SELECT ST_Area(MakePolygon(ST_InteriorRingN(ST_GeometryN(u.g,1),i)),1) a FROM r,u)
SQL
}

{
  echo "## prj"; cat "${SRC%.shp}.prj"; echo
  echo "## cpg"; ls "${SRC%.shp}".cpg 2>/dev/null || echo "(なし)"
  echo "## dbf LDID (byte 29)"; xxd -s 29 -l 1 -p "${SRC%.shp}.dbf"
  echo "## ogrinfo"; ogrinfo -so -al "$SRC" | sed '/^Layer SRS WKT/,/^Data axis/d'
} > "$OUT/basic.txt"

# 文字コード：mapshaper で Shift_JIS として読んだ名前（GDAL の読みと照合用）
npx mapshaper -i "$SRC" encoding=shift_jis -each 'n=S_NAME' -filter-fields KEY_CODE,S_NAME \
  -o "$TMP/names_sjis.csv" 2>/dev/null
q "SELECT KEY_CODE, S_NAME FROM $LAYER" > "$TMP/names_gdal.csv"
if diff -q <(sort "$TMP/names_sjis.csv" | tr -d '"') <(sort "$TMP/names_gdal.csv" | tr -d '"') >/dev/null; then
  echo "mapshaper(shift_jis) と GDAL(LDID) の読みは全件一致" > "$OUT/encoding.txt"
else
  echo "mapshaper と GDAL の読みが一致しない" > "$OUT/encoding.txt"
fi
grep -c '�' "$TMP/names_gdal.csv" | sed 's/^/置換文字(U+FFFD)を含む行: /' >> "$OUT/encoding.txt" || true

q "SELECT * FROM $LAYER LIMIT 3" > "$OUT/sample_rows.csv"
q "SELECT HCODE, COUNT(*) n FROM $LAYER GROUP BY HCODE" > "$OUT/hcode.csv"
for f in KIGO_E KIGO_D KIGO_I AREA_MAX_F N_KEN N_CITY; do
  q "SELECT '$f' field, $f value, COUNT(*) n FROM $LAYER GROUP BY $f"
done > "$OUT/kigo.csv"
q "SELECT KEY_CODE,S_NAME,KIGO_E,AREA_MAX_F,JINKO,SETAI,KBSUM,AREA FROM $LAYER
   WHERE TRIM(COALESCE(KIGO_E,''))<>'' OR TRIM(COALESCE(KIGO_D,''))<>'' OR TRIM(COALESCE(KIGO_I,''))<>''
   ORDER BY KEY_CODE" > "$OUT/kigo_rows.csv"
q "SELECT KEY_CODE,S_NAME,KIGO_E,JINKO,SETAI,AREA FROM $LAYER WHERE JINKO=0 ORDER BY KEY_CODE" > "$OUT/pop_zero.csv"
q "SELECT COUNT(*) n, COUNT(DISTINCT KEY_CODE) keys, COUNT(DISTINCT S_NAME) names,
          SUM(JINKO) jinko, SUM(SETAI) setai, SUM(AREA) area_m2 FROM $LAYER" > "$OUT/totals.csv"

# 名前一覧（KEY_CODE 順）。KEY_CODE は 9 桁と 11 桁が混ざるので S_AREA（6桁固定）で並べる
q "SELECT KEY_CODE,S_AREA,KIHON1,KIHON2,S_NAME,KIGO_E,HCODE,JINKO,SETAI,ROUND(AREA) area_m2
   FROM $LAYER ORDER BY S_AREA, KIGO_E" > "$OUT/names.csv"

# 名前のパターン
q "SELECT KEY_CODE,S_NAME FROM $LAYER WHERE S_NAME LIKE '%丁目' ORDER BY S_AREA" > "$OUT/pat_chome.csv"
q "SELECT KEY_CODE,S_NAME FROM $LAYER WHERE S_NAME LIKE '大字%' ORDER BY S_AREA" > "$OUT/pat_oaza.csv"
q "SELECT S_NAME, COUNT(*) n, GROUP_CONCAT(KEY_CODE) keys FROM $LAYER GROUP BY S_NAME HAVING n>1" > "$OUT/pat_dup_name.csv"
# 「丁目」を取り除いた名前でのグループ（2件以上）
awk -F, 'NR>1 { n=$5; gsub(/"/,"",n); b=n; sub(/[一二三四五六七八九〇十]+丁目$/,"",b); c[b]++; m[b]=m[b] (m[b]?" / ":"") n }
  END { print "base,n,members"; for (k in c) if (c[k]>1) print k "," c[k] "," m[k] }' "$OUT/names.csv" \
  | (read -r h; echo "$h"; sort) > "$OUT/pat_chome_groups.csv"
# 町字コード（KIHON1）でのグループ（2件以上）
q "SELECT KIHON1, COUNT(*) n, GROUP_CONCAT(S_NAME,' / ') members FROM
   (SELECT * FROM $LAYER ORDER BY S_AREA) GROUP BY KIHON1 HAVING n>1 ORDER BY KIHON1" > "$OUT/pat_kihon1_groups.csv"

# ジオメトリ
q "SELECT ST_GeometryType(GEOMETRY) type, ST_NumGeometries(GEOMETRY) parts, COUNT(*) n FROM $LAYER GROUP BY 1,2" > "$OUT/geom_types.csv"
q "SELECT SUM(GEOMETRY IS NULL OR ST_IsEmpty(GEOMETRY)) empty, SUM(NOT ST_IsValid(GEOMETRY)) invalid,
          SUM(ST_NRings(GEOMETRY)-1) holes FROM $LAYER" > "$OUT/geom_validity.csv"
q "SELECT KEY_CODE,S_NAME,ST_IsValidReason(GEOMETRY) reason FROM $LAYER WHERE NOT ST_IsValid(GEOMETRY)" > "$OUT/geom_invalid.csv"
q "SELECT COUNT(*) overlap_pairs, MAX(ST_Area(CollectionExtract(ST_Intersection(a.GEOMETRY,b.GEOMETRY),3),1)) max_m2,
          SUM(ST_Area(CollectionExtract(ST_Intersection(a.GEOMETRY,b.GEOMETRY),3),1)) sum_m2
   FROM $LAYER a, $LAYER b WHERE a.ROWID<b.ROWID AND ST_Overlaps(a.GEOMETRY,b.GEOMETRY)" > "$OUT/geom_overlaps.csv"
q "$(gaps_sql $LAYER)" > "$OUT/geom_gaps_raw.csv"

# 簡略化で隙間ができるか（snap なし / あり）。出力は一時ファイルのみ
for mode in nosnap snap; do
  opt=""; [ "$mode" = snap ] && opt="snap"
  npx mapshaper -i "$SRC" encoding=shift_jis $opt -simplify 5% keep-shapes -o "$TMP/s_$mode.shp" 2>/dev/null
  q "$(gaps_sql "s_$mode")" "$TMP/s_$mode.shp" | sed "1s/^/mode,/;2s/^/$mode,/"
done > "$OUT/simplify_gap_test.csv"

echo "wrote $OUT/"
