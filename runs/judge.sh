#!/usr/bin/env bash
# judge.sh LABEL — list spike-run diffs vs ref that are NOT explained by known noise
set -euo pipefail
cd /home/jmandel/hobby/fhir-perf/runs
LABEL="$1"
join -t$'\t' -j2 <(sort -t$'\t' -k2 ref.manifest) <(sort -t$'\t' -k2 "$LABEL.manifest") \
  | awk -F'\t' '$2!=$3{print $1}' > "$LABEL.diff-files"
total=$(wc -l < "$LABEL.diff-files")
unexplained=$(grep -vE '\.shex(\.html)?$' "$LABEL.diff-files" | grep -vxFf noise-files-v2.txt || true)
echo "== $LABEL: $total differing files; unexplained beyond noise:"
if [[ -n "$unexplained" ]]; then echo "$unexplained" | head -50; echo "($(echo "$unexplained" | wc -l) total)"; else echo "(none)"; fi
# file set changes (added/removed)
diff <(cut -f2- ref.manifest) <(cut -f2- "$LABEL.manifest") | grep '^[<>]' | grep -vE '\.(gif|png)$' || echo "(file set: only volatile images differ)"
