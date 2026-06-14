# FHIR Spec Build Performance — Findings Log

Working notes for the wallclock-reduction effort. Machine: 12 cores / 62GB / Java 17. All runs: `Publisher -nosound -nopartial` via `runs/run-spec.sh` (direct JVM, frozen classpath, no Gradle).

## Headline numbers

| Run | Wallclock | Notes |
|---|---|---|
| Baseline (stock kindling 1.25.5, core 6.9.1) | **683s** | warm tx-cache, warm package cache |
| + `-XX:+DisableExplicitGC -XX:+UseParallelGC` only | **379s** | zero code change |
| Identical repeat (noise floor) | 391s | ±3% timing noise |
| s1 (GC removal in code, ParallelGC only) | 395s | = flags effect, confirms code fix; output clean |
| s2 (linkchecker HashMap) | 374s | link-check window 47.2s → **13.2s**; output clean |
| s3 (parallel validation, 12 threads) | 386s† | validation wall 44s → **9s** (~5×); output clean |
| s4 (book-pass removal + vsusage index) | 421s† | concept maps 38→21.9s, ValueSet 12.2→7.0s (+60s tx-server stall in this run) |
| s5 (parallel packaging tail) | 373s† | packaging steps moved off main thread |
| s6 (compose-from-memory) | 399s† | TTL comment-whitespace divergence found → fixed to reparse-in-memory for TTL |

† rc=1 at the final error gate: tx.fhir.org began 404ing two specific requests ~10:30 local (server-side; affects single-threaded runs equally; durations comparable). s3–s6 runs also had implementation agents compiling concurrently — phase timings mildly inflated; clean combined re-measure pending.

JFR CPU attribution (baseline): `HTMLLinkChecker.getEntryForFile` 13.8%, `XmlParser.nameIsTypeName` 8.7% (r5+r4b), `Element.isEmpty` 6.2%, `PageProcessor.findRelatedValueset` 5.5%, token engine ~4%, vsusage scans ~2%.

## Combined + cold results

| Run | Wallclock | Notes |
|---|---|---|
| combined (s1-s9 + patched core), warm | **286s** | vs 683s baseline = **2.4×**; concept maps 38→14s, validation 44→~10s wall; remaining errors were a 60s `study-design` local-expansion stall + 3 transient tx wrapper errors (retry heuristic broadened in response) |
| cold-stock (empty tx-cache, GC flags) | **1117s** | cold tax ≈ +740s: validation 623s (422s in-tx, serial round trips), `...terminology` 78s, concept maps 96s |
| cold-combined (remote tx.fhir.org, throttle=4) | **892s** | rc=1 (server 404s); prefetched 800 expansions in 57s; validation still ~525s wall |
| cold + all spikes + **local FHIRsmith tx** (throttle=12) | **874s, rc=0** | first clean cold run: zero tx failures, Errors=0 (remote cold runs had 2–4, all server-induced); 1,930 requests total at 0–2ms each |

## The local terminology server (FHIRsmith)

`~/hobby/fhirsmith-src` (the tx.fhir.org implementation) runs locally with already-imported data: config at `data/config.json` (port 3781, endpoints /r5 /r4), library `data/tx-local.yml` (LOINC 2.82+2.77, SNOMED intl 2024+2025 + US editions, RxNorm, NDC, UNII, OMOP, hl7.terminology 7.1.0, dicom, us-core, sdc, phinvads; `internal:vsac` requires credentials — dropped). Start: `cd ~/hobby/fhirsmith-src && npx tsx server.js` (~40s to load). Point the build at it with `-fhir-settings runs/fhir-settings-localtx.json` (`{"txFhirProduction": "http://localhost:3781"}`) — no code change needed (kindling derives its tx URL from `FhirSettings.getTxFhirProduction()+"/r5"`).

Accuracy: validation Errors=0, warnings within 3 of remote; output diffs beyond known noise are small terminology-metadata differences (e.g. binding annotations like "(a valid code from https://www.iana.org/time-zones)" present locally but not in the ref run) — content-version skew between local data files and production tx.fhir.org, not engine misbehavior. The 50 HTTP 422s are `$expand` refusals of the unexpandable BCP-47 all-languages set, same as production.

## THE COLD-BUILD BOTTLENECK MOVED (key insight)

With a 1ms-latency local server and 12-way parallel validation, cold validation still takes ~525s wall (~5,073s of work at ~80% parallel efficiency = ~5.4s *in-process* work per file). Cold per-file cost is dominated by fhir-core's **local terminology computation under a cold cache** — local expansion/membership work inside `ValueSetValidator`, cache-token generation (pretty-printing ValueSet JSON per call), and `BaseWorkerContext` lock contention — NOT network. Warm runs do ~0.18s of the same work. The next frontier for cold builds is therefore upstream fhir-core work:
1. Memoize/lock-narrow `TerminologyCache.generateValidationToken` (serializes VS JSON on every call, even cache hits).
2. Cache local-expansion/membership computations per ValueSet across files (the per-request cache keys appear to defeat reuse when VS content is inlined).
3. Shard or narrow the `BaseWorkerContext` lock; make `codeSystemsUsed`/`TerminologyClientManager` maps concurrent (currently benign-racy).
4. The `study-design` ">60s local expansion" stall is this same engine grinding on a large VS.

Also empirically established: tx.fhir.org sheds load under per-IP concurrency (nginx 404), so remote parallelism caps at ~4; a colocated server removes that cap AND the day's server flakiness from the equation entirely.

## Big-swing spikes A and B (explored, measured, stacked)

All runs: cold tx-cache, local FHIRsmith tx, 12-thread validation, all earlier spikes included. Baseline for this exercise: **874s clean**.

| Run | Wallclock | Correctness |
|---|---|---|
| Spike A — fhir-core terminology fixes (branch `spike/core-txperf`) | **287s (3×)** | rc=0, Errors=0/Warnings=3693 (exact parity), 0 CME |
| Spike B — overlap validation with produce tail (branch `perf/overlap-validation`) | unmeasurable alone | pre-A race corrupted both attempts (220 bogus errors) |
| A + B stacked | **246s** | rc=0, exact parity |
| A + B + adversarial-review fixes (`e6ee120ac`) | **227s** | rc=0, exact parity |
| A + B warm (after poisoned-cache purge) | 255s | rc=0 |

JFR budget of the pre-A cold validation cost (~5.4s/file across 12 threads): **74% blocked on the single shared lock** (BaseWorkerContext passes its own `lock` into `new TerminologyCache(lock, ...)` — every fetchResource queues behind whole-cache-page file rewrites done under that lock; 593s of monitor-enter in a 67s window); **~19% CPU in TerminologyCache pretty-print serialization** (cache keys embed the full serialized ValueSet per call, even cache hits; snomed.cache ≈110KB/entry, rewritten wholesale per store → ~4.9GB cumulative writes); **allocation storm 3.1GB/s**, half from a varargs `int[]` allocated per character in `Utilities.isWhitespace` under escapeJson; real validation work (InstanceValidator/FHIRPath) was **under 2% of thread-time**. CME root cause: `TerminologyCache.cacheCodeSystem/cacheValueSet` iterate plain HashMaps unsynchronized while 12 threads insert (plus a second silent-corruption path via the swallowed exception → `noTerminologyServer` flip).

Spike A contents: split TerminologyCache onto its own lock (was sharing/contending with BaseWorkerContext), synchronized TerminologyClientManager maps + COW server list, narrowed the silent `catch(Exception) → noTerminologyServer=true` flip (the actual root cause of the intermittent 217-error corruption: an unsynchronized-HashMap exception in `chooseServer` silently disabled terminology mid-run, turning every later batch validation into a bogus CONCEPTMAP error), memoized validation-token serialization, streaming hashJson. An adversarial verification pass (multi-agent) found the memo initially dead (BWC copies expParameters per call), the original CME window (`fetchSupplementedCodeSystem` → unsynchronized `CanonicalResourceManager.getSupplements`) still open, a ConceptMap severity flip in no-server runs, and a binary-compat break — all fixed in `e6ee120ac`.

Spike B contents: validation pool forks right after the expansions feed (last produce-side context mutation) and joins where validationProcess used to run; reporting at join keeps output byte-order identical; kill-switch `-Dfhir.build.overlap.validation`. Overlaps spec-map/RDF/packaging/link-check (~150s window). Requires A's thread-safety fixes — without them the produce+validate concurrency reliably triggers the corruption.

More upstream bugs found this round: **the tx disk cache permanently caches transient server-error outcomes** (10 poisoned `.cache` files from a tx.fhir.org flaky window kept failing warm builds until purged — `grep -l "Error performing tx5" ~/.fhir/tx-cache/.../*.cache`); the `Runtime.gc()`-per-file forced-GC measured at 40% of stock build.

## Cold-remote improvement round (H1–H5)

Bench matrix on `perf/integrated` + `spike/core-txperf` jars: cold-remote **415s** rc=0, warm-remote 212s, cold-local **240s**, warm-local **197s** (all exact-parity except one 1-in-15 `ED_SEARCH_EXPRESSION_ERROR: null` race in parallel search-param FHIRPath — known issue).

- **H4 cache-id: CLOSED — protocol bug.** `-Dfhir.build.tx.usecacheid=true` is 27% faster and returns wrong answers (285 errors; valid mimetypes rejected) **identically on legacy tx.fhir.org and current FHIRsmith** — grammar-based infinite systems lose semantics when the VS is registered by reference. Explains the undocumented 2024 disable commit. Upstream-report material; flag stays off.
- **H1–H3 local-first (spike/core-localfirst @ d7f9f3e06, gate `-Dorg.hl7.fhir.tx.localFirst`):** request census from captured request/response pairs re-ranked the classes (UCUM 851 uniques, SNOMED 551, all-systems 204, LOINC 195, lang 117). Root-causes found: the unknown-system negative-cache **never arms** (server sends `x-unknown-system`, client checks `x-caused-by-unknown-system`); the CodeableConcept path never consults the memo; registry "no server claims this" still falls through to the primary server; kindling's existing example.org/UCUM short-circuits are wired to an overload the validator never calls. Implemented the parity-provable subset (grammar-system positives + byte-verified unknown-system synthesis): **1,968 → 1,823 requests (-7.4%), exact parity** (Errors=0/Warnings=3693). UCUM display-checks (816 uniques) skipped with evidence — requires the server's curated display table (530/851 local mismatches).
- **H5 adaptive throttle: no demonstrable benefit; possible lingering per-IP penalty after concurrency bursts.** Static 4 remains the default.
- **Two-pass $batch prefill (spike/s12 + spike/core-batch-tx): PARKED.** Mechanically perfect (1,424 misses → 102 POSTs, 0 token mismatches; request-shape parity reconciled across 7 differences) but wallclock-negative (551s vs 415s — the thread pool already hides latency) and response-processing parity unfinished (warnings 3037 vs 3693). Its 15× request reduction is the salvageable idea if server load ever matters more than wallclock.
- **Measurement meta-finding: tx.fhir.org wallclock varies ±40% by time of day** (415s at 5pm vs 585s at 8pm, identical code/config). Remote optimizations below ~100s are unmeasurable without paired same-window runs; request count is the honest metric for request-reduction work; and CI that cares about cold time should colocate a FHIRsmith container.

## tx.lock spike round (post-ideation)

| Spike | Cold-local | Parity | Server requests | Verdict |
|---|---|---|---|---|
| sp2 **tx.lock answer pack** (`spike/core-txlock`, pack from packager-filtered capture) | **196s — fastest cold run of the session, beats warm** | exact (0/3693/345) | **713 (-67%)** | **works on first measurement** |
| sp3 eval memoization (`spike/core-evalmemo`) | 221s (-19s vs 240 baseline) | exact modulo the known 1-in-N search-param race | 2,134 | keep, modest |
| sp1 UCUM display table (`spike/core-displaytable`) | 224s | exact | 2,118 (-16) | park: addressable class was ~60 req/run, not ~850 — census uniques (cumulative cache entries) ≠ per-run requests |

tx.lock details: pack built by `TerminologyCachePackager` from a captured corpus — poison entries structurally unrepresentable (25 filtered, matching independent grep), manifest records source server + effective edition versions extracted from responses + content sha256, pack named by hash, consumed as an immutable read-only seed layer, `-Dorg.hl7.fhir.tx.hermetic` + miss logging included. Remaining 713 requests (4,205 logged misses, mostly locally-resolved): dominated by `all-systems` (1,028 validate misses — likely key-instability from transient ValueSet urls embedded in request JSON), v2-0487, expansion classes. Key canonicalization of the all-systems class is the path to hermetic/zero-traffic.

## tx.lock final state (txpack/chain @ f88bdf197)

The pack format is complete and self-contained: validate-code answers (incl. deterministic semantic errors via `-Dorg.hl7.fhir.tx.recordSemanticErrors` recording runs), expansions **including deterministic server refusals** (two-tier poison predicate: transport markers unconditional, HTTP-wrapper markers pass only for an allowlisted refusal text), VS/CS external resolutions **with negatives as first-class content**, the tx-registry system map (read-only seed in TerminologyClientManager), and server capability artifacts. Packs are content-addressed, manifest provenance + effective editions, structurally poison-free, `merge`-able for top-ups. 55/55 tests.

Convergence measured (cold, local server, kindling-s12, all runs **rc=0 byte-exact** 0/3693/345):
| run | wallclock | server requests |
|---|---|---|
| no pack | 220s | ~1,930 |
| first pack | 196s | 294 |
| complete pack | 197s | 157 |
| after top-up merge | **195s** | 170 |

**Shadow recording (commits 4dd8db709 + 6777edb1b):** recording runs are now exhaustive — at each unknown-system suppression point, the suppressed probe is also sent to the server and cached (the caller still gets the memo answer, so the recording run's own output is unchanged). This captured +284 probe shapes that thread-timing variance had hidden, closing the probe-variant miss class. It exposed a second-order parity subtlety — pack hits served server-shaped answers where live repeats get memo-shaped ones (the `(src=…)` tag participates in dedup) — fixed by answer-shape precedence: when the per-run memo is armed, a cached unknown-system answer is discarded in favor of the memo path, exactly matching live ordering; the first-asked shape per system stays exempt (live also serves its repeats from cache). Final verification: **replay = 195s, rc=0, exact 0/3693/345; residual 152 requests = the kindling-side floor only.** Recording runs should use `-Dfhir.build.validation.threads=1` to dodge the known parallel search-param race (completeness, not speed, is their job).

**Cold with a pack is indistinguishable from warm (195s vs 197s), byte-exact, every time.** The ~160-request/run floor is precisely attributed: ~56 kindling `BuildWorkerContext.lookupLoinc` 404 probes (the self-refreshing answer-file's miss path — kindling-side fix), ~91 unsupported-system probe *variants* (CODESYSTEM_UNSUPPORTED answers are deliberately never cached, so each run probes a different shape — closing it means a per-system rather than per-request negative policy), and 1-2 client bootstrap calls. Hermetic mode (`-Dorg.hl7.fhir.tx.hermetic=true`) works as designed: it fails loudly naming the exact request, which is how each gap above was found.

**The airplane build (hermetic-v4, commit 3cd05a069 + pack txpack-36913cc2…):** full cold build, **zero network requests, 231s, rc=0, exact 0/3693/345**, judge-clean except `all-valuesets.zip` (known zip nondeterminism — differs even between two stock runs). The last 24 hermetic violations were NOT a cache-key problem (the canonicalized token text never contains cache-id; Rule 2 in commit 7e5f8418a was defensive only). Root cause: the "go with the local warning" early return in `validateCode(Coding)` (`BaseWorkerContext` ~:1689) — narrative `lookupCode` asks (useClient=true, vs=null, unknown system) land their `CODESYSTEM_UNSUPPORTED` in `localWarning`, round-trip the server, then return a WARNING result rebuilt purely from `localWarning` *without caching it and without arming the memo*. So stock live builds re-ask the server for the same shape on every example, forever, and no recording could ever pack the shape. Fix: cache that rebuilt answer PERMANENT (it is fully local-determined — its "Server Error:" diagnostic even reads the rebuilt message, not the server's — so replay is byte-identical and live runs only lose redundant round trips). This is also a standalone upstream win independent of txpack. Top-up flow proved out: pack-seeded recording run captured exactly the residual 63 shapes → `merge` (3023+63, 0 poison, 0 conflicts) → hermetic green.

### Grand totals (full -nopartial build, this machine)
- Warm, stock, remote tx: **683s** → warm, all spikes, local tx: **~255s**
- Cold, stock, remote tx: **1117s** → cold, all spikes + A + B, local tx: **227s** (~5×; cold now ≈ warm)

## Cold-build lessons (measured)

- The cold tax is ~all terminology network: 931 files × serial round trips. Parallel validation overlaps it, but **tx.fhir.org sheds load under per-IP concurrency (nginx 404s)** — a serial cold build issuing far more requests got zero failures while 12-thread runs got 2-110. Mitigation: global tx-request `Semaphore(4)` at fhir-core's `ManagedFhirWebAccessor.httpCall` (`-Dorg.hl7.fhir.tx.maxConcurrency`), plus post-pool serial retry of transiently-failed files in kindling.
- The branch-keying fix means a build on `master` bootstraps its cache from the CI-published `tx-cache/.../master.zip` — converting "wrong-dir cold" into "mostly warm" automatically. Observed live: the fixed build created and used `~/.fhir/tx-cache/jmandel/fhir/master`.
- Caveat found: a failed build may not persist its tx-cache additions, so repeated failing runs stay cold (combined-warm2 paid full network twice).
- `BaseWorkerContext`/`TerminologyCache` locking held up under 12 threads; rare `ConcurrentModificationException` in `ValueSetValidator.validateCode` (shared SD userData caches) — caught by the designed serial-retry fallback. Upstream fix: lock invariant/snapshot cache writes.

## Root causes found

1. **272s (40%) of the build is stop-the-world GC** — `Runtime.getRuntime().gc()` per validated example (`ExampleInspector.java:359`), confirmed by JFR (934 `jdk.SystemGC` events). Plus 3 more forced-GC sites on the build path.
2. **Build is 100% single-threaded** — zero ExecutorService/parallelStream in kindling; 11 of 12 cores idle.
3. **`HTMLLinkChecker.getEntryForFile` = 13.8% of all CPU** (~94s) — O(n²) `equalsIgnoreCase` linear scan over ~11k entries, called per registration and per link.
4. **`PageProcessor.findRelatedValueset` = 5.5% CPU** (~38s) — linear scan per lookup; dominates the 40s "concept maps" step.
5. **fhir-core serialization hot paths**: `XmlParser.nameIsTypeName` 7.1% + 1.6% (r5+r4b), `Element.isEmpty` 6.2%.
6. **Write-then-reparse churn**: each of ~1,300 examples parsed 3-4× and written ~10×; every canonical resource serialized to 5 formats with disk round-trips between.
7. **~50s dead setup** in `ExampleInspector.prepare2` (XSD compile + JSON-LD self-test for a validator whose call site is commented out).
8. **COLD-BUILD: tx-cache branch-keying bug** — `Publisher.checkGit` keys the terminology cache by the *alphabetically-first local branch* (`git.branchList()` first element), not the checked-out branch. This machine loads `tx-cache/jmandel/fhir/integrate-FHIR-11050-empty-2` while on `master`. When the first-sorted branch changes or CI clones fresh, the build silently goes terminology-cold (thousands of serial tx.fhir.org round trips).
9. **Tx cache-id optimization explicitly disabled** (`Publisher.java:686` `setCanUseCacheId(false)`) — every cold validateCode/expand request inlines full ValueSet content.

## Upstream bugs worth reporting (independent of perf)

- The build is **not byte-deterministic**: ShEx (and TTL/JSON-LD) generation emits different content between identical runs (whole `EXTENDS @<BackboneElement>` blocks appear/disappear); vs/cs section numbers unstable run-to-run; random UUIDs embedded in table scripts.
- First build in a fresh checkout produces different output than subsequent builds (missing `structuredefinition-category` extensions) — build reads state produced by prior builds.
- tx-cache branch keying (item 8) is a correctness-of-caching bug.

## Spikes (kindling branches, worktrees under tmp/worktrees/)

| Branch | What | Status |
|---|---|---|
| spike/s1-gc-and-smalls | remove forced GCs, lazy dead prepare2, cached FHIRPath nodes | measuring |
| spike/s2-linkchecker | HashMap index, single read, drop dead compose | measuring |
| spike/s3-parallel-validation | N validators over shared context, ordered merge | measuring |
| spike/s4-vocab-pages | kill discarded "book" render pass; invert vsusage scan | measuring |
| spike/s5-packaging-tail | parallel zip/conversion tail | measuring |
| spike/s6-example-io | compose all formats from in-memory element | measuring |
| spike/s7-vs-index | index findRelatedValueset | implementing |
| spike/s8-token-engine | single-pass template token engine | implementing |
| spike/s9-tx-cold | fix tx-cache keying; gate cache-id re-enable | implementing |
| spike/combined | s1..s6 merged (d69b408), compiles, zero gc() calls | ready |
| (fhir-core) spike/core-hotpaths | nameIsTypeName set lookup, Element.isEmpty | implementing |

## Measurement infrastructure

- `runs/run-spec.sh LABEL [--kindling classes] [--jvm "..."]` — direct-JVM run, timestamped log, normalized manifest, diff vs reference.
- `runs/manifest.py` — sha256 manifest with timestamp/UUID/section-number normalization; archives compared by member list.
- `runs/judge.sh LABEL` — diffs beyond the known nondeterminism allowlist (`noise-files-v2.txt`, 226 files).
- `runs/cold-run.sh LABEL ...` — stashes `~/.fhir/tx-cache` for the run, preserves resulting cache, restores.
- Reference: `runs/ref-publish/` + `ref.manifest` (converged build output). Frozen dependency jars: `runs/cp-frozen/`.

## Review round and consolidation (June 12, afternoon)

The full chain (12 core commits + kindling s10/heuristic/s11 + the extracted fold) went through
a per-commit adversarial review (one reviewer agent per commit; every major finding sent to a
refuter that only confirms problems present at branch tip). 43 agents, 24 confirmed majors, all
fixed; full record in `runs/review-spike-chain.json`. Dominant theme: unflagged default-behavior
changes — fixed by one rule, "pack machinery only acts when pack/recording mode is on":
localFirst and adaptive throttle now strictly opt-in; precedence/arming gated on pack-or-recording;
canonical keys gated likewise (default runs keep stock keys — no silent cache invalidation);
capability capture recording-only; localWarning answers TRANSIENT by default; plus correctness
hardening (grammar shortcut defers to locally loaded CodeSystems; unknown-system memo keyed by
(system, vs) pair; pack ServerOptionList defensively copied; isPackDescribedServer master-only;
corrupt-page recovery incremental again; packager verify handles zips; ManagedFileAccess sweep).

Post-fix verification (all judge-clean except the known all-valuesets.zip):
- hermetic-postfix (fixed core + fixed fold, otherwise-stock kindling): 650s, rc=0, 0 requests, 0/3693/345
- hermetic-integration-v2 (composed PR set perf/integrated + perf/terminology-fold, fixed tips): **211s, rc=0, 0 requests, 0/3693/345**

Branches renamed off spike/: core `txpack/chain` (was spike/core-coldpack, fixes at tip
e9e60c989), kindling `perf/overlap-validation` (was spike/s11..., overlap now opt-in,
fixes a92b35a+ddb7d7e), `perf/terminology-fold` (clean single-commit extraction 3ae9326
replacing spike/s13-fold), `perf/integration-eval` (the composed evidence merge).
`perf/narrative-lookup-cache` amended to TRANSIENT (40186d0ca).

## Judge-readout correction + demo reference (June 12, evening)

A display filter used in today's session (`grep -v '\.html$'` on judge output) hid 49
unexplained pages in every judge call since mid-morning. Root-caused: they are the
LONG-DOCUMENTED local-vs-remote terminology-metadata skew (e.g. FHIRsmith annotates
IANA-timezone bindings, production tx.fhir.org doesn't) - the committed reference was
remote-flavored while packs record local answers - plus one genuinely unnormalized date format
("12 Jun 2026" expansion-generated lines), now added to manifest.py's normalizer. No semantic
content differed. Consequence for claims: pack-run "byte-exact" = exact signature + judge-clean
*within the pack's recorded-server flavor*; vs a live-remote build the known ~49-page metadata
skew applies (the drift class txpack exists to pin). The future-world demo branch
(jmandel/fhir @ txpack-future) therefore ships a reference manifest generated from its own
pinned toolchain+pack configuration.

## Future-world demo on GitHub CI (June 12-13, jmandel/fhir @ txpack-future)

A self-contained shadow environment of the proposed future, on the spec itself: tx.lock pins an
immutable pack + tooling jar (content-addressed release assets; GitHub Packages rejected - auth
required even for public reads), eng/future/build.sh (default path: bash/curl/sha256sum/java
only), parity tooling, and split CI. **Green end-to-end on 4-core/16GB GitHub runners**: fresh
clone -> hermetic cold build in ~3.5-4 min (vs ~18+ min stock cold against tx.fhir.org), zero
terminology network (enforced), exact signature - plus an optional reproducibility job (double
build, evidence-based + order-insensitive judged parity vs a committed reference manifest).

Nine CI iterations produced an environment-leak catalogue, each found by the hermetic gate or
the parity judge doing its job (stock builds silently absorb all of these):
locale -> terminology request keys; absolute checkout path and OS username -> page content
(bug 7 item 5); installed fonts -> POI xlsx column widths; filesystem enumeration order ->
archive member order; thread timing -> element ordering, a flickering language-designations
table (cause unverified), and a local-expansion fallback (v3-ActReason) that fell through an
unguarded prefetch retry to the network - fixed by porting the review's retry guard into
perf/integrated (commit 6e84496) and bumping the pinned jar (kindling-future-v2.jar), itself a
live example of the lock-bump discipline.

Comparison taxonomy settled with sharp edges: per-push CI gate = ONE build (hermetic +
signature; ~4 min - the everyday cost); bump review = same-machine OLD-vs-NEW output A/B (the
refresh workflow's layer 1, feeding the lock-bump PR body + a GitHub Models-written explanation
section, narrative-only); committed-reference parity = the OPTIONAL reproducibility stretch
track (runs on [parity] tag/dispatch), where double-build evidence + O-tier (order-insensitive
second-chance hashing, tamper-verified) keep noise excusal honest without allowlist blindness.
Pack-vs-live equivalence is established once at recording time and inherited transitively.
Manifest tooling: parallelized 74s -> 14s (Python 3.14 non-fork multiprocessing gotcha), opt-in.

## All-Java future world + bug 15 (June 13)

The demo's scaffolding became product: core txpack/chain gained TerminologyCachePackager
`diff` (canonical pack comparison, 63/0/0 parity with the python tool on real packs) and
TxLock (content-addressed pack resolution with sha256 verify, ~/.fhir/tx-packs store);
kindling perf/integrated gained OutputManifest (manifest/compare/impact, identical path sets
to python on 26,865 files, parallel) and SpecBuild - one CLI front door (build/judge/impact/
manifest/compare/diff-packs) that pins locale/timezone IN-PROCESS, resolves tx.lock natively,
asserts the lock's signature, and accumulates local evidence manifests. python deleted from
the demo branch; bash reduced to a 20-line jar bootstrap; dependency footprint = JDK.
Local E2E: `SpecBuild build . --judge` = 190s, hermetic, exact signature, evidence-excused
parity, rc=0. CI gate green from a COLD runner (pack fetched by the publisher itself).

That cold fetch found **bug 15**: SimpleHTTPClient percent-decodes redirect Location headers
(stock master L96, introduced a4efdb922 May 2024), corrupting signed-URL redirects - GitHub
release assets 400 every time through ManagedWebAccess while curl succeeds. Fixed on
txpack/chain (80c9dfe13); added to the upstream report (P2).

Refresh-flow E2E status: no-change path validated (silent stop); harmful-candidate path
validated twice in CI (downgrade blocked, +27-warnings/Errors=1 signatures); benign-change
path (layered PR incl. GitHub Models explanation) pending a benign candidate.

## Determinism fixes in the forks (June 14)

Driven by a same-machine run-to-run diff (two converged SERIAL builds, race-free, both
0/3693/345). Genuine run-to-run nondeterministic files: **21 → effectively 1**. Characterized
via a 6-agent workflow (runs/ + transcripts); fixes applied to core txpack/chain + kindling
perf/integrated, 119 core unit tests green, output signature unchanged:

- core CanonicalResourceManager.allResources HashSet→LinkedHashSet — identity-hash iteration
  order reordered every getList() consumer (warnings.xml messages, toc.html section numbers,
  spec.internals targets). Root fix; spec.internals now timestamp-only, toc stable.
- core ValueSetExpander.addCode defensive-copy — was appending the synthetic preferredForLanguage
  designation to the caller's LIVE cached CodeSystem list → duplicate accumulation flickering with
  processing order (expansions.json + the value-set display-column present/empty flicker). Real
  shared-state-mutation correctness bug, not just nondeterminism. Fixed the displayflicker at root
  (no renderer mask needed).
- core PatientRenderer photo filename: per-build random UUID → content-derived CRC32 name.
- kindling: NamingSystem registry bundle sort-by-fullUrl; scanForPages/scanForImages sort
  listFiles by name (also the cross-machine fs-enumeration class).

Remaining run-to-run residual: fhir.ttl (OWL ontology RDF ordering — ~25 subjects via a
secondary unsorted pass + intra-subject restriction/predicate order; deeper FhirTurtleGenerator
fix, the narrowed TTL survivor of bug #7 source 3) + wall-clock timestamps (version.info etc.,
normalizer territory) + downstream containers. For PARALLEL byte-repro the known search-param
validation race also applies (serial sidesteps it). Net: converged serial build now reproducible
run-to-run except fhir.ttl + timestamps. All folded into upstream-bugs.md bug #7 status.

## Correctness sweep of the perf forks (June 14)

Triggered by the realization that the "search-param race" was filed as a runbook note
(threads=1) rather than a correctness defect, and that the determinism pass had just found a
real shared-mutation bug (ValueSetExpander) the static review missed. Three complementary
efforts:

1. **Empirical reproduction** — 4 parallel builds: all clean (exact 0/3693/345). The
   result-flipping event (one build hit Errors=2 earlier) is rare (≲1-in-10) and unreproduced.
2. **Concurrency audit** (6-agent workflow) over every parallel path we introduced
   (validateFiles, searchparams, prefetchExpansions, overlapValidation, packagingTail, core
   WorkerContext): **no confirmed result-flipping/corrupting race.** The search-param path is
   provably clean (`certain`) — per-thread FHIRPathEngine, synchronized expressionNode cache,
   monotonic-post-join flags, evaluate() doesn't mutate the node; the earlier race was already
   closed by the expressionNode synchronization. Only residual: a benign diagnostic txLink
   provenance race in prefetch (server-fallback only, not expansion content; never fires in
   pack/hermetic mode). The CME-on-shared-SD-userData race is handled by the existing
   warmup+serial-retry fallback.
3. **Behavior-preservation review** (9-agent workflow) of the foundational perf optimizations
   never put through rigorous review (kindling 520b280/79b56dd/bb3cc94/455888a/99e0504/3556ad7;
   core a4030ee0a/b56b1e818/3116a459c): **all behavior-preserving for valid builds.** The HashMap
   indexes equal the linear scans they replace (verified ValueSet has no equals/hashCode override
   so identity-keying is exact), the single-pass token engine and serialization-reduction preserve
   output, cache-key memoization doesn't collide/stale, parser precomputed-sets match. One
   intentional documented delta: a4030ee0a downgrades ConceptMapValidator NOSERVICE error→warning
   (no-terminology-server runs only; the spike-A fix turning silent corruption into visible
   degradation). One latent trap hardened: clean2() now invalidates VS-derived caches it left
   stale (f449fb9). One item covered by empirical signal: 79b56dd's book-template→real-page
   fragment-scan change is unverifiable by publish-dir parity (fragments don't reach publish), but
   the QA warning count held at 3693 across dozens of builds, so the validated fragment set is
   stable.

Net: no live correctness regression in the perf forks beyond what was already fixed/handled;
two minor items (benign txLink, latent clean2 — now hardened). Process lesson recorded: static
review + output-parity sampling missed two runtime/shared-state bugs (ValueSetExpander mutation,
and the rare validation event); concurrency and shared-mutation need their own targeted passes,
done here.
