#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Direct execution of a dedicated probe without document-type declarations.
# Never invokes open, lsregister, or association setters.
exec /usr/bin/python3 "$ROOT/scripts/verify_m0.py" --webkit-only
