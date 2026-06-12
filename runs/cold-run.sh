#!/usr/bin/env bash
# cold-run.sh LABEL [run-spec.sh args...] — empties ~/.fhir/tx-cache for the run, restores after.
# The run's resulting cache is preserved at runs/LABEL-txcache for inspection.
set -euo pipefail
ROOT=/home/jmandel/hobby/fhir-perf
LABEL="$1"
TXC="$HOME/.fhir/tx-cache"
STASH="$HOME/.fhir/tx-cache.stash"
[[ -e "$STASH" ]] && { echo "stash already exists: $STASH — previous cold run did not clean up; aborting"; exit 1; }
mv "$TXC" "$STASH"
mkdir -p "$TXC"
restore() {
  rm -rf "$ROOT/runs/$LABEL-txcache"
  mv "$TXC" "$ROOT/runs/$LABEL-txcache" 2>/dev/null || true
  mv "$STASH" "$TXC"
}
trap restore EXIT
"$ROOT/runs/run-spec.sh" "$@"
