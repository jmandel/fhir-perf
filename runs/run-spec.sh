#!/usr/bin/env bash
# Measured spec-build run with optional kindling substitution.
# Usage: run-spec.sh LABEL [--kindling /path/to/target/classes] [--jvm "EXTRA FLAGS"] [-- publisher args]
set -euo pipefail
ROOT=/home/jmandel/hobby/fhir-perf
LABEL="$1"; shift
KINDLING_SUB=""
CPFILE="$ROOT/runs/classpath.txt"
JVM_EXTRA=()
ARGS=(-nosound -nopartial)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cp) CPFILE="$2"; shift 2;;
    --kindling) KINDLING_SUB="$2"; shift 2;;
    --jvm) read -ra f <<< "$2"; JVM_EXTRA+=("${f[@]}"); shift 2;;
    --) shift; ARGS+=("$@"); break;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
CP="$(cat "$CPFILE")"
if [[ -n "$KINDLING_SUB" ]]; then
  CP="$KINDLING_SUB:$(tr ':' '\n' < "$CPFILE" | grep -v '/kindling-' | paste -sd:)"
fi
cd "$HOME/work/fhir"
start=$(date +%s)
set +e
java -Xmx14g -Xms4g "${JVM_EXTRA[@]}" -Dfile.encoding=UTF-8 -cp "$CP" \
  org.hl7.fhir.tools.publisher.Publisher "${ARGS[@]}" 2>&1 \
  | stdbuf -oL gawk '{ print strftime("[%H:%M:%S]"), $0; fflush() }' > "$ROOT/runs/$LABEL.log"
rc=${PIPESTATUS[0]}
set -e
end=$(date +%s)
echo "EXIT:$rc DURATION:$((end-start))s" >> "$ROOT/runs/$LABEL.log"
python3 "$ROOT/runs/manifest.py" "$HOME/work/fhir/publish" > "$ROOT/runs/$LABEL.manifest"
ndiff=$(diff <(cut -f2- "$ROOT/runs/ref.manifest" 2>/dev/null) <(cut -f2- "$ROOT/runs/$LABEL.manifest") | grep -c '^[<>]' || true)
hdiff=$(diff "$ROOT/runs/ref.manifest" "$ROOT/runs/$LABEL.manifest" 2>/dev/null | grep -c '^[<>]' || true)
echo "RESULT $LABEL: duration=$((end-start))s rc=$rc file-set-diff=$ndiff content-diff-lines=$hdiff"
