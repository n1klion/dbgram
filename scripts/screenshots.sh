#!/bin/bash
# Regenerates the README screenshots in docs/images from the sample schemas.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product DBGram
BIN="$(swift build --show-bin-path)/DBGram"
mkdir -p docs/images

shot() {  # shot <output> <schema> [ENV=value ...]
  local out=$1 schema=$2; shift 2
  env DBGRAM_SCREENSHOT="$PWD/docs/images/$out" "$@" "$BIN" "$schema" >/dev/null 2>&1
  echo "docs/images/$out"
}

shot overview-dark.png      samples/shop.dbml   DBGRAM_APPEARANCE=dark  DBGRAM_SELECT_TABLE=orders
shot relationship-light.png samples/shop.dbml   DBGRAM_APPEARANCE=light DBGRAM_SELECT_REF=orders.customer_id
shot social-light.png       samples/social.dbml DBGRAM_APPEARANCE=light DBGRAM_SELECT_TABLE=posts
