# Upstream Bugs Found During FHIR Build Performance Work (June 2026)

All found while profiling/parallelizing the core FHIR spec build (kindling + org.hl7.fhir.core). All code locations and line numbers have been verified against stock upstream code: fhir-core `master` @ 5c4d5a0ff and kindling `main` @ b6cb1f6 (June 2026). Where a measurement was originally taken on the earlier 6.9.1-SNAPSHOT line, that is noted. "Fixed in" refers to branches in this workspace.

---

## 1. cache-id terminology protocol yields wrong validation results for grammar-based code systems

**Where:** Protocol interaction between fhir-core's tx client (`TerminologyClientContext.canUseCacheId`, a static flag at TerminologyClientContext.java 74/311; the inline-ValueSet-vs-by-reference switch is `BaseWorkerContext.addServerValidationParameters`, master 1925-1944) and the tx server's cache-id handling — reproduces identically on legacy deployed tx.fhir.org and current FHIRsmith (`tx/` module), so the defect is in the interaction design or shared client behavior, not one server build.

**Symptom:** With cache-id enabled, validations against grammar-based "infinite" systems return false negatives: `The value provided ('application/pdf') was not found in the value set 'Mime Types'`, same for `image/jpeg`, `application/dicom`, valid BCP-47 codes, etc. A full spec build went from Errors=0 to **Errors=285**, Warnings shifted 3693→3821.

**Likely cause:** When the client registers a ValueSet by reference (cache-id) instead of inlining it, validation runs against the registered copy, which loses the special-system semantics of `urn:ietf:bcp:13` (any syntactically valid mimetype is a member) and similar grammar systems — the registered VS behaves as an enumerable set with no members.

**Repro:** In kindling, `Publisher.execute` line 686 hard-disables cache-id (`TerminologyClientContext.setCanUseCacheId(false)` — commit 0b65fdc, Sept 24 2024, "No use cache-id on the tx server", with no rationale; this bug is the probable rationale). Re-enable it (or, optionally, use the `-Dfhir.build.tx.usecacheid=true` gate on workspace branch `spike/s9-tx-cold`) and run any spec build; `binary-example` fails on `Binary.contentType` immediately. Minimal repro: register the mimetypes ValueSet via cache-id, then `$validate-code` `application/pdf` against it by reference. (VERIFICATION NEEDED: a raw-HTTP emulation of that two-request sequence against tx.fhir.org/r5 — inline `valueSet` + `cache-id`, then `url`+`valueSetVersion` with the same `cache-id` — was not retained by the server at all ("value set could not be found"), so the minimal repro may need the real client's full cache-id handshake; the build-level repro is the verified one.)

**Status:** Report-only. Flag remains off.

---

## 2. Unknown-system answers are never remembered: `validateCode(Coding)` returns early past both the per-run memo and the cache

**Where:** fhir-core `BaseWorkerContext.validateCode(Coding)`, master lines 1552-1567. When local evaluation of an unknown code system records a warning (a `VSCheckerException` with type `CODESYSTEM_UNSUPPORTED` becomes `localWarning`, lines 1470-1475) and the server then also answers `CODESYSTEM_UNSUPPORTED` with the code's system in `unknownSystems` (an `x-caused-by-unknown-system` response, parsed at 2139-2148), the "go with the local warning" branch rebuilds a WARNING `ValidationResult` from `localWarning` and **returns early** (lines 1557-1561) — skipping both `updateUnsupportedCodeSystems` (line 1563, the per-run negative memo) and `txCache.cacheValidation` (lines 1564-1566). The answer is recorded at no layer, so the next `validateCode` for the same system is a fresh server round trip — within the run, and again on every subsequent build.

A second, minor bug sits in the same lines: line 1560 composes diagnostics as `"Local Warning: " + localWarning + ". Server Error: " + res.getMessage()` — but `res` was just reassigned at line 1559, so the "Server Error:" text is the local warning repeated and the server's actual message is discarded. (The comment at 1558 also says "local error" where it means the local warning.)

**Symptom:** Every coding from an unknown/fictional system (`http://example.org/fhir/foo-types`, `http://acme.com/...` — common in spec example resources) round-trips to the server on every occurrence. We counted **22 separate POSTs for one fictional system** in one build. Narrative generation makes this unbounded: `DataRenderer.lookupCode` (master DataRenderer.java 313-323) calls `validateCode(options, system, version, code, null)` → `validateCode(Coding, vs=null)` (BaseWorkerContext 1181-1186) with useClient and useServer both on, so every rendered example mentioning the system pays a round trip, every build, forever. Compounding: the CodeableConcept validation path (master 1723-1816) neither consults nor updates the memo at all, and versioned codings are excluded from memoization (lines 1702-1706, `!code.hasVersion()`).

Related asymmetry worth fixing at the same time: `processValidationResult` treats the two unknown-system response spellings differently — `x-caused-by-unknown-system` classifies the result as `CODESYSTEM_UNSUPPORTED` (2139-2148), while `x-unknown-system` only populates `unknownSystems` and never sets the error class (2149-2150) — so a server using the latter spelling can never arm the memo by any path. Current tx.fhir.org returns `x-caused-by-unknown-system` for both the CodeSystem and ValueSet `$validate-code` shapes (verified live, June 2026), so on that server the early return above is the operative bug.

**Repro:** With a context configured with a terminology server and a tx cache, call `validateCode(new ValidationOptions(), new Coding().setSystem("http://example.org/fhir/foo-types").setCode("xyz"), null)` twice (useClient/useServer at their defaults, vs = null): the tx log shows two identical `$validate-code` round trips and nothing is written to the tx cache. Equivalently, validate any resource containing a coding from a made-up system twice, or grep a cold build's server log for `example.org` request counts.

**Status:** Client-side workaround (local synthesis of unknown-system answers, byte-identical to 11/11 captured server responses) on branch `spike/core-localfirst` (`-Dorg.hl7.fhir.tx.localFirst`). Fix direction upstream: arm the memo and cache the rebuilt warning result before returning, and compose the diagnostics string from the server result's message rather than the rebuilt one's.

---

## 3. Registry "no server claims this system" still falls back to asking the primary server

**Where:** fhir-core `TerminologyClientManager.chooseServer` (master lines 288-316: "System not handled by any servers. Using primary server") and `decideWhichServer` (lines 426-469): a clean registry negative (resolve succeeds with no `authoritative` and no `candidates`) returns an empty `ServerOptionList` (452-460), which `chooseServer` then turns into a POST to the primary server; the resolve-error path falls back to the primary the same way (461-468).

**Symptom:** A clean negative answer from the tx ecosystem registry (no authoritative server, no candidates) produces a positive network action — a `$validate-code` POST to the primary server, which then also fails. Negative routing knowledge is discarded.

**Repro:** Same as #2 — fictional-system validations; observe the registry resolve GET followed anyway by a primary-server POST.

**Status:** Addressed as part of `spike/core-localfirst`. Worth an upstream design note regardless.

---

## 4. Terminology stack is not thread-safe; failures silently disable terminology and corrupt results

**Where:** fhir-core:
- `TerminologyCache.cacheCodeSystem` / `cacheValueSet` (master lines 1304-1370): plain `HashMap`s (`csCache`/`vsCache`, lines 347-348) mutated and iterated with no synchronization. Observed live `ConcurrentModificationException` at `TerminologyCache.cacheCodeSystem:1170` under 12-thread validation (line number from the 6.9.1 line; the method is at ~1341 in master). Master's June 2026 txcache rework (df9504f6e) added a TODO comment (lines 87-97) acknowledging exactly these unsynchronized paths — `getServerId`, `cacheValueSet`/`cacheCodeSystem`, `getReport` — but the races remain.
- `TerminologyClientManager`: `resMap`/`serverMap` plain HashMaps (lines 142/144) mutated by concurrent `chooseServer` → `findClient`/`findServerForSystem` (385-415).
- The killer: `BaseWorkerContext.getTxSupportInfo` (master 817-862) wraps the server-support probe in `catch (Exception)` (839) → **sets `noTerminologyServer=true`** (841) whenever `canRunWithoutTerminology` is set (kindling sets it for all non-web builds, Publisher.java:2482). A console banner is printed, but the build continues with terminology permanently disabled → every subsequent batch validation returns NOSERVICE → `ConceptMapValidator` renders those as `CONCEPTMAP_VS_INVALID_CONCEPT_CODE` errors. One swallowed race produced **217-220 bogus validation errors** ("The code 'X' in the system http://snomed.info/sct is not valid in the value set 'null'"), timing-dependent (some runs clean, some corrupted, same inputs).

**Repro:** Run example validation across a thread pool sharing one `BaseWorkerContext` with a cold terminology cache (branch `spike/s3-parallel-validation` against unfixed core reproduces within a few runs).

**Status:** Fixed in PR branch `perf/tx-thread-safety` (commit a4030ee0a): synchronization, COW server list, narrowed catch, NOSERVICE downgrade in ConceptMapValidator.

---

## 5. `BaseWorkerContext` and `TerminologyCache` share one lock; whole cache-page file rewrites happen under it

**Where:** fhir-core `BaseWorkerContext` line 260 declares `private final Object lock`; `initTxCache` (lines 2244-2246) passes it into `new TerminologyCache(lock, cachePath)` (constructor at TerminologyCache.java:385). `TerminologyCache.cacheValidation` → `store()` → `save(nc)` (lines 768-778, 696-728, 820) rewrites an entire named cache page (~110KB/entry for SNOMED because each entry embeds the serialized ValueSet; ~4.9GB cumulative writes in one cold build) **while holding that shared lock**.

**Symptom (JFR-measured):** During 12-thread validation, 593 seconds of monitor-blocking in a 67-second window — **74% of all validator thread-time** queued behind one lock, mostly `fetchResourceWithExceptionByVersion` waiting for cache file I/O.

**Repro:** JFR `jdk.JavaMonitorEnter` on any multi-threaded validation workload.

**Status:** Fixed in `perf/tx-thread-safety` (lock split; cache is self-synchronized leaf). Master had independently improved persistence (5s save coalescing) but still shared the lock.

---

## 6. Transient server errors are cached permanently in the terminology disk cache

**Where:** fhir-core — server-error outcomes ("Error from http://tx.fhir.org/r5: 404 Not Found nginx", "Error performing tx5 operation...") are stored as PERMANENT cache entries like any other result. `BaseWorkerContext.validateCode` caches every server outcome PERMANENT (master 1546-1566 for Coding — including results synthesized from transport exceptions, which get errorClass SERVER_ERROR at 1550 — and 1802-1814 for CodeableConcept), and `TerminologyCache.store` (696-728) filters only unversioned CODESYSTEM_UNSUPPORTED results, never transport/5xx/404 outcomes.

**Symptom:** A build that runs during a transient server flake poisons `~/.fhir/tx-cache/...`: subsequent **warm** builds replay the cached error as a validation failure forever. We reproduced a build that passes cold and then fails warm *from its own priming run's cached errors*; found 10 poisoned `.cache` files after one flaky afternoon.

**Repro:** `grep -l "Error performing tx5\|Error from http" ~/.fhir/tx-cache/*/*/*/*.cache` after any build that overlapped a server hiccup; rerun warm and watch rc=1.

**Fix direction:** Never persist results whose message indicates a transport/5xx/404 failure (or persist with a transient TTL).

**Status:** Report-only (our builds purge manually; `runs/bench.sh` has a poison-check).

---

## 7. `validateCodeBatch` returns degraded results vs singular validation

**Where:** fhir-core `BaseWorkerContext.validateCodeBatch` (master 1205-1293) vs the singular `validateOnServer2`/`addServerValidationParameters` path (1893-1980). The batch request omits, relative to singular: `addDependentResources` (referenced ValueSets, COMPLETE/FRAGMENT CodeSystems, supplements as `tx-resource` — 1946), `cache-id` bookkeeping (1953), `valueSetVersion` (1931; batch sends only `url`, 1261), correct expansion-parameter merge semantics (`defaultDisplayLanguage` translation, override order — 1962-1974; batch dumps the raw expansion parameters into each sub-request, 1698), `mode=lenient-display-validation` (1977), and `diagnostics=true` (1979); the response path passes `null` instead of the VS url to `processValidationResult` (1284) and never updates the unsupported-systems memo.

**Symptom:** Identical codes validated via the batch path yield fewer/weaker messages — a full spec build validated via batch prefill lost **~650 warnings** (3693→3037), silently.

**Repro:** Validate the same coded elements through both paths and diff messages; or see the reconciliation commit `fe25b5e3d` on `spike/core-batch-tx`, which enumerates and fixes all seven gaps.

**Status:** Fix exists on `spike/core-batch-tx` (not in the main PR branches; the two-pass feature that motivated it is parked). The gap matters to every current consumer of `validateCodeBatch`: `ConceptMapValidator` (line 204), the validator's `ValueSetValidator` (line 520), and `CodingsObserver` IPS checks (line 105).

---

## 8. Hot-path allocation/CPU bugs: per-character varargs in `isWhitespace`; cache keys pretty-print full ValueSets per call

**Where:** fhir-core:
- `Utilities.isWhitespace` (master Utilities.java 1773-1777) called per character from `escapeJson` (1005-1031): allocates a 25-element varargs `int[]` (via `existsInList`) **per character**. JFR: 104GB of `int[]` allocation in one build (~half of a 3.1GB/s allocation storm).
- `TerminologyCache.generateValidationToken` (master 491-585): pretty-print-serializes the expansion `Parameters` and the ValueSet "essence" on **every** `validateCode` call, including cache hits (the token is generated before the cache is consulted, BaseWorkerContext 1437-1440); ~73% of validation-phase CPU was JSON serialization for cache keys.
- `JsonParserBase.compose` (lines 204, 258) uses an unbuffered `OutputStreamWriter` (per-token charset-encoder round trips; 34GB of HeapCharBuffer).

**Repro:** JFR `jdk.ObjectAllocationSample` + `jdk.ExecutionSample` on any validation-heavy workload.

**Status:** Fixed in `perf/tx-thread-safety` (switch-based isWhitespace, memoized keys, buffered writers).

---

## 9. kindling forces a full GC after every validated example

**Where:** kindling `ExampleInspector.java:359` (`Runtime.getRuntime().gc()` at the end of `doValidate`), plus three more unconditional `System.gc()` sites on the build path (`Publisher.java` ~3619, `PageProcessor.clean()`/`clean2()` ~11520/11528).

**Symptom:** 934 explicit-GC events per build (JFR `jdk.SystemGC`); **272s of stop-the-world pause = 40% of the entire stock build** (683s total, 14GB heap). Each forced full collection walks the whole live heap per example file.

**Repro:** JFR on a stock build; or run with `-XX:+DisableExplicitGC` → 683s → 379s with zero code change.

**Status:** Fixed in `perf/integrated` commit 1.

---

## 10. Terminology cache keyed to the alphabetically-first local git branch, not the checked-out branch

**Where:** kindling `Publisher.checkGit` (~lines 634-641): iterates `git.branchList().call()` and takes the **first ref** as `ghBranch` → flows into the tx-cache directory (`~/.fhir/tx-cache/{org}/{repo}/{branch}`) and CI cache-zip URL.

**Symptom:** Observed live: building `master` while the cache read/wrote `.../integrate-FHIR-11050-empty-2/`. Consequences: caches silently shared/mixed across branches; creating a new branch that sorts first makes every build cold; the CI bootstrap zip URL is wrong.

**Repro:** In a checkout with any local branch alphabetically before the current one, run a build and read the "Load Terminology Cache from ..." log line.

**Status:** Fixed in `perf/integrated` commit 5 (uses `getFullBranch()`; detached HEAD falls back).

---

## 11. kindling's local terminology short-circuits are bypassed by the validation paths that need them

**Where:** kindling `BuildWorkerContext` (lines 360-384) overrides the 5-arg `validateCode(options, system, version, code, display)` with local handling for SNOMED/LOINC/UCUM/example.org (`loadUcum` at 421, `getUcumService` at 645). But the binding-driven paths that dominate example validation call the `Coding`/`CodeableConcept` overloads (`InstanceValidator.checkCodeOnServer`, fhir-core master 8972-9018), which kindling does not override — they go straight to `BaseWorkerContext` and the network. The 5-arg overload is only reachable from the validator via `InstanceValidator.checkCode` (master 1239, called from `checkTerminologyCoding` ~2082 and `checkCodedElement` ~2445), and that path is pre-gated by `getTxSupportInfo`, which classifies `example.org`/`acme.com` systems as unsupported up front (BaseWorkerContext 829) — so for exactly the systems the override special-cases, it is unreachable from validation. The local UcumService is consulted only by the FHIRPath engine and by that same hard-to-reach override — not by the binding validations that produce the UCUM traffic.

**Symptom:** 150 UCUM and dozens of example.org validations per cold build go to the network past a local safety net that was built for them.

**Repro:** Breakpoint/log the 5-arg overload during a build: in our builds it never fired for example validation (all observed traffic flowed through the Coding/CodeableConcept overloads).

**Status:** Superseded by `spike/core-localfirst` (proper plug-in at the `ValueSetValidator.findSpecialCodeSystem` level); the effectively-dead override is worth removing or re-wiring upstream either way.

---

## 12. The spec build is not deterministic (same inputs → different published bytes)

**Where:** Multiple, all upstream of our changes (reproduced on stock builds):
- **ShEx generation** emits different content between identical runs — whole `EXTENDS @<BackboneElement>` blocks appear/disappear (~78 `.shex` + their `.html` renderings differ per run). Likely unordered-set iteration in the ShEx generator (fhir-core r5 `ShExGenerator`, which uses HashSet/HashMap-backed collections throughout). TTL/JSON-LD show the same class.
- **Section numbers** for value-set/code-system pages shuffle between runs (HashMap-order dependent numbering in kindling page generation).
- **Random UUIDs** are embedded in generated table scripts (`// 6fbd5028-...`) and image filenames.
- **First build in a fresh checkout differs from converged builds** (e.g. `structuredefinition-category` extensions appear only from run 2) — the build reads state produced by prior builds.

**Repro:** Two consecutive `-nopartial` builds of the same commit; diff publish dirs with timestamps normalized → ~226 files differ (manifest tooling in this workspace automates it: `runs/manifest.py`, `runs/noise-files-v2.txt`).

**Status:** Report-only. Matters for caching, signing, and anyone diffing published output.

---

## 13. XML comments grow one space per compose/reparse cycle

**Where:** fhir-core `org.hl7.fhir.utilities.xml.XMLWriter.comment` (line 475, write at 491) emits `"  <!-- " + text + " -->"` (one space of padding *inside* each delimiter); `org.hl7.fhir.r5.elementmodel.XmlParser.reapComments` (lines 693-709) stores the raw node text content (`getTextContent()`) **including that padding**.

**Symptom:** Every compose→parse round trip grows every comment by one leading and one trailing space. Visible in published TTL (`#   <priority value="5" />` vs `#  <priority ...>`) because the Turtle composer emits comments verbatim; it made example outputs depend on how many XML round trips the pipeline happened to take.

**Repro:** Parse a resource with an XML comment, compose, re-parse, compare `Element.getComments()` strings — they differ by two spaces per cycle.

**Status:** Report-only (we made the build's round-trip count deterministic instead; the asymmetry remains upstream).

---

## 14. CI terminology-cache bootstrap 404s for forks

**Where:** fhir-core r5 `TerminologyCacheManager.initialize` (lines 61-72) fetches `https://tx.fhir.org/tx-cache/{org}/{repo}/{branch}.zip`, falling back to `{org}/{repo}/default.zip` (line 72) — the fallback is still fork-scoped. For forks (e.g. `jmandel/fhir`), both URLs 404: a fork's "cold" build is fully cold while the canonical repo's is seeded.

**Repro:** Build a fork clone with an empty tx-cache; log shows `No - can't initialise cache from .../jmandel/fhir/master.zip: Not Found`.

**Fix direction:** fallback chain fork → canonical upstream repo → default.

**Status:** Report-only (infrastructure/policy more than code).
