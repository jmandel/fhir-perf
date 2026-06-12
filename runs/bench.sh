#!/usr/bin/env bash
# Apples-to-apples benchmark matrix for the integrated FHIR spec build.
#
#   bench.sh <cell> [--kindling DIR] [--cp FILE]
#   cells: cold-local | warm-local | cold-remote | warm-remote | all
#
# Protocol (encodes lessons from the spike phase):
#  - Same checkout SHA, same JVM flags, -nopartial, serial runs (nothing else heavy on the box).
#  - COLD = tx-cache branch dir empty at start (cold-run.sh stash protocol).
#  - WARM = the cache produced by the SAME server's cold run (converged, then poison-checked).
#    Caches are NOT shared across servers: each server's responses prime its own cache.
#  - Remote runs: tx concurrency capped at 4 (tx.fhir.org sheds load above that); local runs: 12.
#  - One remote-cold run only (be polite to the public server).
#  - After each run: normalized-manifest diff vs reference (judge.sh) + error-summary parity check.
set -euo pipefail
ROOT=/home/jmandel/hobby/fhir-perf
KINDLING="${KINDLING_CLASSES:-$ROOT/tmp/worktrees/kindling-integrated/target/classes}"
CPFILE="${CORE_CP:-$ROOT/runs/classpath.core-txperf.txt}"
LOCAL_SETTINGS="$ROOT/runs/fhir-settings-localtx.json"
TXDIR="$HOME/.fhir/tx-cache/jmandel/fhir/master"
GCFLAGS="-XX:+UseParallelGC"

while [[ $# -gt 1 ]]; do
  case "$2" in
    --kindling) KINDLING="$3"; set -- "$1" "${@:4}";;
    --cp) CPFILE="$3"; set -- "$1" "${@:4}";;
    *) echo "unknown arg $2" >&2; exit 1;;
  esac
done

poison_check() { # warn if the cache holds permanently-cached transient server errors
  local hits
  hits=$(grep -l "Error performing tx5\|Error from http" "$TXDIR"/*.cache 2>/dev/null | wc -l || true)
  [[ "$hits" -gt 0 ]] && echo "WARNING: $hits poisoned cache files in $TXDIR (purge before warm runs)" || true
}

install_cache_from() { # install a preserved cold-run cache as the active warm cache
  local src="$1"
  [[ -d "$src/jmandel/fhir/master" ]] || { echo "no preserved cache at $src"; exit 1; }
  rm -rf "$TXDIR" && mkdir -p "$(dirname "$TXDIR")"
  cp -a "$src/jmandel/fhir/master" "$TXDIR"
}

run_cell() {
  local cell="$1" label settings tx flags
  case "$cell" in
    cold-local)
      "$ROOT/runs/cold-run.sh" bench-cold-local --kindling "$KINDLING" --cp "$CPFILE" \
        --jvm "$GCFLAGS -Dorg.hl7.fhir.tx.maxConcurrency=12" -- -fhir-settings "$LOCAL_SETTINGS"
      ;;
    warm-local)
      install_cache_from "$ROOT/runs/bench-cold-local-txcache"; poison_check
      "$ROOT/runs/run-spec.sh" bench-warm-local --kindling "$KINDLING" --cp "$CPFILE" \
        --jvm "$GCFLAGS -Dorg.hl7.fhir.tx.maxConcurrency=12" -- -fhir-settings "$LOCAL_SETTINGS"
      ;;
    cold-remote)
      "$ROOT/runs/cold-run.sh" bench-cold-remote --kindling "$KINDLING" --cp "$CPFILE" \
        --jvm "$GCFLAGS -Dorg.hl7.fhir.tx.maxConcurrency=4"
      ;;
    warm-remote)
      install_cache_from "$ROOT/runs/bench-cold-remote-txcache"; poison_check
      "$ROOT/runs/run-spec.sh" bench-warm-remote --kindling "$KINDLING" --cp "$CPFILE" \
        --jvm "$GCFLAGS -Dorg.hl7.fhir.tx.maxConcurrency=4"
      ;;
    *) echo "unknown cell: $cell" >&2; exit 1;;
  esac
}

if [[ "$1" == "all" ]]; then
  # order matters: each warm cell consumes its server's cold-run cache
  for c in cold-local warm-local cold-remote warm-remote; do
    echo "=== bench cell: $c"
    run_cell "$c"
  done
  echo "=== summary"
  for l in bench-cold-local bench-warm-local bench-cold-remote bench-warm-remote; do
    grep -h "Summary: Errors" "$ROOT/runs/$l.log" 2>/dev/null | sed "s/^/[$l] /" || true
    grep -h "^EXIT" "$ROOT/runs/$l.log" 2>/dev/null | sed "s/^/[$l] /" || true
  done
else
  run_cell "$1"
fi
