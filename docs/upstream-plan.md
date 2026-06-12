# Upstream contribution plan: FHIR core build performance work

Status: **nothing has been posted, filed, or PR'd upstream yet.** All code lives on the
`jmandel` forks as plain branches (clickable, non-PR); all prose lives in this repo's `docs/`.
This document is the map from what we built to how we hand it over.

## Principles

- **Don't flood the maintainer.** At most 2–3 open PRs per repo at any time. Everything else
  waits, visible on the fork and listed here so the roadmap is inspectable without being a queue
  of review obligations.
- **One consolidated bug report**, not 14 issues. `docs/upstream-bugs.md` (audited, each bug
  verified against stock code with a repro) goes out as a single Zulip post linking the doc in `jmandel/fhir-perf`. Individual
  GitHub issues get filed only when (a) a PR fixes one (so the PR can say "fixes #N") or (b) the
  maintainer asks for one.
- **Design discussion before architecture code.** The txpack series does not open as PRs until
  the proposal (`docs/txpack-proposal.md`) has been discussed. The discussion is anchored by
  clickable working branches, not hypotheticals.
- **Default-off everywhere.** Every behavior-affecting change beyond Wave 1 ships behind a
  system property that defaults to today's behavior, so merging is low-risk and defaults can be
  flipped later with data.
- **Stacked only where actually dependent.** Independent changes are independent PRs.
- **Negative results stated up front** (two-pass `$batch` prefill, adaptive throttle, cache-id
  re-enable) to preempt "did you consider…" cycles. See "Parked" below.

## Release coupling

kindling consumes fhir-core via released Maven artifacts. Anything in kindling that *needs* a
core change cannot go green in kindling CI until the core change is merged **and released**.
Hence core Wave 1 leads; kindling Wave 1 is the only kindling work with no new core dependency.

---

## Track A — fhir-core (`hapifhir/org.hl7.fhir.core`)

Fork: <https://github.com/jmandel/org.hl7.fhir.core>

### Wave 1 — open now (4 PRs total, respecting the 2–3 cap by opening A1.1, A1.2, A2 first)

**A1. The thread-safety / hot-path stack** — branch
[`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety)
(on current master; suites green). Authored and verified as a stack; opens as 3 stacked PRs cut
at its commit boundaries:

| PR | Commit | Content | Pitch |
|---|---|---|---|
| A1.1 | [`a4030ee0a`](https://github.com/jmandel/org.hl7.fhir.core/commit/a4030ee0ab40264d93c7e250adc6ff9ce734283b) | Thread-safety of shared terminology infrastructure (TerminologyClientManager maps, BaseWorkerContext lock split) | **Correctness first**: fixes a real intermittent corruption — an unsynchronized map race silently flips `noTerminologyServer`, producing 217 bogus errors. Perf is a side effect. |
| A1.2 | [`b56b1e818`](https://github.com/jmandel/org.hl7.fhir.core/commit/b56b1e818765f34d2ea8ac6cccf0df99b2f4be56) | Cache-key memoization, buffered JSON output, **tx HTTP concurrency throttle** (`-Dorg.hl7.fhir.tx.maxConcurrency`, default 4) | The throttle is a favor to tx.fhir.org: it sheds load above ~4 concurrent requests per IP (nginx 404s), so unthrottled parallel validators DoS themselves and the server. |
| A1.3 | [`3116a459c`](https://github.com/jmandel/org.hl7.fhir.core/commit/3116a459c54892f224398d2244edf94ca653ea59) | XmlParser `nameIsTypeName` precomputed sets (6 modules), de-varargs `isEmpty` | Mechanical; JFR-measured 7.1%+1.6%+6.2% of build CPU. |

**A2. Narrative-path lookup caching** — branch
[`perf/narrative-lookup-cache`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/narrative-lookup-cache)
(single commit
[`40186d0ca`](https://github.com/jmandel/org.hl7.fhir.core/commit/40186d0ca)
on current master, independent of A1; `TerminologyCacheTests` green). Fixes the
"go with the local warning" early return in `validateCode(Coding)` that skips the cache store:
today every narrative `lookupCode` of an unknown code system is a fresh server round trip on
**every example, every build, forever**. The rebuilt WARNING answer is fully determined by the
local warning, so it caches TRANSIENT: repeats within a run come from memory, and across runs
the build re-asks once — exactly the adjacent "keep trying (but only once per run)" policy,
which this branch makes that path finally honor.

### Wave 2 — after Wave 1 merges (flag-gated, ports to master needed)

| PR | Source (6.9.1 spike line) | Flag | Dependency |
|---|---|---|---|
| A3. Local evaluation memoization | [`33bb89dd1`](https://github.com/jmandel/org.hl7.fhir.core/commit/33bb89dd1) on `txpack/chain` | `-Dorg.hl7.fhir.tx.evalMemo` | Stacked on A1.1 (relies on its synchronized accessors) |
| A4. Local-first grammar-system answering | [`d7f9f3e06`](https://github.com/jmandel/org.hl7.fhir.core/commit/d7f9f3e06) on `txpack/chain` | `-Dorg.hl7.fhir.tx.localFirst` | Independent; parity-verified shapes only (UCUM / BCP-47 / BCP-13) |

These exist verified on the 6.9.1 line; the master ports are mechanical but each needs its
parity manifest re-run before opening.

### Wave 3 — txpack (design discussion first; then a 5-step stacked series)

Working illustration: branch
[`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain)
— the complete, measured chain on the 6.9.1 line (every commit was built and wallclock/parity
verified; this is the branch Zulip readers click). Proposal: `docs/txpack-proposal.md`.
Headline evidence: cold build with pack = warm build (195s vs 197s, byte-identical);
**hermetic full build: zero network requests, 231s, exact output signature**.

The final PR series is authored fresh against master, each step mergeable and default-off:

| Step | Content | Illustrated by (spike commits) |
|---|---|---|
| T1 | Canonical cache keys (uuid/profile-url + cache-id canonicalization; fixes key instability) | [`3738065cd`](https://github.com/jmandel/org.hl7.fhir.core/commit/3738065cd), [`7e5f8418a`](https://github.com/jmandel/org.hl7.fhir.core/commit/7e5f8418a) |
| T2 | `TerminologyCachePackager`: pack format, build/merge/verify CLI, poison structurally unrepresentable | [`4218c307f`](https://github.com/jmandel/org.hl7.fhir.core/commit/4218c307f) (packager part), [`717181095`](https://github.com/jmandel/org.hl7.fhir.core/commit/717181095) |
| T3 | Read-only pack seed layer + `-Dorg.hl7.fhir.tx.pack=` + miss log | [`4218c307f`](https://github.com/jmandel/org.hl7.fhir.core/commit/4218c307f) (seed part), [`f88bdf197`](https://github.com/jmandel/org.hl7.fhir.core/commit/f88bdf197) |
| T4 | Recording: `-Dorg.hl7.fhir.tx.recordSemanticErrors`, shadow recording, answer-shape precedence, capabilities-in-pack | [`97c34a2f2`](https://github.com/jmandel/org.hl7.fhir.core/commit/97c34a2f2), [`4dd8db709`](https://github.com/jmandel/org.hl7.fhir.core/commit/4dd8db709), [`6777edb1b`](https://github.com/jmandel/org.hl7.fhir.core/commit/6777edb1b) |
| T5 | Hermetic mode (`-Dorg.hl7.fhir.tx.hermetic=true`) + bootstrap gating | [`5867116a4`](https://github.com/jmandel/org.hl7.fhir.core/commit/5867116a4) + ManagedFhirWebAccessor gate |

---

## Track B — kindling (`HL7/kindling`)

Fork: <https://github.com/jmandel/kindling>

### Wave 1 — open now, parallel with core Wave 1 (no new core dependency)

Branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated)
(6 commits on current main, reviewed, output-parity verified). Opens as 3 stacked PRs cut at
commit boundaries:

| PR | Commits | Content | Pitch |
|---|---|---|---|
| B1.1 | `520b280`, `79b56dd`, `bb3cc94` | Remove forced GC + dead validation setup; index hot lookups; single-pass templates; fewer serialization round-trips | **`Runtime.gc()` per validated example is 272s — 40% — of the stock warm build** (934 JFR-confirmed `jdk.SystemGC` events). No behavior change. |
| B1.2 | `455888a` | Parallelize validation, packaging, expansion prefetch | Build is 100% single-threaded today; 11 of 12 cores idle. Safe only because core A1.1 exists — but runs against *released* core with a serial-retry fallback, so no hard dependency for merge. |
| B1.3 | `99e0504`, `3556ad7` | Fix tx-cache branch keying (alphabetically-first-branch bug); gate cache-id; cleanup | The keying fix alone converts "silently cold on every CI clone" into "warm". |

### Wave 2 — after first core release containing A1

Branch [`perf/overlap-validation`](https://github.com/jmandel/kindling/tree/perf/overlap-validation):
overlap example validation with the page-production tail. Requires core thread-safety at
runtime; opens once a core release ships A1.1.

### Wave 3 — with/after txpack

Branch [`perf/terminology-fold`](https://github.com/jmandel/kindling/tree/perf/terminology-fold):
a single clean commit on main (extracted from the s13 spike, dropping its two-pass coupling),
compiles against released fhir-core, reviewed + review findings fixed. Two parts:
- **Early-eligible** (could even join Wave 1.5): route `lookupLoinc` through the normal
  terminology client (kills 56 eternally-404ing direct probes per build) and replace the
  hardcoded tx.fhir.org fallback with a hard error; lookup outages and authoritative
  not-found answers are distinguished by error class (review fix).
- **txpack-coupled**: in pack/hermetic mode, skip the bootstrap metadata ping AND the
  TerminologyCacheManager refresh (kindling-side only — no core API needed; review fix:
  against released core, a null version stamp would have wiped the recorded cache dir).

---

## The bug report

`docs/upstream-bugs.md` — one consolidated document, every bug verified against stock code,
with cause location and repro. Hand-off: a single Zulip thread (tooling stream) with the doc as
a gist, framed as "found while profiling the core build; PRs attached for several; the rest
documented for triage." Bugs fixed by the PR waves above get cross-referenced from the PR
descriptions, not duplicate issues.

## The txpack conversation

Zulip post anchored by: `docs/txpack-proposal.md` (self-contained design doc) + the clickable
`txpack/chain` chain + the headline measurement (hermetic zero-network build, exact
output parity). The post explicitly invites the "requests don't pin editions" design objection
the proposal addresses head-on (manifest pins effective editions; freshness = reviewed
lock-bump diff; it replaces the existing un-gated zip pipeline using the same credentials).

## Parked (stated to preempt review cycles)

- **Two-pass `$batch` prefill** (kindling `spike/s12-batch-tx`): wallclock-negative; response
  parity unfinished. Documented as a negative result.
- **Adaptive concurrency throttle**: static 4 retained; adaptive start-high triggered lingering
  per-IP penalties on tx.fhir.org.
- **cache-id re-enable**: closed as a protocol bug — fast but wrong on both server generations
  for grammar/mimetype systems (documented in the bug report); explains why it was disabled
  upstream in 2024.

## Verification status of pushed branches

Every branch below went through a 16-commit adversarial review round (one reviewer agent per
commit, every major finding adversarially refuted or confirmed; 24 confirmed majors all fixed)
followed by individual re-verification, and the kindling PR set was evaluated as a composed
merge. Full review record: `runs/review-spike-chain.json`.

| Branch | Base | Verified |
|---|---|---|
| core `perf/tx-thread-safety` | master | full test suites green; reviewed (prior session) |
| core `perf/narrative-lookup-cache` | master | reviewed + fixed (TRANSIENT per-run dedupe, matching the keep-trying policy); TerminologyCacheTests green |
| core `txpack/chain` | 6.9.0 (6.9.1 line) | every commit built + measured; reviewed + 18 confirmed majors fixed at tip (flag discipline: default runs behave stock); 59 cache/packager tests + 4 throttle tests; hermetic zero-network re-verified post-fix |
| kindling `perf/integrated` | main | output-parity verified; reviewed (prior session) |
| kindling `perf/overlap-validation` | main (spike chain) | reviewed + 4 confirmed majors fixed (incl. overlap now opt-in); builds clean; full measurement at Wave-2 port time |
| kindling `perf/terminology-fold` | main | reviewed + 2 confirmed majors fixed; compiles against released core; hermetic zero-network verified standalone (650s on otherwise-stock kindling) |
| kindling `perf/integration-eval` | main | merge of `perf/integrated` + `perf/terminology-fold` (fixed tips): **hermetic full build 211s, rc=0, zero network requests, exact 0/3693/345** |

## Sequencing at a glance

```
core:      A1.1 ──> A1.2 ──> A1.3          (stacked)
           A2                               (parallel, independent)
           └─ release ──> A3, A4            (Wave 2, flag-gated)
                          └─ txpack talk ──> T1..T5 (stacked, default-off)
kindling:  B1.1 ──> B1.2 ──> B1.3          (stacked; parallel with core Wave 1)
           core release ──> s11
           txpack T3/T5 ──> s13 fold (loinc reroute may go earlier)
```
