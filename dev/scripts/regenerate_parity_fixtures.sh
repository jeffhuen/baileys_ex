#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TSX="$ROOT_DIR/dev/reference/Baileys-master/node_modules/.bin/tsx"

cd "$ROOT_DIR"

"$TSX" dev/tools/generate_signal_fixtures.mts
node dev/scripts/generate_wam_definitions.mjs
"$TSX" dev/tools/generate_parity_vectors.mts
