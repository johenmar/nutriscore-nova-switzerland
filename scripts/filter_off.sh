#!/usr/bin/env bash
# ------------------------------------------------------------------
# Reduce the full Open Food Facts CSV export to the products and
# columns used in this project.
#
# Input : en.openfoodfacts.org.products.csv.gz
#         https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz
#         (tab-separated despite the .csv name; about 1.3 GB compressed)
# Output: data/off_ch_de_fr_subset.tsv.gz
#         products tagged as sold in Switzerland, Germany or France,
#         25 columns (identifiers, tags, scores, nutrients per 100 g)
#
# Usage : bash scripts/filter_off.sh path/to/en.openfoodfacts.org.products.csv.gz
# Runs in about one minute on a laptop. Works with GNU awk, mawk or BSD awk.
# Data licence: Open Database License (ODbL 1.0), Open Food Facts contributors.
# ------------------------------------------------------------------
set -euo pipefail

IN="${1:?give the path to en.openfoodfacts.org.products.csv.gz}"
OUT="data/off_ch_de_fr_subset.tsv.gz"
AWK="${AWK:-$(command -v mawk || command -v awk)}"
mkdir -p data

COLS="code created_t last_modified_t product_name brands categories_tags countries_tags additives_n nutriscore_score nutriscore_grade nova_group pnns_groups_1 pnns_groups_2 food_groups_en unique_scans_n completeness main_category_en energy-kcal_100g fat_100g saturated-fat_100g carbohydrates_100g sugars_100g fiber_100g proteins_100g salt_100g"

gzip -dc "$IN" |
  { IFS= read -r header; printf '%s\n' "$header"; grep -E 'en:(switzerland|germany|france)' || true; } |
  "$AWK" -F'\t' -v cols="$COLS" '
    BEGIN { OFS = "\t"; n = split(cols, want, " ") }
    NR == 1 {
      ncol = NF
      for (i = 1; i <= NF; i++) pos[$i] = i
      for (j = 1; j <= n; j++) { if (!(want[j] in pos)) { print "missing column: " want[j] > "/dev/stderr"; exit 1 }; idx[j] = pos[want[j]] }
      ctry = pos["countries_tags"]
      line = $idx[1]; for (j = 2; j <= n; j++) line = line OFS $idx[j]; print line; next
    }
    NF != ncol { bad++; next }                                   # malformed rows (none in the Sept 2026 export)
    $ctry !~ /en:(switzerland|germany|france)/ { next }         # grep matched outside the countries field
    { kept++; line = $idx[1]; for (j = 2; j <= n; j++) line = line OFS $idx[j]; print line }
    END { printf "kept %d products, skipped %d malformed rows\n", kept, bad > "/dev/stderr" }' |
  gzip -6 > "$OUT"

echo "written: $OUT"
