#!/usr/bin/env bash
# Extract European country PMTiles from Protomaps daily planet build.
#
# Prerequisites:
#   npm install -g pmtiles    (or: go install github.com/protomaps/go-pmtiles/cmd/pmtiles@latest)
#
# Usage:
#   bash extract-europe-maps.sh [output_dir] [source_url]
#
# The script uses HTTP Range Requests — it does NOT download the full 120 GB planet file.
# Each country extraction takes 30s–5min depending on size and connection speed.

set -euo pipefail

OUTPUT_DIR="${1:-./pmtiles-europe}"
# Use latest Protomaps daily build by default
SOURCE="${2:-https://build.protomaps.com/20250315.pmtiles}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}->  ${NC}$*"; }
ok()   { echo -e "${GREEN} +  ${NC}$*"; }
warn() { echo -e "${YELLOW} !  ${NC}$*"; }

if ! command -v pmtiles &>/dev/null; then
    echo "Error: 'pmtiles' CLI not found."
    echo "Install: npm install -g pmtiles"
    echo "    or:  go install github.com/protomaps/go-pmtiles/cmd/pmtiles@latest"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

VERSION="2025-03"
MAXZOOM=14

# ── Country bounding boxes: [min_lon, min_lat, max_lon, max_lat] ─────────────
# Grouped by region for the installer

declare -A COUNTRIES
# Northern Europe
COUNTRIES["norway"]="4.0,57.9,31.2,71.2"
COUNTRIES["sweden"]="11.0,55.3,24.2,69.1"
COUNTRIES["finland"]="20.5,59.8,31.6,70.1"
COUNTRIES["denmark"]="8.0,54.5,15.2,57.8"
COUNTRIES["iceland"]="24.5,63.3,-13.5,66.6"
COUNTRIES["estonia"]="21.8,57.5,28.2,59.7"
COUNTRIES["latvia"]="20.9,55.7,28.2,58.1"
COUNTRIES["lithuania"]="20.9,53.9,26.8,56.5"

# British Isles
COUNTRIES["united_kingdom"]="8.2,49.9,1.8,60.9"
COUNTRIES["ireland"]="10.5,51.4,-5.3,55.4"

# Western Europe
COUNTRIES["france"]="5.2,42.3,8.2,51.1"
COUNTRIES["belgium"]="2.5,49.5,6.4,51.5"
COUNTRIES["netherlands"]="3.3,50.7,7.2,53.6"
COUNTRIES["luxembourg"]="5.7,49.4,6.5,50.2"

# Central Europe
COUNTRIES["germany"]="5.9,47.3,15.0,55.1"
COUNTRIES["poland"]="14.1,49.0,24.2,54.8"
COUNTRIES["czech_republic"]="12.1,48.5,18.9,51.1"
COUNTRIES["austria"]="9.5,46.4,17.2,49.0"
COUNTRIES["switzerland"]="5.9,45.8,10.5,47.8"
COUNTRIES["hungary"]="16.1,45.7,22.9,48.6"
COUNTRIES["slovakia"]="16.8,47.7,22.6,49.6"

# Southern Europe
COUNTRIES["spain"]="9.3,36.0,3.3,43.8"
COUNTRIES["portugal"]="9.5,36.9,-6.2,42.2"
COUNTRIES["italy"]="6.6,36.6,18.5,47.1"
COUNTRIES["greece"]="19.4,34.8,29.6,41.8"
COUNTRIES["malta"]="14.2,35.8,14.6,36.1"
COUNTRIES["cyprus"]="32.3,34.6,34.6,35.7"

# Southeastern Europe
COUNTRIES["romania"]="20.2,43.6,29.7,48.3"
COUNTRIES["bulgaria"]="22.4,41.2,28.6,44.2"
COUNTRIES["croatia"]="13.5,42.4,19.4,46.5"
COUNTRIES["slovenia"]="13.4,45.4,16.6,46.9"
COUNTRIES["serbia"]="18.8,42.2,23.0,46.2"
COUNTRIES["bosnia_herzegovina"]="15.7,42.5,19.6,45.3"
COUNTRIES["montenegro"]="18.4,41.9,20.4,43.6"
COUNTRIES["albania"]="19.3,39.6,21.1,42.7"
COUNTRIES["north_macedonia"]="20.4,40.8,23.0,42.4"
COUNTRIES["kosovo"]="20.0,41.8,21.8,43.3"

echo ""
echo "  Protomaps Europe Extractor"
echo "  Source: $SOURCE"
echo "  Output: $OUTPUT_DIR"
echo "  Max zoom: $MAXZOOM"
echo "  Countries: ${#COUNTRIES[@]}"
echo ""

FAILED=()
for country in $(echo "${!COUNTRIES[@]}" | tr ' ' '\n' | sort); do
    bbox="${COUNTRIES[$country]}"
    outfile="${OUTPUT_DIR}/${country}_${VERSION}.pmtiles"

    if [[ -f "$outfile" ]]; then
        ok "$country — already exists, skipping"
        continue
    fi

    info "Extracting $country ($bbox)..."
    if pmtiles extract "$SOURCE" "$outfile" \
        --bbox="$bbox" \
        --maxzoom="$MAXZOOM" \
        --download-threads=4 2>&1; then
        size=$(du -h "$outfile" | cut -f1)
        ok "$country — $size"
    else
        warn "$country — FAILED"
        FAILED+=("$country")
        rm -f "$outfile"  # clean up partial file
    fi
done

echo ""
echo "Done. Files in: $OUTPUT_DIR"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    warn "Failed: ${FAILED[*]}"
fi

# Print file sizes
echo ""
echo "  File sizes:"
du -h "$OUTPUT_DIR"/*.pmtiles 2>/dev/null | sort -h -r | while read -r size name; do
    basename_no_ext=$(basename "$name" .pmtiles)
    printf "    %-35s %s\n" "$basename_no_ext" "$size"
done
echo ""
total=$(du -sh "$OUTPUT_DIR" | cut -f1)
echo "  Total: $total"
