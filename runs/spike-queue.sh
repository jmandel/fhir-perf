#!/usr/bin/env bash
set -uo pipefail
cd /home/jmandel/hobby/fhir-perf/runs
W=/home/jmandel/hobby/fhir-perf/tmp/worktrees
GCFLAGS="-XX:+DisableExplicitGC -XX:+UseParallelGC"
run() {
  local label="$1" wt="$2" flags="$3"
  if [[ ! -d "$W/$wt/target/classes" ]]; then echo "RESULT $label: SKIP no classes"; return; fi
  ./run-spec.sh "$label" --kindling "$W/$wt/target/classes" --jvm "$flags"
  rsync -a --delete --link-dest=../ref-publish "$HOME/work/fhir/publish/" "$label-publish/"
  ./judge.sh "$label" || true
}
# s1 removes gc() in code: run WITHOUT DisableExplicitGC to prove the code fix
run s1 kindling-s1 "-XX:+UseParallelGC"
run s2 kindling-s2 "$GCFLAGS"
run s3 kindling-s3 "$GCFLAGS"
run s4 kindling-s4 "$GCFLAGS"
run s5 kindling-s5 "$GCFLAGS"
run s6 kindling-s6 "$GCFLAGS"
echo "QUEUE-DONE"
