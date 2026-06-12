# FHIR Spec Build: Top 10 Rework Opportunities (ranked by expected-win / effort)

Baseline (runs/baseline.log, warm tx-cache, -Xmx14g, 12 cores): **683s total** = ~83s load/parse → ~224s produce content → ~50s HTML link check → ~322s validation of 931 files → QA. Entire build is single-threaded (zero ExecutorService/Thread/parallelStream in kindling — verified by 4 of 7 agents independently).

---

## ⭐ SPIKE FIRST #1 — Delete per-file `Runtime.getRuntime().gc()` in validation
1. **Change**: Remove (or gate behind a flag) the gc() call at `/home/jmandel/hobby/fhir-perf/repos/kindling/src/main/java/org/hl7/fhir/tools/publisher/ExampleInspector.java:359` (verified present). Optionally also `Publisher.java:3619`, `PageProcessor.java:11520/11528`. Zero-code-change variant: add `-XX:+DisableExplicitGC` to the launcher JVM flags.
2. **Impact**: ~265s of the 683s build (39%). Validation phase is 322s wallclock but validator-reported time sums to only 54.4s; per-file delta (~0.27–0.29s × 931) is forced full GC of an 8–11GB heap. All 5 agents that looked at validation independently quantified this the same way.
3. **Risk**: None — GC timing cannot affect validation output. Verify: identical qa.html error counts, identical validation message logs.
4. **Effort**: <1 hour (one line + rebuild + rerun).
5. **Dependencies**: None. Prerequisite for measuring #2 honestly (it currently masks/serializes everything).

## ⭐ SPIKE FIRST #2 — Parallelize the example-validation loop
1. **Change**: `Publisher.validationProcess()` loop at `Publisher.java:6644-6663` — partition `filesToValidate` across a 10–12-worker pool, one `InstanceValidator` per worker over the shared `BuildWorkerContext` (already lock-guarded: 21 `synchronized(lock)` blocks in fhir-core `BaseWorkerContext.java`; `TerminologyCache` get/store synchronized, HTTP calls happen outside the lock). Per-task error lists merged in sorted-filename order. `ExampleInspector.java:198-223` refactor to per-thread instances.
2. **Impact**: Remaining ~55s validator CPU → ~8–15s on NORMAL mode; on CI EXTENDED mode (thousands of files) and cold tx-cache, this is tens of minutes recovered — the latency-hiding for serial tx round trips is the bigger half of the win.
3. **Risk**: Moderate, well-mapped by the core-validation agent: (a) FHIRPath/invariant caches written via `setUserData` on shared StructureDefinitions (`InstanceValidator.java:8589-8594`, 6108-6228) — fix with an eager snapshot + expression warm-up pass first; (b) shared `SearchParameterDefn.setWorks/setTested` mutation (`ExampleInspector.java:449-480`) — synchronize or merge; (c) deterministic error ordering — sort before report. Verify: diff qa.html / validation message lists against a serial run.
4. **Effort**: 1–2 days for a solid spike (warm-up pass + pool + merge).
5. **Dependencies**: Do after #1. Composes with #9 (tx). Shares the warm-up-pass infrastructure with #5.

## ⭐ SPIKE FIRST #3 — HTMLLinkChecker: HashMap lookup + single read + drop dead compose (then parallelize)
1. **Change**: `/home/jmandel/hobby/fhir-perf/repos/kindling/src/main/java/org/hl7/fhir/tools/publisher/HTMLLinkChecker.java` — replace `getEntryForFile` linear scan (line 386-397, called from registerFile/registerExternal at 121/134 and per-link at 330 — verified) with a `HashMap<String,Entry>` keyed on lowercased name (keep original case in Entry for the case-error diagnostic); read each file once (checkNormativeStatus at 193 re-reads what the parser at 169 reads); delete the stripDivs + XhtmlComposer compose whose bytes are nulled at 157 (dead epub leftover). Then parallelize the per-entry check loop in build() (149-161).
2. **Impact**: ~50s phase → seconds. Plus the O(n²) registration scans are smeared through the whole build, so some additional recovery during produce. Two agents independently sized this; one estimated 10⁹–10¹⁰ string comparisons across ~921k links / 11,286 registered files.
3. **Risk**: Low — lookups return identical results; diagnostics preserved. Verify: identical link-check error/warning output, byte-diff of any pages it rewrites (webPath href rewrite at 324-342 must stay ordered per-file).
4. **Effort**: Half a day for the data-structure fixes; +half a day for parallelization.
5. **Dependencies**: None. The "feed pre-extracted links from generation time" deeper variant overlaps with #7.

---

## #4 — Kill the discarded "book" page pass for ValueSets/CodeSystems
1. **Change**: `Publisher.java:6905` (`generateValueSetPart2`), 6961-6970 (code systems), 6016/6045/6065 (IG pages): the `processPageIncludesForBook` → `cachePage` (6506) output is never written (epub is dead); it exists only for `scanForFragments` + link-checker registration. Scan fragments from the already-generated real page instead. Note: template-vs-book.html re-triggers full `<%vsexpansion%>` rendering and `<%vsusage%>` whole-spec scans per valueset.
2. **Impact**: Halves terminology page generation — directly attacks the 40.2s concept-maps + 13.7s ValueSet steps and the ~750-vocab-page block (~40s+); pageprocessor agent rates it "large".
3. **Risk**: Low — fragment scan looks only for `<pre fragment=...>` nodes that appear identically in the real page. Verify: publish-dir byte diff (should be empty) + identical fragment-usage QA warnings.
4. **Effort**: Half a day.
5. **Dependencies**: Multiplies with #6 (vsusage index) and #8 (parallel produce). Do before #8 to shrink the work being parallelized.

## #5 — processExample: stop the write-then-reparse churn + delete dead parse
1. **Change**: `Publisher.java:5173-5474`. (a) Delete the provably dead `XhtmlParser` parse of the just-written .xml.html at 5429-5430 (`pre` never used). (b) Compose .canonical.xml/.json/.canonical.json/.ttl directly from the in-memory `e.getElement()` instead of re-parsing the file at 5388; reuse composed bytes for the JSON string embed (5396) and the DOM step (5421); single DOM parse for the examples/ copy (5455-5457). Same pattern in `serializeResource` (2114-2158, thousands of canonical-resource calls).
2. **Impact**: Each of ~1,259 examples currently gets ~4 parses + ~10 file writes; cuts 30–50% of the 94s resource loop and a chunk of the vocab phase. 4 agents corroborated the exact redundancy map.
3. **Risk**: Low-medium: the file round-trip may normalize whitespace/xsi noise — the in-memory element had setHl7WG mutations applied *before* compose (5190), so output should be byte-identical, but **verify with a full publish-dir byte diff** (the build's natural comparison mechanism).
4. **Effort**: 1 day (mechanical but many call sites).
5. **Dependencies**: Reduces the heap churn that #10 addresses; makes #8 parallelization cheaper per task.

## #6 — Invert generateValueSetUsage (O(valuesets × whole spec) → one indexed pass)
1. **Change**: `PageProcessor.java:3795-3889` (`<%vsusage%>`/`<%txusage%>`): precompute one `Map<vsUrl, List<usageItem>>` over all StructureDefinitions/conceptmaps/resources/extensions before page generation; lookup per page.
2. **Impact**: ~3,000 valuesets × full-spec scan (×2 today due to the book pass) ≈ 10⁸–10⁹ comparisons → one pass. Large slice of vocab-page time.
3. **Risk**: Low — read-only scan over data frozen before produceSpec; build index in the same deterministic scan order → byte-identical HTML. Verify: byte-diff of valueset pages.
4. **Effort**: Half to one day.
5. **Dependencies**: Win shrinks if #4 lands first (book pass removed = one scan not two) — still worth it; both together is best.

## #7 — Parallelize produceResource2 + vocab part-2 loops (132 resources, ~1,500 canonicals)
1. **Change**: `Publisher.java:3244-3255` (resource loop → `produceResource2` at 4842), 6849-6906/6961+ (vocab loops), 3290-3318 (~660 producePage calls). Pre-assign section numbers/vsCounter/csCounter in iteration order before dispatch; make shared sinks concurrent or collect-and-merge in original order (valueSetsFeed/conceptMapsFeed bundles, HTMLChecker registration — trivial after #3's HashMap, sectionTrackerCache, definitions.addNs); per-worker `page.getRc().copy(false)` rendering contexts.
2. **Impact**: The ~224s produce phase is CPU-bound and per-unit independent (each unit: ~12 templates, 2 SVGs, POI .xlsx, 6 diff files, examples). 6–8x on that block plausible → ~190s recovered.
3. **Risk**: **Highest of the list** — PageProcessor is a 12,400-line shared mutable object (`page.setId`, caches, the token engine). Incremental approach: first parallelize only the PageProcessor-free parts (xlsx/diffs/SVGs/serializations), keep template rendering serial. Verify: full publish-dir byte diff + identical qa.html.
4. **Effort**: 2–4 days for the incremental version.
5. **Dependencies**: Do #4, #5, #6 first (less work to parallelize, fewer shared touches); requires #3's concurrent-safe registration.

## #8 — Parallel/single-pass packaging tail (~75s)
1. **Change**: `Publisher.java:3523-3757` — run independent archive products concurrently (definitions zips, validator.pack, DSTU3 conversions 3580-3618, r4-as-r5 3621-3635, igpack, NPM, examples zips); parse each of the 5,190 .json files **once** shared between examples-json.zip (3692-3729), the NDJSON pass (3750-3752), and the NPM payload; convert DSTU3 XML+JSON from one parsed bundle instead of re-parsing per format.
2. **Impact**: ~75s → ~15–20s. All consumers read the now-immutable publish dir and write distinct files.
3. **Risk**: Very low — finalized inputs, disjoint outputs. Verify: unzip-and-diff archives against serial-build archives.
4. **Effort**: 1 day.
5. **Dependencies**: None; independent of everything above.

## #9 — Terminology: re-enable cache-id, batch validation, pin/verify the tx-cache directory
1. **Change**: (a) Investigate/remove `TerminologyClientContext.setCanUseCacheId(false)` at `Publisher.java:686` (verified). (b) Route cold-cache misses through the existing-but-unused `BaseWorkerContext.validateCodeBatch` (BaseWorkerContext.java:1205). (c) **Verify which cache dir the build uses**: `TerminologyCacheManager.java:54-58` falls back to `rootDir/temp/tx-cache` without git info, and `checkGit` (Publisher.java:634-641) keys on the *first alphabetical* branch ref, not the checked-out one — a mis-keyed dir means a 15–30 min cold bootstrap. (d) Memoize the cache-key JSON serialization in `TerminologyCache.generateValidationToken` (TerminologyCache.java:491-519) — currently pretty-prints expansion Parameters + VS essence on *every* validateCode call including cache hits.
2. **Impact**: Near-zero on this warm baseline; **dramatic on cold/CI builds** (the "1+ hour" reports). Item (d) is a warm-run CPU win too (tens of thousands of redundant serializations; 70% of validator-internal time is tx per reportTimesShort).
3. **Risk**: Low for (c)/(d) (byte-identical cache keys for (d) required); medium for (a) — the disable may be a server-compat workaround, test against tx.fhir.org and diff validation output.
4. **Effort**: (c)+(d): hours. (a): hours to test. (b): 1–2 days.
5. **Dependencies**: Multiplies with #2 (parallel validation hides remaining tx latency).

## #10 — JVM flags: bigger heap, throughput GC
1. **Change**: Launcher flags only: `-Xmx24-32g` (machine has 62GB; current 14336MB with 2.8→11.6GB oscillation during the resource loop), `-XX:+UseParallelGC` or tuned G1, `-XX:+DisableExplicitGC` (also neutralizes #1 with zero code).
2. **Impact**: Moderate — removes GC stalls hidden in every phase; cheap to measure on the existing JFR.
3. **Risk**: None. Verify: identical outputs by construction.
4. **Effort**: Minutes.
5. **Dependencies**: Do alongside #1 as the very first experiment.

**Honorable mentions** (real but smaller or contested): dedupe the double `testSearchParameters` call + use cached ExpressionNode (`ExampleInspector.java:417-480`, ~30–50k redundant FHIRPath parses — high confidence, <1h, fold into #2); `expandVS` stats.ini re-read/re-save per expansion (`PageProcessor.java:11304-11306` — fold into #4/#7 era); fix `fetchCanonicalResource` O(n) scan under the context lock (`ExampleInspector.java:605-612` — becomes a lock convoy under #2); StringBuilder rewrite of the O(n²) token engine (`PageProcessor.java:660`); parallel R4/R4B/R5 bundle loads + overlapping RDF/schema/invariant phases (~30–40s); Maven `-T 1C` + raise forked-javac maxmem + skip duplicate-finder/animal-sniffer for fhir-core dev loop (`repos/fhir-core/pom.xml:553-573`); ExampleInspector.prepare2 dead XSD/JSON-LD setup (~50s claim — **needs verification**, see contradictions).

---

## Cross-cutting facts (multi-agent corroborated)

- **Single-threaded everywhere**: zero ExecutorService/Thread/parallelStream in all of kindling; 11 of 12 cores idle for the whole 683s build (corroborated by all 7 agents).
- **Per-file forced full GC** at ExampleInspector.java:359 (verified): 931 files × ~0.27–0.29s = ~265s, 39% of the build; validator-reported time only 54.4s (5 agents, consistent numbers from the same log).
- **Write-then-reparse churn**: each example is parsed 3–4× and written ~10× by processExample (Publisher.java:5173-5474), with a confirmed dead parse at 5429-5430; serializeResource repeats the pattern for every canonical resource (5 agents).
- **Every HTML page parsed/serialized 2–3×** (token expansion string-churn → insertSectionNumbers parse+compose → link checker re-parse + discarded compose) across ~11,286 pages (3 agents).
- **tx cache-id disabled** at Publisher.java:686 (verified); warm disk tx-cache (~83MB, ~3,353 entries) makes this run network-light, cold runs pay thousands of serial HTTPS round trips (4 agents).
- **fhir-core is parallel-ready-ish**: BaseWorkerContext fully lock-guarded, TerminologyCache synchronized, tx HTTP outside the lock, upstream commits explicitly testing CanonicalResourceManager multithreading (3 agents).

## Contradictions / unknowns needing measurement

1. **HTMLLinkChecker phase size**: spec-tree-io and publisher-pipeline measured ~50s from the log; pageprocessor claimed "tens of minutes" and rated the fix "dramatic". The log wins — treat as ~50s (moderate), but the O(n²) registration cost smeared through produce is unmeasured; JFR will show it.
2. **prepare2 dead-setup ~50s**: prior-art attributes the 49.5s "Validating Examples" step to dead XmlValidator/JSON-LD setup; no other agent saw this and the same window overlaps link-check accounting in other agents' phase splits. Verify with JFR before counting it.
3. **Per-file validator time**: agents quote 3–5ms vs avg 58ms vs 65ms — different sample windows of the same log; the sum (54.4s) is the reliable figure.
4. **tx win size**: "dramatic" (terminology agent, cold-cache scenario) vs "near-zero" (warm baseline). Both right; resolve by confirming which tx-cache directory the gym build actually uses (`/home/jmandel/work/fhir/temp` currently has no tx-cache dir — suspicious) and by one deliberately cold run.
5. **Why cache-id is disabled** at Publisher.java:686 is unexplained in code/history — needs an upstream question or an A/B run before shipping #9a.

**Stacked estimate if #1–#8 land**: 683s → roughly 2.5–4 minutes warm, with cold/EXTENDED CI builds improving far more (#2 + #9).