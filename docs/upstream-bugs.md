# Upstream Bugs Found During FHIR Build Performance Work (June 2026)

All found while profiling/parallelizing the core FHIR spec build (kindling + org.hl7.fhir.core). Every code location below is a permalink into stock upstream code, pinned to the commits the claims were verified against: fhir-core [`master` @ 5c4d5a0ff](https://github.com/hapifhir/org.hl7.fhir.core/tree/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7) and kindling [`main` @ b6cb1f6](https://github.com/HL7/kindling/tree/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8) (June 2026). Code excerpts are verbatim from those commits. Where a measurement was originally taken on the earlier 6.9.1-SNAPSHOT line, that is noted. "Fixed in" refers to the author's workspace branches; the ones pushed for reference live on the [jmandel/org.hl7.fhir.core](https://github.com/jmandel/org.hl7.fhir.core) and [jmandel/kindling](https://github.com/jmandel/kindling) forks.

Bugs are ordered by priority. P1 is reserved for correctness/data-integrity harm that fires in default configurations and changes build outcomes: persistent cache poisoning (6) and silent mid-build terminology disable producing false hard errors (4). P2 collects active-by-default harms that are important but not build-breaking — silently weakened validation output, wasted load on shared terminology servers, and broken caching/reproducibility — ordered correctness-flavored first, then by blast radius (all fhir-core consumers before spec-build-only). P3 holds measured performance costs with no correctness impact, again radius-first (all-consumer hot paths 8 over the larger but kindling-only GC win 9), and P4 holds the one fully latent defect (1) whose harm requires a non-default flag flip.

| # | Tier | Bug | Why it ranks here |
|---|---|---|---|
| [1](#1-transient-server-errors-are-cached-permanently-in-the-terminology-disk-cache) | P1 | Transient server errors are cached permanently in the terminology disk cache | Active-by-default data-integrity bug with the widest radius: one transient server flake is persisted as PERMANENT cache state, replayed as validation failures on every warm build and propagatable via the CI cache zip. |
| [2](#2-terminology-stack-breaks-its-documented-thread-safety-contract-latent-until-a-context-is-shared-across-threads-and-its-failure-path-is-armed-today-one-swallowed-mid-build-exception-silently-disables-terminology-and-corrupts-validation-results) | P1 | Terminology stack breaks its documented thread-safety contract (latent until a context is shared across threads) | Active correctness harm in every default non-web kindling build: a single transient probe exception silently disables terminology mid-build and surfaces as bogus hard ConceptMap errors. |
| [3](#3-validatecodebatch-returns-degraded-results-vs-singular-validation) | P2 | `validateCodeBatch` returns degraded results vs singular validation | Active correctness erosion across all validator consumers — the batch path silently drops real validation findings — but partially latent (3/7 gaps need vs!=null) and the ~650-warning figure came from non-default routing, keeping it below the P1 build-breakers. |
| [4](#4-unknown-system-answers-are-never-remembered-an-early-return-in-validatecodecoding-skips-the-per-run-unsupported-system-memo-so-every-occurrence-re-asks-the-server) | P2 | Unknown-system answers are never remembered | Active operational harm with all-consumer radius: a regression defeats the designed unsupported-system memo, multiplying doomed POSTs (22x measured) against shared tx infrastructure on every default validation run. |
| [5](#5-registry-routing-cannot-represent-no-server-claims-this-system-a-clean-registry-negative-is-encoded-like-no-information-so-the-client-falls-through-to-a-doomed-post-to-the-primary-server) | P2 | Registry routing cannot represent "no server claims this system" | Same active wasted-server-load pattern with all-consumer radius (ecosystem routing on by default), but results stay correct and most of the repeated cost is bug 2's memo, so it ranks just below. |
| [6](#6-xml-comments-grow-one-space-per-composereparse-cycle) | P2 | XML comments grow one space per compose/reparse cycle | Correctness-class and active in every default round-trip across all consumers, but the harm is cosmetic comment-whitespace drift in published output, so important rather than critical. |
| [7](#7-the-spec-build-is-not-deterministic-same-inputs-different-published-bytes) | P2 | The spec build is not deterministic (same inputs → different published bytes) | Active operational harm to caching/verification/diffing (non-reproducible bytes every run), with radius mostly the spec build plus two fhir-core generator sources reaching IG Publisher. |
| [8](#8-kindling-keys-the-local-build-terminology-cache-to-the-alphabetically-first-git-branch-not-the-checked-out-branch) | P2 | kindling keys the local-build terminology cache to the alphabetically-first git branch, not the checked-out branch | Active broken-caching defect, but the narrowest radius in the tier: only local multi-branch kindling clones, with cost limited to mixed or abandoned identity-keyed caches. |
| [9](#9-hot-path-allocationcpu-bugs-per-character-varargs-allocation-in-iswhitespace-terminology-cache-keys-re-serialize-parametersvalueset-json-on-every-call-even-cache-hits) | P3 | Hot-path allocation/CPU bugs | Largest blast radius in the measured-cost tier: three unconditional JFR-measured hot-path defects (104GB/34GB allocation, ~73% validation CPU) hitting every fhir-core consumer, each with a small behavior-preserving patch. |
| [10](#10-kindling-forces-a-full-gc-after-every-validated-example-40-of-stock-build-time-is-explicit-gc-pause) | P3 | kindling forces a full GC after every validated example | Biggest single measured number (272s STW, 40% of stock build, one-line fix) but kindling-only radius, so it sits just below the all-consumer hot-path trio. |
| [11](#11-baseworkercontext-and-terminologycache-share-one-lock-whole-cache-page-file-rewrites-happen-under-it) | P3 | `BaseWorkerContext` and `TerminologyCache` share one lock; whole cache-page file rewrites happen under it | All consumers pay under-lock cache-file I/O, but the headline 74% contention requires non-default cross-thread context sharing and master's coalescing already shrank the magnitude. |
| [12](#12-kindlings-local-terminology-short-circuits-are-bypassed-by-the-validation-paths-that-need-them) | P3 | kindling's local terminology short-circuits are bypassed by the validation paths that need them | Active but spec-build-only and bounded: ~150 UCUM plus dozens of example.org validations per cold build leak past a local short-circuit to the network, with correct answers throughout. |
| [13](#13-terminology-cache-seed-bootstrap-can-never-work-for-forks-and-currently-appears-to-serve-nothing-to-anyone) | P3 | Terminology-cache seed bootstrap can never work for forks | Spec-build-only cold-start cost on forks against possibly dead seed infrastructure; the concrete ask is largely a decision plus a log-level cleanup. |
| [14](#14-the-cache-id-terminology-protocol-is-unused-and-unsafe-dead-code-that-returns-wrong-answers-if-anyone-turns-it-back-on-cut-it-or-make-it-safe) | P4 | The cache-id terminology protocol is unused and unsafe | Pure latent defect — dead code behind a default-off static affecting no default configuration — though worth reporting because one undocumented flag flip re-arms a 285-error correctness bug. |

---

## 1. Transient server errors are cached permanently in the terminology disk cache

**Setup.** fhir-core memoizes terminology-server answers in a persistent disk cache (`~/.fhir/tx-cache/<org>/<repo>/<branch>` for the spec build; IG Publisher and the validator point the same `TerminologyCache` at their own folders) so warm builds can skip `$validate-code` round trips. Cache entries are written by `BaseWorkerContext.validateCode` with a lifetime flag; `TerminologyCache.store` is the single choke point that decides whether an entry is persisted.

**The bug.** Server-error outcomes — "Error from http://tx.fhir.org/r5: 404 Not Found nginx", "Error performing tx5 operation..." — are stored as PERMANENT cache entries exactly like real answers. On the Coding path, any transport exception is converted into an ERROR `ValidationResult` with errorClass `SERVER_ERROR`:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1546-L1551
```java
    try {
      Parameters pIn = constructParameters(options, code);
      res = validateOnServer2(tc, vs, pIn, options, systems);
    } catch (Exception e) {
      res = new ValidationResult(IssueSeverity.ERROR, e.getMessage() == null ? e.getClass().getName() : e.getMessage(), null).setTxLink(txLog == null ? null : txLog.getLastId()).setErrorClass(TerminologyServiceErrorClass.SERVER_ERROR);
    }
```

That `res` flows straight into `txCache.cacheValidation(cacheToken, res, TerminologyCache.PERMANENT)` a few lines later ([L1564-L1566](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1564-L1566)); the CodeableConcept path does the same ([L1802-L1814](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1802-L1814)). The only outcome `TerminologyCache.store` ever filters is an unversioned `CODESYSTEM_UNSUPPORTED` — transport failures, 5xx, and 404 results pass through and are persisted:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L696-L706
```java
  public void store(CacheToken cacheToken, boolean persistent, NamedCache nc, CacheEntry e) {
    if (noCaching) {
      return;
    }

    if ( !cacheErrors &&
        ( e.v!= null
        && e.v.getErrorClass() == TerminologyServiceErrorClass.CODESYSTEM_UNSUPPORTED
        && !cacheToken.hasVersion)) {
      return;
    }
```

This does not look intentional. The one filter that does exist encodes the policy stated at the write site — "we never cache unsupported code systems - we always keep trying (but only once per run)" ([L1564](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1564)) — i.e. retryable answers must not be persisted, and a transport failure is the most retryable answer there is. `SERVER_ERROR` was simply never added to the filter; the static `cacheErrors` escape hatch (default `false`) only ever *widens* caching, and the read side ([getValidation](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L750)) returns whatever was stored, with no TTL and no error check.

**Consequences.** A build that runs during a transient server flake poisons `~/.fhir/tx-cache/...`: subsequent **warm** builds replay the cached error as a validation failure forever, until someone manually deletes the cache files. We reproduced a build that passes cold and then fails warm *from its own priming run's cached errors*, and found 10 poisoned `.cache` files after one flaky afternoon. Nor is the poison necessarily confined to the machine that saw the flake: a full spec build with a tx.fhir.org API key configured zips and uploads the entire cache directory — poisoned entries included — ([Publisher.java#L827-L831](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L827-L831) → [TerminologyCacheManager.commit](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L149-L158)), and `TerminologyCacheManager.initialize()` seeds any cache whose version stamp doesn't match — i.e. fresh checkouts — from those uploaded zips ([L66-L73](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L66-L73)). That propagation path is asserted from code only; we did not observe a poisoned zip in the wild.

**Repro.** Run any build that overlaps a server hiccup, then:
```
grep -l "Error performing tx5\|Error from http" ~/.fhir/tx-cache/*/*/*/*.cache
```
Rerun the build warm and watch it exit rc=1 on the replayed errors.

**Fix direction.** Both catch blocks already tag these results with `errorClass = SERVER_ERROR`, so the minimal fix is a one-line extension of the existing filter in `TerminologyCache.store`: skip persisting entries whose `errorClass` is `SERVER_ERROR`, exactly as it already skips unversioned `CODESYSTEM_UNSUPPORTED` (or, if some server-error memoization is wanted, persist them with a transient TTL instead of `PERMANENT`).

**Status.** Report-only — no fix branch. The author's workspace builds purge poisoned entries manually, and the workspace harness (`runs/bench.sh`) includes a poison-check.

---

## 2. Terminology stack breaks its documented thread-safety contract (latent until a context is shared across threads) — and its failure path is armed today: one swallowed mid-build exception silently disables terminology and corrupts validation results

**Setup.** fhir-core's shared validation context advertises thread safety as a contract: the `IWorkerContext` javadoc describes `SimpleWorkerContext` as "a fully functional implementation that is thread safe" ([IWorkerContext.java#L51-L54](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/IWorkerContext.java#L51-L54)), and `BaseWorkerContext` mostly delivers — twenty `synchronized (lock)` blocks guard its state, and most of `TerminologyCache` synchronizes on the same shared lock. But several mutating paths in the terminology layers take no lock at all. Activeness, stated plainly: stock kindling and IG Publisher validate on a single thread (neither contains a thread pool anywhere near validation), so the data races in layers 1-2 below are latent in shipping builds — they bite consumers who take the javadoc at its word and share one context across threads (embedded validation services, or anyone parallelizing spec-build validation, which is how we hit them). Layer 3 is different: it needs no concurrency at all and is armed in every kindling build not run with the production `-web` switch.

**The bug.** Three layers, in increasing severity:

1. *Unsynchronized cache maps.* `csCache`/`vsCache` are plain `HashMap`s, mutated and then fully iterated (to rewrite `cs-externals.json`/`vs-externals.json`) with no lock — `cacheValueSet`/`cacheCodeSystem` at [TerminologyCache.java#L1304-L1376](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L1304-L1376). A live `ConcurrentModificationException` was observed at `TerminologyCache.cacheCodeSystem:1170` under the author's 12-thread parallel-validation harness (line number from the 6.9.1 line; the method starts at line 1341 in master). Master's June 2026 txcache rework (df9504f6e) added a TODO acknowledging exactly these unsynchronized paths — `getServerId`, `cacheValueSet`/`cacheCodeSystem`, `getReport` — but the races remain:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L346-L348
```java
  private Map<String, NamedCache> caches = new HashMap<String, NamedCache>();
  private Map<String, SourcedValueSetEntry> vsCache = new HashMap<>();
  private Map<String, SourcedCodeSystemEntry> csCache = new HashMap<>();
```
(TODO comment: [TerminologyCache.java#L87-L97](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L87-L97).)

2. *Unsynchronized client routing.* `TerminologyClientManager`'s `serverMap`/`resMap` are plain `HashMap`s ([declarations, L142-L144](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L142-L144)) mutated by concurrent `chooseServer` → `findClient`/`findServerForSystem` ([L385-L415](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L385-L415)). The callers don't even agree on a lock: `chooseServer` is invoked both while holding the context lock (from `getTxSupportInfo`) and with no lock at all (`validateCodeBatch`, [BaseWorkerContext.java#L1276](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1276); `validateCode(Coding)`, [L1538](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1538)).

3. *The active failure mode: one exception silently kills terminology for the rest of the build — no concurrency required.* `BaseWorkerContext.getTxSupportInfo` ([L817-L862](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L817-L862)) is called per code system throughout validation. It wraps the server-support probe — `chooseServer`, which performs live network I/O (registry lookup, plus capability fetches when a new client is set up), followed by the in-memory `supportsSystem` check — in `catch (Exception)` and, whenever `canRunWithoutTerminology` is set, flips `noTerminologyServer=true` and keeps going:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L839-L848
```java
            } catch (Exception e) {
              if (canRunWithoutTerminology) {
                noTerminologyServer = true;
                logger.logMessage("==============!! Running without terminology server !! ==============");
                if (terminologyClientManager.getMasterClient() != null) {
                  logger.logMessage("txServer = " + terminologyClientManager.getMasterClient().getId());
                  logger.logMessage("Error = " + e.getMessage() + "");
                }
                logger.logMessage("=====================================================================");
                return new SystemSupportInformation(false);
```

The design intent of `canRunWithoutTerminology` is evidently graceful degradation when no terminology server is available — IG Publisher and `ValidationEngine` set it only when no tx server is configured at all. kindling is the one stock consumer that combines the flag with a live server: it sets `canRunWithoutTerminology` for all non-web builds ([Publisher.java#L2482](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L2482)) while still validating against tx.fhir.org. So any single exception escaping the probe mid-build — a transient network failure or server error in stock single-threaded builds; a race in the routing maps, or in the cache's `getServerId` reached through new-client setup, once validation is parallelized — permanently converts the run to "no terminology server". (The layer-1 `csCache`/`vsCache` races surface elsewhere — `cacheValueSet`/`cacheCodeSystem` run outside this try — but the routing layer is inside it, and so is `getServerId`, called when a newly constructed client caches its server capabilities.) A console banner is printed, but the build continues with terminology permanently disabled: every subsequent batch validation returns an ERROR-severity NOSERVICE result ([BaseWorkerContext.java#L1245-L1246](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1245-L1246)), and `ConceptMapValidator` renders NOSERVICE results as hard `CONCEPTMAP_VS_INVALID_CONCEPT_CODE` errors ([ConceptMapValidator.java#L206-L215](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ConceptMapValidator.java#L206-L215) — only `CODESYSTEM_UNSUPPORTED`/`_VERSION` are downgraded to warnings; NOSERVICE falls through to the error branch). That asymmetry is hard to read as intended: "the server doesn't know this system" is a warning, but "the client stopped asking" is a hard error.

**Consequences.** Two populations. In default (non-web) kindling builds today — single-threaded, no flags — one transient probe exception mid-build silently corrupts validation output rather than failing the build; this is code-provable from the path above (we have not measured how often transient tx failures trip it in the wild — our observed instances were race-triggered). Under the author's 12-thread harness, a race-induced exception tripping the layer-3 flip produced **217-220 bogus validation errors** in a single occurrence, of the form "The code 'X' in the system http://snomed.info/sct is not valid in the value set 'null'". The corruption is timing-dependent — some runs clean, some corrupted, same inputs — which makes it look like flaky terminology data rather than a thread-safety bug. The same races are what currently stands between the spec build and straightforwardly parallelized example validation.

**Repro.** For the races (layers 1-2): run example validation across a thread pool sharing one `BaseWorkerContext` with a cold terminology cache; reproduces within a few runs. (Optional: the author's kindling branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) — whose parallel-validation commit runs example validation across a pool — is such a harness when run against unfixed core.) For layer 3, no concurrency is needed: any exception thrown inside `getTxSupportInfo`'s try block during a `canRunWithoutTerminology` build takes the silent-disable path — observable as the "Running without terminology server" banner mid-build followed by a build that completes with spurious `CONCEPTMAP_VS_INVALID_CONCEPT_CODE` errors.

**Status / recommendation.** Fixed in the author's workspace PR branch [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (fhir-core fork, commit a4030ee0a): synchronization, copy-on-write server list, narrowed catch, and a NOSERVICE downgrade in `ConceptMapValidator`. Independently actionable upstream asks, smallest first: **(a)** downgrade NOSERVICE in `ConceptMapValidator` to a warning, consistent with the existing `CODESYSTEM_UNSUPPORTED` handling — a one-line change that turns silent corruption into visible degradation; **(b)** in `getTxSupportInfo`, stop converting an arbitrary mid-run exception into a permanent global "no terminology server" state — narrow the catch, fail the system being probed rather than the whole service, or make the flip loud for builds that did have a working server; **(c)** decide the threading model and finish the locking that the `TerminologyCache` TODO already defers — or document the context as single-threaded and amend the `IWorkerContext` javadoc that currently promises thread safety.

---

## 3. `validateCodeBatch` returns degraded results vs singular validation

**Setup.** `BaseWorkerContext` has two paths for asking a terminology server to validate a coding: the singular path ([`validateOnServer2` → `addServerValidationParameters`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1893-L1980)), which carefully assembles the request, and the batch path ([`validateCodeBatch`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1205-L1293)), which packs many codings into one `$batch` request. The two are documented as equivalent — the javadoc on `IWorkerContext.validateCodeBatch` promises "Each is the same as a validateCode" ([IWorkerContext.java#L756-L764](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/IWorkerContext.java#L756-L764)) — and callers rely on that: they consume the two interchangeably and surface their messages side by side. `ValueSetValidator` even splits a single include's concept list across both, validating the first concept singularly and batching the rest ([ValueSetValidator.java#L478-L491](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ValueSetValidator.java#L478-L491)). The batch path has nonetheless drifted from the singular one in seven ways.

**The bug.** The batch path hand-rolls its request and response handling instead of reusing `addServerValidationParameters`/the singular result path, and omits seven things the singular path does. On the request side, the batch attaches the ValueSet with only a bare `url`:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1257-L1262
```java
    if (vs != null) {
      if (passVS) {
        batch.addParameter().setName("tx-resource").setResource(vs);
      }
      batch.addParameter("url", vs.getUrl());
    }
```

and on the response side it passes `null` instead of the ValueSet url into `processValidationResult` (the singular path passes `vs.getUrl()` at [L1918](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1918)):

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1283-L1287
```java
        if (r.getResource() instanceof Parameters) {
          t.setResult(processValidationResult((Parameters) r.getResource(), null, tc.getAddress()));
          if (txCache != null) {
            txCache.cacheValidation(t.getCacheToken(), t.getResult(), TerminologyCache.PERMANENT);
          }
```

The full list of gaps, batch relative to singular. One framing fact matters for which gaps bite by default: **every call site that runs in a default configuration passes `vs = null`** (see Consequences), so the vs-dependent gaps are marked latent:

1. No dependent resources — referenced ValueSets, COMPLETE/FRAGMENT CodeSystems, and supplements attached as `tx-resource` by `addDependentResources` ([L1946](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1946)). **Active even with `vs = null`**: the singular path still attaches COMPLETE/FRAGMENT CodeSystems and supplements for each coding's system via the `systems` loop ([L1948-L1952](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1948-L1952)), while the batch computes the same `systems` set ([L1270-L1271](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1270-L1271)) but uses it only to choose a server ([L1276](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1276)).
2. No `cache-id` bookkeeping ([L1953](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1953)). Largely latent today: the cache-id protocol is disabled ecosystem-wide (bug 14), though the singular path still sends the `cache-id` parameter itself unconditionally and the batch never does.
3. No `valueSetVersion` ([L1930-L1932](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1930-L1932)) — batch sends only `url` ([L1261](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1261), excerpt above). Latent: the only stock caller that passes a ValueSet at all (`CodingsObserver`, below) uses a synthetic ValueSet with no version.
4. Wrong expansion-parameter merge semantics — singular translates `defaultDisplayLanguage` and respects override order ([L1962-L1974](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1962-L1974)); batch dumps the raw expansion parameters into each sub-request (`constructParameters`, [L1698](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1698)), including `defaultDisplayLanguage` itself and possible duplicates of `displayLanguage`. Active by default.
5. No `mode=lenient-display-validation` ([L1976-L1978](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1976-L1978)). To be precise: both paths send the `lenient-display-validation` boolean from `setTerminologyOptions` ([L1715-L1717](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1715-L1717)); only the singular path adds the `mode` parameter spelling, so a server that honors only `mode` treats batch sub-requests as strict. `ValueSetValidator` requests display-warning mode at its batch call site, so the spelling difference is live there.
6. No `diagnostics=true` ([L1979](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1979)). Active by default.
7. Response handling passes `null` instead of the VS url to `processValidationResult` ([L1284](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1284), excerpt above) — equivalent when `vs` is null, divergent for `CodingsObserver` — and never updates the unsupported-systems memo (`updateUnsupportedCodeSystems`, [L1702-L1706](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1702-L1706)), which applies to every caller (the batch *reads* that memo at [L1243](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1243) but never arms it). Active by default.

**Consequences.** Identical codes validated via the batch path yield fewer/weaker messages than the singular path. The one measured number: routing a full spec build's validations through the *stock* batch path (the author's batch-prefill experiment — non-default routing, unmodified batch code) lost **~650 warnings** (3693→3037), silently. That number characterizes the divergence of the shipped code path under heavy use, not a loss in the default configuration, where the batch path carries less traffic: it runs out of the box wherever the validator batches concept checks against a server that advertises batch support — [`ConceptMapValidator` L204](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ConceptMapValidator.java#L204), the validator's [`ValueSetValidator` L520](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ValueSetValidator.java#L520) — plus ValueSet narrative rendering ([`ValueSetRenderer` L1740](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/renderers/ValueSetRenderer.java#L1740)), and — only when IPS code checking is enabled (`checkIPSCodes`, [default `false`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation.cli/src/main/java/org/hl7/fhir/validation/cli/picocli/options/InstanceValidatorOptions.java#L149)) — [`CodingsObserver` IPS checks L105](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/codesystem/CodingsObserver.java#L105). All of these pass `vs = null` except the opt-in `CodingsObserver`, so the divergences active in default configurations are gaps 1, 4, 6, and the memo half of 7 (5 depending on server spelling support). One user-visible default-config symptom follows directly from the `ValueSetValidator` split: the first concept of an include is validated singularly and the rest batched, so any divergence surfaces as inconsistent messages between sibling concepts of the same ValueSet in one validation report.

**Repro.** Wire-level, no workspace needed: with tx logging enabled, validate a ValueSet whose `compose.include` enumerates several concepts from one server-supported system, and compare the logged singular request for the first concept against the `$batch` sub-requests for the rest — the batch entries lack `diagnostics`, lack attached dependent CodeSystems/supplements (visible when the local context holds a COMPLETE/FRAGMENT CodeSystem or supplement for the system), and carry the raw expansion parameters (including `defaultDisplayLanguage`) instead of the merged set. Optionally, the reconciliation commit `fe25b5e3d` on the author's workspace branch `spike/core-batch-tx` enumerates and fixes all seven gaps.

**Status.** A fix exists on the author's workspace branch `spike/core-batch-tx` (commit `fe25b5e3d`); it is not in the main PR branches, and the two-pass feature that motivated it is parked. Concrete ask, independent of that branch: make `validateCodeBatch` build each sub-request through `addServerValidationParameters` (or a shared helper) and post-process responses identically to the singular path (pass the ValueSet url, update the unsupported-systems memo). If instead the batch is intended as a deliberately lighter-weight check, change the documented contract on `IWorkerContext.validateCodeBatch` — today it promises "Each is the same as a validateCode", and callers mix the two paths within a single resource on that assumption.

---

## 4. Unknown-system answers are never remembered: an early return in `validateCode(Coding)` skips the per-run unsupported-system memo, so every occurrence re-asks the server

**Setup.** `BaseWorkerContext.validateCode(Coding)` (the five-arg overload at [BaseWorkerContext.java#L1429](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1429)) tries local validation first, then asks the terminology server. For code systems the server doesn't know, the design is stated in an in-line comment: "we never cache unsupported code systems - we always keep trying (but only once per run)". The first half is enforced by the persistent cache itself — `TerminologyCache.store` drops `CODESYSTEM_UNSUPPORTED` results for version-less requests unless the test-utilities-only `cacheErrors` static is set ([TerminologyCache.java#L701-L706](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L701-L706)) — so that exclusion is deliberate and not at issue here. The "only once per run" half is a memo, `unsupportedCodeSystems`, armed by `updateUnsupportedCodeSystems` and consulted before the server call ([L1528](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1528)). Spec example resources routinely use fictional code systems (`http://example.org/fhir/foo-types`, `http://acme.com/...`), so "this system is unknown" is one of the most-repeated answers in a build — and under the stated design it should cost exactly one server round trip per system per run.

**The bug.** When local evaluation of an unknown system records a warning (a `VSCheckerException` of type `CODESYSTEM_UNSUPPORTED` becomes `localWarning`, [L1470-L1475](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1470-L1475)) and the server then also answers `CODESYSTEM_UNSUPPORTED` with the code's system in `unknownSystems`, the "go with the local warning" branch rebuilds a WARNING `ValidationResult` and **returns early** — skipping the per-run memo update at line 1563:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1557-L1567

```java
    } else if (!res.isOk() && res.getErrorClass() == TerminologyServiceErrorClass.CODESYSTEM_UNSUPPORTED && res.getUnknownSystems() != null && res.getUnknownSystems().contains(codeKey) && localWarning != null) {
      // we had some problem evaluating locally, but the server doesn't know the code system, so we'll just go with the local error
      res = new ValidationResult(IssueSeverity.WARNING, localWarning, null);
      res.setDiagnostics("Local Warning: " + localWarning.trim() + ". Server Error: " + res.getMessage());
      return res;
    }
    updateUnsupportedCodeSystems(res, code, codeKey);
    if (cachingAllowed && txCache != null) { // we never cache unsupported code systems - we always keep trying (but only once per run)
      txCache.cacheValidation(cacheToken, res, TerminologyCache.PERMANENT);
    }
    return res;
```

For fictional example systems this branch is the one that always runs (with vs = null, local validation reliably raises the unsupported-system warning and the server reliably doesn't know the system), so the memo is never armed and the next `validateCode` for the same system is a fresh server round trip. (The early return also skips the cache write at lines 1564-1566, but for an unsupported-class result that write would have been dropped by the store filter above anyway — the persistent-cache exclusion is by design; the memo skip is not.)

It was not always so. From its introduction in core commit `f13a487c3` (Sept 13 2023, "Correct validation when CodeSystem.content = example and server doesn't know code system") this branch mutated the server result in place (`res.setMessage(localWarning)`) and fell through to `updateUnsupportedCodeSystems`; commit `441825275` (Dec 15 2023) downgraded the severity to WARNING, still falling through; commit `792f2191d` (Jan 4 2024, "more terminology qa updates") replaced the mutation with a fresh `ValidationResult` and added the `return res;`. Nothing in that commit indicates skipping the memo was intended — for the four months prior, this exact case armed it.

A second, minor bug sits in the same lines: the `setDiagnostics` call composes `"Local Warning: " + localWarning + ". Server Error: " + res.getMessage()` — but `res` was just reassigned on the previous line, so the "Server Error:" text is the local warning repeated and the server's actual message is discarded. (The comment also says "local error" where it means the local warning.) This one predates the early return: ever since the Sept 2023 introduction, the diagnostics string has been composed after the message was overwritten, so the server's message has never actually appeared after "Server Error:".

A related asymmetry worth fixing at the same time: `processValidationResult` ([L2105](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2105)) treats the two unknown-system response spellings differently — `x-caused-by-unknown-system` sets the error class to `CODESYSTEM_UNSUPPORTED`, while `x-unknown-system` only populates `unknownSystems` and never sets the error class — so a server signalling unknown systems only via the latter spelling (and not also via the legacy `cause` parameter, [L2176](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2176), whose `not-found` also maps to `CODESYSTEM_UNSUPPORTED`) cannot arm the memo:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2139-L2150

```java
        } else if (p.getName().equals("x-caused-by-unknown-system")) {
          String unkSystem = ((PrimitiveType<?>) p.getValue()).asStringValue();
          if (unkSystem != null && unkSystem.contains("|")) {
            err = TerminologyServiceErrorClass.CODESYSTEM_UNSUPPORTED_VERSION;
            system = unkSystem.substring(0, unkSystem.indexOf("|"));
            version = unkSystem.substring(unkSystem.indexOf("|") + 1);
          } else {
            err = TerminologyServiceErrorClass.CODESYSTEM_UNSUPPORTED;
            unknownSystems.add(unkSystem);
          }
        } else if (p.getName().equals("x-unknown-system")) {
          unknownSystems.add(((PrimitiveType<?>) p.getValue()).asStringValue());
```

Current tx.fhir.org returns `x-caused-by-unknown-system` for both the CodeSystem and ValueSet `$validate-code` shapes (verified live, June 2026), so on that server the early return above is the operative bug.

**Consequences.** Every coding from an unknown/fictional system round-trips to the server on every occurrence, where the stated design budgets one probe per system per run. We counted **22 separate POSTs for one fictional system** in one build — 21 more than the design intends. Narrative generation makes this unbounded: `DataRenderer.lookupCode` ([DataRenderer.java#L313-L323](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/renderers/DataRenderer.java#L313-L323)) calls `validateCode(options, system, version, code, null)` → `validateCode(Coding, vs=null)` ([BaseWorkerContext.java#L1181-L1185](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1181-L1185)) with useClient and useServer both on, so every rendered example mentioning the system pays a round trip, in every build (the once-per-build retry is by design; the per-occurrence repeats within a build are the bug). Related gaps in the same memo, possibly intentional but worth deciding deliberately: the CodeableConcept validation path ([L1723-L1816](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1723-L1816)) neither consults nor updates the memo at all, and versioned codings are excluded from memoization (`!code.hasVersion()` in `updateUnsupportedCodeSystems`, [L1702-L1706](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1702-L1706)).

**Repro.** With a context configured with a terminology server and a tx cache, call `validateCode(new ValidationOptions(), new Coding().setSystem("http://example.org/fhir/foo-types").setCode("xyz"), null)` twice (useClient/useServer at their defaults, vs = null): the tx log shows two identical `$validate-code` round trips and nothing is written to the tx cache. Equivalently, validate any resource containing a coding from a made-up system twice, or grep a cold build's server log for `example.org` request counts.

**Status / recommendation.** No upstream fix. The repeat-traffic harm is fixed on the author's master-based branch [`perf/narrative-lookup-cache`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/narrative-lookup-cache) (caches the rebuilt warning TRANSIENT under its request token, so repeats within a run come from memory and each new run re-asks once — the same per-run policy the adjacent keep-trying comment documents; it deliberately leaves the memo and diagnostics behavior unchanged). The fuller minimal fix is confined to the early-return branch: capture the server's message into a local before `res` is reassigned (fixing the diagnostics string), and call `updateUnsupportedCodeSystems(res, code, codeKey)` on the server result *before* rebuilding it. Note that simply moving the `return` below line 1563 would not work: the rebuilt result has no error class, so the memo would stay unarmed — and the synthesized warning would then be written to the persistent cache, against the documented keep-trying intent. One decision for upstream to make explicitly: arming the memo restores the Sept 2023 – Jan 2024 behavior, in which the second and later occurrences short-circuit at L1528 with an ERROR-severity unknown-CodeSystem result where this branch returns a WARNING; if that severity difference matters, the memo replay should carry the warning severity for warning-class entries. A client-side workaround (local synthesis of unknown-system answers, byte-identical to 11/11 captured server responses) lives in the author's pushed chain [`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain) (commit d7f9f3e06, gated by `-Dorg.hl7.fhir.tx.localFirst`); optional reference only, not needed for the repro or the fix.

---

## 5. Registry routing cannot represent "no server claims this system": a clean registry negative is encoded like "no information", so the client falls through to a doomed POST to the primary server

**Setup:** fhir-core routes terminology requests through `TerminologyClientManager`, which asks the tx ecosystem registry (`resolve?...&url=<system>`) which server is authoritative for each code system, then picks a server in `chooseServer(ValueSet, Set<String>, boolean)`. The registry can answer with authoritative servers, candidate servers, or — for unknown/fictional systems — neither. This path runs in the shipping defaults: `IGNORE_TX_REGISTRY` is hard-coded `false` ([TerminologyClientManager.java#L137](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L137)), and both kindling ([BuildWorkerContext.java#L120](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L120), `setMasterClient(client, true)`) and IG Publisher's main loader (`PublisherIGLoader`) pass `useEcosystem = true`.

**The gap:** A clean registry negative (the resolve call succeeds but returns no `authoritative` and no `candidates` entries) is encoded as an empty `ServerOptionList`, indistinguishable by type or flag from "no information":

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L451-L460

```java
    try {
      ServerOptionList ret = new ServerOptionList(url);
      JsonObject json = JsonParser.parseObjectFromUrl(request);
      for (JsonObject item : json.getJsonObjects("authoritative")) {
          ret.authoritative.add(item.asString("url"));
      }
      for (JsonObject item : json.getJsonObjects("candidates")) {
        ret.candidates.add(item.asString("url"));
      }
      return ret;
```

`chooseServer` then falls through all of its matching loops (authoritative-for-all, partially-authoritative, candidate-for-all, most-authoritative — they iterate empty lists) and lands in the catch-all fallback, which turns the negative into a `$validate-code` POST to the primary server:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L308-L316

```java
    } else {
      if (systems.size() == 1) {
        log(vs, serverList.get(0).getAddress(), systems, choices, "System not handled by any servers. Using primary server");
      } else {
        log(vs, serverList.get(0).getAddress(), systems, choices, "Systems handled by multiple servers. Using primary server");
      }
      log(vs, serverList.get(0).getAddress(), systems, choices, "Fallback: primary server");
      return findClient(serverList.get(0).getAddress(), systems, expand);
    }
```

(The `vs != null` branch at [L300-L307](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L300-L307) does the same.) The resolve-*error* path falls back to the primary the same way, returning `new ServerOptionList(url, getMasterClient().getAddress())` at [L461-L468](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L461-L468) — so "registry says nobody serves this system" and "registry unreachable" produce identical behavior.

**Is this by design?** Partly, and this report should be read with that on the table. The fallback itself is deliberate — the code logs an explicit "System not handled by any servers. Using primary server" — and, taken once per system, defensible: the registry may simply not know everything the configured primary serves, and asking the primary once yields an authoritative answer. The defect-shaped residue is representational: a successful-but-empty resolve and a failed resolve produce the same `ServerOptionList`, so no layer above can ever distinguish "known negative" from "no data" — even though the client goes to the trouble of memoizing the empty answer per system and persisting it (`resMap` in `findServerForSystem`, [L402-L415](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L402-L415), saved to `system-map.json` in the tx cache folder). Negative routing knowledge is recorded but unusable.

**Consequences:** Bounded, and the final validation results stay correct — the primary answers "unknown system" and the coding gets the proper warning — so the harm is wasted network I/O, not wrong answers. The registry resolve itself is paid only once per system (memoized in `resMap`, persisted across runs when a tx cache folder is configured). What repeats is the doomed primary-server `$validate-code` POST: because of bug #4 (unknown-system answers never memoized or cached), every occurrence of a coding from an unknown system pays that POST again, every build. With bug #4 fixed, this section's marginal cost drops to roughly one doomed POST per unknown system per run — which is why this is filed as a design concern that amplifies bug #4, not as a standalone severity item.

**Repro:** Same as #2, in the default kindling or IG Publisher configuration (ecosystem routing on) — validate codings from a fictional system (e.g. `http://example.org/fhir/foo-types`); in the tx log, observe one registry resolve GET for the system followed by a primary-server `$validate-code` POST per occurrence.

**Status / recommendation:** Smallest viable change upstream: record on `ServerOptionList` whether it came from a successful-but-empty resolve or from the resolve-error fallback (one boolean), log the two cases distinctly in `chooseServer`, and expose the "known negative" so the validation layer (bug #4's memo, once that is fixed) can stop re-POSTing after the first authoritative failure. A client-side alternative (local synthesis of unknown-system answers) lives in the author's pushed chain [`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain) (commit d7f9f3e06) — an optional reference only, not upstream code.

---

## 6. XML comments grow one space per compose/reparse cycle

**Setup:** fhir-core's element-model XML pipeline round-trips resources through compose (`org.hl7.fhir.utilities.xml.XMLWriter`) and parse (`org.hl7.fhir.r5.elementmodel.XmlParser`). Comments attached to elements (`Element.getComments()`) are carried across these round trips, and downstream composers re-emit the stored strings verbatim (the Turtle composer writes root-level comments as `# `-prefixed lines and element comments as ` # ` trailers) — whatever the parse half stores is what gets published.

**The bug:** The writer pads the comment text with one space *inside* each delimiter — deliberate pretty-printing, by the look of it — and the parser reaps the raw DOM text content, padding included. The two halves of the round trip are asymmetric: compose∘parse is not idempotent, and the error compounds.

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xml/XMLWriter.java#L488-L491
```java
		if (levels.inComment())
			write("  <!-- "+comment+" -- >");
		else
			write("  <!-- "+comment+" -->");
```

`XmlParser.reapComments` then stores `node.getTextContent()`, which for `<!-- text -->` is `" text "` — the padding becomes part of the stored comment string:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/elementmodel/XmlParser.java#L693-L699
```java
  private void reapComments(org.w3c.dom.Element element, Element context) {
    Node node = element.getPreviousSibling();
    while (node != null && node.getNodeType() != Node.ELEMENT_NODE) {
      if (node.getNodeType() == Node.COMMENT_NODE)
        context.getComments().add(0, node.getTextContent());
      node = node.getPreviousSibling();
    }
```

(The full method is [XmlParser.java#L693-L709](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/elementmodel/XmlParser.java#L693-L709); the trailing-comments loop has the same behavior. The write site is inside [`XMLWriter.comment`, #L475-L494](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xml/XMLWriter.java#L475-L494).)

**Consequences:** Every compose→parse round trip grows every comment by one leading and one trailing space. This is exercised by the stock spec build, not just unusual pipelines: kindling's example processing composes each example's element model to the published `.xml` ([Publisher.java#L5193](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L5193)), then re-parses that file and composes the result to `.canonical.xml`/`.json`/`.ttl` ([Publisher.java#L5387-L5394](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L5387-L5394)) — so at least one padding cycle is baked into every published example that carries XML comments. It is visible in published TTL (`#   <priority value="5" />` vs `#  <priority ...>`) because the Turtle composer emits comments verbatim — example outputs ended up depending on how many XML round trips the pipeline happened to take, the same shape of problem as bug 7: published bytes reflect pipeline internals rather than inputs. The harm is confined to comment whitespace; no other data is affected.

**Repro:** Parse a resource containing an XML comment, compose it, re-parse, and compare the `Element.getComments()` strings — they differ by two spaces per cycle.

**Status / recommendation:** Report-only. In the author's workspace, the build's round-trip count was made deterministic instead, which hides the symptom locally; the asymmetry itself remains upstream. The writer's one-space padding looks intentional (readability of `<!-- text -->`), so the minimal fix is on the parse side: in `XmlParser.reapComments` (both loops), strip the single leading/trailing space that `XMLWriter.comment` adds before storing the string — making compose→parse idempotent — and add a round-trip test asserting `Element.getComments()` is unchanged across two cycles. (Trimming *all* surrounding whitespace would be simpler and also works, at the cost of normalizing comments that deliberately begin or end with extra spaces.)

---

## 7. The spec build is not deterministic (same inputs → different published bytes)

**Setup:** A spec build (kindling driving fhir-core generators) should be a pure function of its inputs: building the same commit twice should publish byte-identical output (after normalizing timestamps). It doesn't — several independent sources of nondeterminism are baked into stock upstream code. To be clear about standing: upstream documents no byte-reproducibility contract, so this is filed against an implicit property — but nothing below is *intentionally* random, each source is individually small, and the codebase already concedes the point where the randomness bites its own tests (the `forTesting()` pin in item 2).

**The bug:** Four distinct sources, all upstream of our changes (reproduced on stock builds):

1. **Section numbers shuffle (kindling).** Value-set pages get sequential section numbers assigned in the iteration order of a plain `HashMap`, so numbering depends on hash order rather than anything stable:

https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L6849-L6854
```java
  private void generateValueSetsPart2() throws Exception {

    for (ValueSet vs : page.getDefinitions().getBoundValueSets().values()) {
//      page.log(" ...value set: "+vs.getId(), LogMessageType.Process);
      generateValueSetPart2(vs);
    }
```

`getBoundValueSets()` is `new HashMap<String, ValueSet>()` ([Definitions.java#L135](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/definitions/model/Definitions.java#L135)), and each page is numbered from a sequential counter as it is visited ([Publisher.java#L6901](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L6901) calling `vsCounter()`, [Publisher.java#L6919-L6922](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L6919-L6922)). Code-system pages are numbered by the same pattern ([Publisher.java#L6785-L6799](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L6785-L6799)).

   One objection to preempt: a `String`-keyed Java `HashMap` iterates reproducibly when the insertion sequence is identical, so this loop is where ordering instability becomes published bytes, not necessarily where the instability originates. The shuffle itself is observed fact, not inference: vs/cs section numbers move between two identical stock runs, and the comparison tooling in the repro has to strip section-number anchors before hashing pages at all. Independently of run-to-run behavior, hash-order numbering is fragile by construction — any unrelated change to the map's key set renumbers pages wholesale, which is diff noise across commits even when runs of one commit happen to agree.

2. **Random UUIDs in published bytes (fhir-core).** The hierarchical table generator embeds a fresh per-process UUID into every generated table script (`// 6fbd5028-...`); random UUIDs also appear in image filenames:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xhtml/HierarchicalTableGenerator.java#L126-L128
```java
  private static final String BACKGROUND_ALT_COLOR = "#F7F7F7";
  public static boolean ACTIVE_TABLES = false;
  public static String uuid = UUIDUtilities.makeUuidLC();
```

The UUID is written into output at [HierarchicalTableGenerator.java#L922-L923](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xhtml/HierarchicalTableGenerator.java#L922-L923) (`String js= "  // "+uuid+"\n";` — at this SHA, the comment marker there is the static's only consumer within fhir-core itself, and kindling never references it; the field is public, though, and the IG Publisher reads and even reassigns it elsewhere). Notably, a `forTesting()` hook already pins it to a constant ([#L1500-L1502](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xhtml/HierarchicalTableGenerator.java#L1500-L1502)) — an existing acknowledgment that the randomness breaks output comparison, and proof that a constant value is acceptable output.

3. **ShEx generation varies between identical runs (fhir-core).** Whole `EXTENDS @<BackboneElement>` blocks appear/disappear between runs (~78 `.shex` files plus their `.html` renderings differ per run). That per-run diff is the measured fact; the root cause has not been isolated. At this SHA the generation logic lives in `ShExGeneratorBase` (r5), whose working state mixes insertion-ordered and hash-ordered collections (declarations at [ShExGeneratorBase.java#L281-L294](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/conformance/ShExGeneratorBase.java#L281-L294), e.g. `HashSet<String> uniq_structure_urls` alongside several `LinkedHashSet`s); the `EXTENDS @<...>` text is emitted at [#L640-L649](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/conformance/ShExGeneratorBase.java#L640-L649). TTL/JSON-LD output shows the same class of run-to-run variance.

4. **Build reads its own prior output.** The first build in a fresh checkout differs from converged builds (e.g. `structuredefinition-category` extensions appear only from run 2 onward) — the build reads state produced by prior builds. This may well be intentional bootstrapping; even so, it means published bytes are a function of build *history*, not just of the source commit, and a fresh-checkout build cannot reproduce the published artifacts. If it is by design, the dependency deserves documentation — today it is discoverable only by diffing run 1 against run 2.

**Consequences:** Two consecutive stock builds of the same commit publish different bytes. Normalizing timestamps is not enough to make them compare equal; even after additionally normalizing the embedded random UUIDs and the section-number anchors, ~226 files still differ run-to-run (155 of them `.shex`/`.shex.html`; the remainder includes TTL/JSON-LD, expansions, conceptmap and codesystem renderings, and the packaged `.tgz`/`.zip` archives that contain them). This defeats output caching, rules out byte-level verification of published artifacts against a source commit (rebuild-and-compare can never match, so signing/attestation workflows have nothing to attest), generates spurious diffs for anyone comparing published output across builds, and means a fresh-checkout build is not even self-consistent with a converged one.

**Repro:** Run two consecutive `-nopartial` builds of the same commit; diff the publish directories. With timestamps, UUIDs, and section-number anchors normalized before hashing, ~226 files still differ. Manifest tooling in this workspace automates the comparison (`runs/manifest.py`, `runs/noise-files-v2.txt` — author's workspace, not upstream; the normalization regexes in `manifest.py` double as a catalogue of the noise patterns).

**Status / recommendation:** Report-only; no fix branch. Since no reproducibility contract exists, the ask is to adopt one incrementally — each source has a small, independent fix, in rough order of effort: **(1)** number vs/cs pages from a sorted view of the collections at the loops cited above, so section numbers are a function of content rather than map order; **(2)** make the table-script UUID deterministic (derive it from content, or promote the existing `forTesting()` constant — the test hook already demonstrates pinning is safe) and do the same for UUID-named images; **(3)** stabilize ShEx output by sorting emitted lists at the generator — correct regardless of where the variance enters; **(4)** document the prior-output dependency, or make a first build converge in one pass. Items 1–3 are mechanical; item 4 may be working as designed and only needs to be written down.

---

---

## 8. kindling keys the local-build terminology cache to the alphabetically-first git branch, not the checked-out branch

**Setup.** When kindling builds the spec from a local GitHub clone (i.e., outside CI — CI builds take their branch from the `SYSTEM_PULLREQUEST_SOURCEBRANCH`/`CI_BRANCH_DIRECTORY` environment variables and are unaffected), `Publisher.checkGit` inspects the repository to derive an org/repo/branch triple. That triple selects the persistent terminology cache directory (`~/.fhir/tx-cache/{org}/{repo}/{branch}`) and the URL of the CI cache-bootstrap zip downloaded from tx.fhir.org. The path layout makes the design intent plain: one cache per branch. Scope: within fhir-core, kindling, and IG Publisher, the only production consumer of `TerminologyCacheManager` is kindling's `PageProcessor`, so this is a spec-build bug, not a general fhir-core one.

**The bug.** `checkGit` never asks which branch is checked out. It iterates `git.branchList().call()` — JGit's `ListBranchCommand` sorts refs by name, so local branches come back in alphabetical order — and returns out of the loop on the **first ref**, so `ghBranch` (and `ciDir`, copied from it) is the alphabetically-first local branch name, regardless of HEAD. The unconditional `return` inside the loop reads as code written for a clone with exactly one local branch, where it is accidentally correct:

https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L634-L641
```java
            List<Ref> branches = git.branchList().call();
            for (Ref ref : branches) {
              page.getFolders().ghBranch = ref.getName().substring(ref.getName().lastIndexOf("/") + 1, ref.getName().length());
              // We won't have an explicit CI dir, so set this to ghBranch
              page.getFolders().ciDir = page.getFolders().ghBranch;
              System.out.println("This is a GitHub Repository: https://github.com/"+page.getFolders().ghOrg+"/"+page.getFolders().ghRepo+"/"+page.getFolders().ghBranch);
              return;
            }          
```

That value flows via [`PageProcessor` (kindling, L10355-L10356)](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/PageProcessor.java#L10355-L10356) into fhir-core's `TerminologyCacheManager`, which uses it both for the on-disk cache directory and for the bootstrap zip URL (`https://tx.fhir.org/tx-cache/{org}/{repo}/{branch}.zip`, [L66-L69](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L66-L69)):

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L54-L58
```java
    if (Utilities.noString(ghOrg) || Utilities.noString(ghRepo) || Utilities.noString(ghBranch)) {
      cacheFolder = Utilities.path(rootDir, "temp", "tx-cache");
    } else {
      cacheFolder = Utilities.path(System.getProperty("user.home"), ".fhir", "tx-cache", ghOrg, ghRepo, ghBranch);
    }
```

**Consequences.** Observed live: building `master` while the cache read/wrote `.../integrate-FHIR-11050-empty-2/`. Two concrete effects:

1. **Per-branch cache isolation is silently defeated.** Every branch in the clone reads and writes one directory, named after a branch that need not be the one being built — the `Load Terminology Cache from ...` log line names that other branch, which is the only visible signal. The mixing is not provably harmless: for a ValueSet with `url` and `version`, the persistent cache key is identity-based, not content-based ([`generateValidationToken`, TerminologyCache.java L505-L507](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L505-L507)), and spec branches typically carry the same spec version string — so an answer cached from one branch's definition of a ValueSet can be served while building another branch whose definition differs. (What was observed is the cross-branch directory mixing; a resulting wrong validation answer was not separately captured.)
2. **The cache silently relocates when the branch list changes.** Creating a local branch that sorts before the previous first one moves the cache directory: the accumulated local cache is abandoned, and the next build re-bootstraps from tx.fhir.org — first from `…/{branch}.zip`, which names a branch that may exist only locally and 404s, then from the org-wide `default.zip` fallback ([`initialize`, L70-L73](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L70-L73)). Where neither zip exists (forks — see bug 13), that build runs fully cold.

**Repro.** Self-contained: in a local `HL7/fhir` clone with a working build, create a branch name that sorts before every existing one (`git branch 000-test`), stay on `master`, run a build, and read the `Load Terminology Cache from ...` log line ([PageProcessor L10356](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/PageProcessor.java#L10356)) — the path ends in `000-test`, not the checked-out branch.

**Status / recommendation.** The fix is a few lines in `checkGit`: ask JGit for HEAD's branch (`git.getRepository().getFullBranch()`) instead of taking the first entry of `branchList()`, with a fallback for detached HEAD. Implemented that way in the author's workspace branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) (kindling fork, commit 5 — optional reference, not needed to reproduce or fix).

---

## 9. Hot-path allocation/CPU bugs: per-character varargs allocation in `isWhitespace`; terminology cache keys re-serialize Parameters/ValueSet JSON on every call, even cache hits

**Setup:** Two utility paths in fhir-core sit directly under every JSON serialization and every terminology validation call, in every consumer (validator, IG Publisher, kindling): `Utilities.escapeJson` is invoked for each string written by the JSON composers ([JsonCreatorDirect.java#L163](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/formats/JsonCreatorDirect.java#L163)), and `TerminologyCache.generateValidationToken` builds the cache key for each `validateCode` call whenever the terminology cache is enabled (`cachingAllowed`, the default). Both run millions of times in a spec build, so per-call waste here dominates the allocation and CPU profiles.

**The bug:** Three independent hot-path defects, all in fhir-core, all active in the default configuration:

1. `Utilities.isWhitespace` checks membership in a 25-element list via `existsInList(int, int...)`, which allocates a fresh 25-element varargs `int[]` on **every call** — and `escapeJson` ([Utilities.java#L1004-L1030](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/Utilities.java#L1004-L1030)) calls it for every character of every escaped string except the six explicitly-escaped ones (`\r` `\n` `\t` `"` `\` space) — i.e., nearly every character.

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/Utilities.java#L1773-L1777
```java
  public static boolean isWhitespace(int ch) {
    return Utilities.existsInList(ch, '	', '\n', '','','\r',' ','',' ',
        ' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',
        ' ', ' ', ' ', ' ', '　');
  }
```

2. The `TerminologyCache.generateValidationToken` overloads ([TerminologyCache.java#L491-L580](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L491-L580)) pretty-print-serialize the expansion `Parameters` to JSON on **every** `validateCode` call — and, when the ValueSet lacks a url+version, also its "essence" via `extracted(...)`/`getVSEssense(...)` (ValueSets above 1000 codes fall back to just the url):

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L501-L503
```java
      JsonParser json = new JsonParser();
      json.setOutputStyle(OutputStyle.PRETTY);
      String expJS = expParameters == null ? "" : json.composeString(expParameters);
```

This cost is paid even on cache hits, because the token is generated before the cache is consulted ([BaseWorkerContext.java#L1437-L1441](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1437-L1441)). To be clear about intent: the human-readable pretty-JSON request text is plausibly by design — the on-disk `.cache` files are meant to be read and diffed — and nothing here requires changing that format. The defect is recomputation: the expansion `Parameters` change only through explicit setters ([`setExpansionParameters`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2286-L2289) and a locale update) — in practice they are constant for a whole build — yet their JSON is rebuilt from scratch for every token, including the calls that go on to hit the cache (and `getExpansionParameters()` hands the token generator a fresh deep copy of the `Parameters` each call: [BaseWorkerContext.java#L2281-L2284](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2281-L2284)).

3. `JsonParserBase.compose` wraps its output stream in an `OutputStreamWriter` with no `BufferedWriter` ([JsonParserBase.java#L204](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/formats/JsonParserBase.java#L204) and [#L258](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/formats/JsonParserBase.java#L258)), so every individual `write()` from the JSON emitter invokes the charset encoder, each invocation allocating a fresh `HeapCharBuffer`.

**Consequences:** In a profiled spec build, JFR attributed **104GB** of `int[]` allocation to the `isWhitespace` varargs path alone — roughly half of a **3.1GB/s** allocation storm. About **73%** of validation-phase CPU was JSON serialization for cache keys (item 2). The writer without buffering (item 3) accounted for **34GB** of `HeapCharBuffer` allocation. None of this work produces different results; it is pure overhead on the hottest paths of the build.

**Repro:** Record JFR with `jdk.ObjectAllocationSample` and `jdk.ExecutionSample` enabled on any validation-heavy workload (e.g. a spec build); the three sites above dominate the allocation and CPU profiles.

**Status / recommendation.** All three fixes are small, independent, behavior-preserving one-file patches: (1) a switch- or table-based `isWhitespace` (no per-call allocation), (2) memoizing the expansion-`Parameters` JSON in the cache-key path, recomputed only if the parameters are changed — the keys stay byte-identical, so existing on-disk `.cache` files remain valid — and (3) wrapping the composer's writer in a `BufferedWriter`. All three are implemented together on the author's workspace branch [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (switch-based `isWhitespace`, memoized cache keys, buffered writers); that branch is reference material only, not needed to reproduce or to fix.

---

## 10. kindling forces a full GC after every validated example — 40% of stock build time is explicit-GC pause

**Setup.** During the core spec build, kindling validates every example resource in the specification via `ExampleInspector.doValidate(...)`, called once per example file. This path is on by default: `Publisher.main` hardcodes `pub.doValidate = true` ([Publisher.java#L545](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L545)) — the only command-line opt-outs are `-validation-mode none` and `-post-pr`, which skip the whole validation pass at [Publisher.java#L6553](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L6553) — and the measured stock build takes it (the JFR counts below confirm the path ran). The build runs with a large heap (14GB in the measured configuration), so any full collection has to walk a large live set.

**The bug.** `doValidate` ends with an unconditional explicit GC, so the JVM performs a forced full stop-the-world collection after every single example validated:

https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/ExampleInspector.java#L353-L360
```java
        warningCount++;
      else if (m.getLevel() == IssueSeverity.INFORMATION)
        informationCount++;
      else
        errorCount++;
    }
    Runtime.getRuntime().gc();
  }
```

Three more unconditional `System.gc()` sites sit on the build path: [`Publisher.java#L3619`](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L3619) and `PageProcessor.clean()`/`clean2()`:

https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/PageProcessor.java#L11523-L11529
```java
  public void clean2() {
    if (definitions.getCodeSystems() != null) 
      definitions.getCodeSystems().clear();
    if (definitions.getValuesets() != null) 
      definitions.getValuesets().clear();
    System.gc();
  }
```
(`clean()`'s `System.gc()` is at [`PageProcessor.java#L11520`](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/PageProcessor.java#L11520).)

**Is it by design?** The `clean()`/`clean2()` sites look deliberate — they null out large structures and then ask for a collection, presumably to keep the build's footprint down between phases. Even granting that intent, the calls don't achieve it: an explicit GC cannot lower the live-set requirement, because anything unreachable is reclaimable on demand the moment the heap actually needs the space. And the per-example call in `doValidate` — the one that fires hundreds of times — has no such between-phases rationale; it just forces a full pause after every file. The measured `-XX:+DisableExplicitGC` run (below) completed normally on the same 14GB heap, so the build demonstrably does not need any of these calls to fit in memory; they buy nothing but pause time.

**Consequences.** JFR shows **934 explicit-GC events per build** (`jdk.SystemGC`, across all four call sites — the per-example site dominates: each of the other three executes only once per build), totaling **272s of stop-the-world pause — 40% of the entire stock build** (683s total, 14GB heap). Each forced full collection walks the whole live heap, once per example file.

**Repro.** Self-contained, no special setup: run JFR on a stock build and count `jdk.SystemGC` events; or simply run the build with `-XX:+DisableExplicitGC`: 683s → 379s with zero code change.

**Status / recommendation.** The smallest worthwhile fix is one deleted line: remove the `Runtime.getRuntime().gc()` at the end of `ExampleInspector.doValidate` (and, ideally, the three other unconditional `System.gc()` sites — or guard them behind a debug flag if the between-phases footprint trimming is still wanted for memory diagnostics). A zero-code interim alternative is adding `-XX:+DisableExplicitGC` to the documented build invocation, which alone recovers the full 683s → 379s. For reference only (not required for the fix or the repro): the deletion is applied in the author's workspace branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) (commit 1).

---

## 11. `BaseWorkerContext` and `TerminologyCache` share one lock; whole cache-page file rewrites happen under it

**Setup.** `BaseWorkerContext` is fhir-core's central resource/terminology context, and it guards essentially all of its state — resource maps, code systems, value sets — with a single private monitor object. `TerminologyCache` is the disk-backed cache of terminology-server answers, persisted as one "page" file per named cache (e.g. one file per code system). The context hands its own lock to the cache at construction time, so the two components serialize on the same monitor.

**The bug.** The context's lock ([BaseWorkerContext.java#L260](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L260)) is passed straight into the cache:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2244-L2249
```java
  public void initTxCache(String cachePath) throws FileNotFoundException, FHIRException, IOException {
    if (cachePath != null) {
      txCache = new TerminologyCache(lock, cachePath);
      initTxCache(txCache);
    }
  }
```

(the receiving constructor is explicit about it — `// use lock from the context`, [TerminologyCache.java#L384-L387](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L384-L387)).

The cache then does disk I/O while holding that shared lock. `cacheValidation` takes the lock and calls `store(...)`:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L768-L779
```java
  public void cacheValidation(CacheToken cacheToken, ValidationResult res, boolean persistent) {
    if (cacheToken.key != null) {
      synchronized (lock) {      
        NamedCache nc = getNamedCache(cacheToken);
        CacheEntry e = new CacheEntry();
        e.request = cacheToken.request;
        e.persistent = persistent;
        e.v = new ValidationResult(res);
        store(cacheToken, persistent, nc, e);
      }    
    }
  }
```

`store` ([L696-L728](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L696-L728)) calls `save(nc, now)` ([L820](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L820-L829)), which rewrites the **entire** named cache page file — every entry, each embedding its serialized ValueSet — still inside the shared monitor. For SNOMED that is ~110KB per entry; on the earlier 6.9.1-SNAPSHOT line, where every persistent store triggered a rewrite, that compounded to ~4.9GB of cumulative writes over one cold build. Current master coalesces saves (see Status), so the cumulative figure no longer applies as measured — but each save that does fire is still a full-page rewrite under the monitor. Meanwhile every other context operation (resource fetches, code-system lookups) is queued behind the same lock waiting for that file I/O.

The sharing is deliberate — the constructor comment says so — presumably to keep one coarse monitor rather than reason about lock ordering. But it is not load-bearing: `TerminologyCache` holds no reference back into the context, so it is a natural self-synchronized leaf, and fhir-core itself already constructs one with a private lock in another path (`new TerminologyCache(new Object(), ...)`, [ValidationService.java#L647](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/service/ValidationService.java#L647)). Nothing in the cache's contract requires the context's monitor; sharing it only couples the cache's disk I/O latency into every context read.

**Consequences.** JFR-measured during 12-thread validation, taken on the 6.9.1-SNAPSHOT line before upstream's save-coalescing: 593 seconds of monitor-blocking inside a 67-second wall-clock window — **74% of all validator thread-time** queued behind this one lock, mostly threads in `fetchResourceWithExceptionByVersion` waiting for cache file I/O. Those magnitudes will be lower on current master (not re-measured there); what is unchanged at the pinned commit is the structure: every cache read and write serializes with every resource fetch on one monitor, and the page-file rewrite, when it fires, runs inline under it. The contention cost manifests only when one context is shared across validating threads — a stock serial kindling build pays the same file I/O as inline latency instead. (Making shared-context multi-threading safe at all is bug 2; this lock is the scaling ceiling once it is.)

**Repro.** Record JFR with `jdk.JavaMonitorEnter` enabled on any workload that validates from multiple threads against a shared context; the blocked time concentrates on the `BaseWorkerContext` lock.

**Status.** Fixed in the author's workspace branch [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (lock split; the cache becomes a self-synchronized leaf) — optional reference, not needed to act on this. Upstream master had independently improved persistence — commit `94ce573f5` ("fix caching bug", May 23 2026, first released in 6.9.8) coalesces saves into 5s windows (`SAVE_DELAY_MS = 5000`, [L185](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L185)), and a later commit (`df9504f6e`, "2026 06 gg txcache" / PR #2472, June 9 2026, on master at the pinned commit but not yet in any tagged release as of 6.9.9) caps each named cache at 5000 entries — but the lock is still shared. Recommendation: give the cache its own private monitor at the construction sites (R5 `initTxCache` and the default field initializer, plus the R4/R4B equivalents), as `ValidationService` already does; moving the page-file write itself outside the monitor is the natural follow-on.

---

## 12. kindling's local terminology short-circuits are bypassed by the validation paths that need them

**Setup.** kindling's `BuildWorkerContext` extends fhir-core's `BaseWorkerContext` and adds local short-circuits for terminology the spec build hits constantly: it overrides the 5-arg `validateCode(options, system, version, code, display)` to answer SNOMED, LOINC, UCUM, and `http://example.org` codes locally — SNOMED and LOINC from bundled tables (with a one-time server fallback for codes not in them), UCUM fully locally via a `UcumEssenceService` — so the build's SNOMED/LOINC/UCUM lookups should mostly never need to reach tx.fhir.org.

**The bug.** The override covers only one overload — and the validator paths that generate the bulk of the traffic never call it.

https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L360-L371

```java
  public ValidationResult validateCode(ValidationOptions options, String system, String version, String code, String display) {
    try {
      if (system.equals("http://snomed.info/sct"))
        return verifySnomed(code, display);
    } catch (Exception e) {
      return new ValidationResult(IssueSeverity.WARNING, "Error validating snomed code \""+code+"\": "+e.getMessage(), null);
    }
    try {
      if (system.equals("http://loinc.org"))
        return verifyLoinc(code, display);
      if (system.equals("http://unitsofmeasure.org"))
        return verifyUcum(code, display);
```

(The same method short-circuits `http://example.org` at [L376–L377](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L376-L377) before falling through to `super.validateCode` at [L384](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L384).)

But the binding-driven checks that dominate example validation go through the `Coding`/`CodeableConcept` overloads of `InstanceValidator.checkCodeOnServer` ([InstanceValidator.java L8972–L9022](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L8972-L9022)), which call the `Coding`/`CodeableConcept` forms of `context.validateCode` — overloads kindling does not override, so they go straight to `BaseWorkerContext` and the network. Dispatch runs the wrong way for the override, too: `BaseWorkerContext`'s 5-arg form delegates *into* its `Coding` form ([BaseWorkerContext.java L1181–L1185](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1181-L1185)), never the reverse, so the `Coding`/`CodeableConcept` paths cannot reach kindling's short-circuits even indirectly.

Within `InstanceValidator` itself, the only route into the 5-arg overload during ordinary example validation is `checkCode` ([L1239–L1247](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L1239-L1247), reached from `checkTerminologyCoding` at [L2082](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L2082) and `checkCodedElement` at [L2445](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L2445)) — and both feeders are residual: `checkCodedElement` falls back to `checkCode` only when the binding-based check did not actually check the code (the `!checked.ok()` guard at [L2441](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L2441)), and `checkTerminologyCoding` is itself invoked only from a CDA/logical-model special case ([L2043–L2046](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L2043-L2046)). (The one other in-class caller, `validateCodeAndTextWithAI` ([L1077–L1087](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L1077-L1087)), is inert unless an AI validation service is configured — the spec build configures none.) The `checkCode` route is pre-gated by `getTxSupportInfo`, which classifies `example.org`/`acme.com` systems as unsupported up front:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L829-L831

```java
        if (system.startsWith("http://example.org") || system.startsWith("http://acme.com") || system.startsWith("http://hl7.org/fhir/valueset-")) {
          return new SystemSupportInformation(false);
        } else {
```

So within `InstanceValidator`'s own element-level checks, the `example.org` arm of the override is unreachable, and the SNOMED/LOINC/UCUM arms are reachable only via that residual `checkCode` path — never from the binding checks that produce the traffic. (The override is not literally dead code: a handful of resource-specific validators that run during instance validation call the 5-arg form directly, unguarded — e.g. `BundleValidator`'s signature checks at [L1163](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/BundleValidator.java#L1163) and `ValueSetValidator`'s filter-value checks at [L772](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ValueSetValidator.java#L772) — and so does kindling's own value-set QA ([definitions ValueSetValidator L401](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/definitions/validation/ValueSetValidator.java#L401)). But none of that is the element-level example-validation traffic the short-circuits were evidently built for — see Repro.)

The local `UcumService` ([loadUcum L421](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L421-L423), [getUcumService L645](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L645-L647)) is consulted by the FHIRPath engine, by a few quantity-comparison checks in `InstanceValidator`, and by that same hard-to-reach override — but not by the binding validations that produce the UCUM traffic.

**Consequences.** 150 UCUM and dozens of example.org validations per cold build go to the network, past a local safety net that was built for them. The answers are not wrong — they are just fetched remotely — so this is a performance/robustness defect of the spec build, not a correctness one, and it affects only kindling (`BuildWorkerContext` is kindling code).

**Works-as-intended?** The likely design answer is that the `Coding`/`CodeableConcept` overloads answer ValueSet-*membership* questions, which a per-code-system short-circuit cannot answer in general — which would explain why the override was never extended to them. But that defense indicts the override itself: if the membership-aware paths cannot use it and the system-level path that could is gated (example.org) or residual (SNOMED/LOINC/UCUM), the short-circuits no longer do the job they were added for; they only look like they do.

**Repro.** Set a breakpoint (or add logging) on the 5-arg `validateCode` overload in `BuildWorkerContext` during a spec build: in our builds it never fired for example validation — all observed traffic flowed through the `Coding`/`CodeableConcept` overloads.

**Status / recommendation.** Two clean options upstream: **(a) re-wire** — plug local SNOMED/LOINC/UCUM answering in at a layer the `Coding`/`CodeableConcept` path actually consults, e.g. fhir-core's special-code-system hook ([`ValueSetValidator.findSpecialCodeSystem`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/validation/ValueSetValidator.java#L1083)), so the build's real traffic hits it; the author's pushed chain [`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain) (fhir-core, commit d7f9f3e06, optional reference, not upstream) demonstrates this approach; or **(b) prune** — accept the network round trips and delete the bypassed arms of the override (the `example.org` arm in particular is unreachable from `InstanceValidator`'s element-level checks), keeping only what the remaining direct 5-arg callers — the resource-specific validators and kindling's own value-set QA — still exercise.

---

---

## 13. Terminology-cache seed bootstrap can never work for forks — and currently appears to serve nothing to anyone

**Setup.** fhir-core's r5 `TerminologyCacheManager` seeds the local terminology cache by downloading a pre-built cache zip from `tx.fhir.org/tx-cache/`, keyed by GitHub repository coordinates. A seeded cache avoids re-asking the terminology server for answers a previous canonical build already obtained. The only production consumer is kindling's spec build ([`PageProcessor` L10355](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/PageProcessor.java#L10355); IG Publisher does not use this class), so the blast radius is spec builds, not fhir-core consumers generally. kindling derives the coordinates for any build of a GitHub clone — from Azure PR variables in CI, else from the clone's `github.com` remote ([`Publisher.checkGit` L611-L651](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L611-L651)) — so the bootstrap also fires on local clones; locally the miss only costs the first build, because `~/.fhir/tx-cache/<org>/<repo>/<branch>` persists between runs. Ephemeral CI, which starts empty every run, is where the miss recurs.

**The bug.** Both the primary URL and the fallback URL are scoped to the *current* org/repo. The fallback only retries with `default.zip` in place of the branch name — it never falls back to the canonical upstream repository:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L66-L76
```java
    if (!version.equals(getCacheVersion())) {
      clearCache();
      fillCache("https://tx.fhir.org/tx-cache/"+ghOrg+"/"+ghRepo+"/"+ghBranch+".zip");
    }
    if (!version.equals(getCacheVersion())) {
      clearCache();
      fillCache("https://tx.fhir.org/tx-cache/"+ghOrg+"/"+ghRepo+"/default.zip");
    }
    if (!version.equals(getCacheVersion())) {
      clearCache();
    }
```

For a fork (e.g. `jmandel/fhir`), no cache zip has ever been uploaded under that org/repo, so both URLs 404 and `fillCache` just logs the failure and moves on:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L88-L93
```java
      HTTPResult res = ManagedWebAccess.get(Arrays.asList("web"), source+"?nocache=" + System.currentTimeMillis());
      res.checkThrowException();
      unzip(new ByteArrayInputStream(res.getContent()), cacheFolder);
    } catch (Exception e) {
      log.error("No - can't initialise cache from "+source+": "+e.getMessage(), e);
    }
```

And a fork can never self-heal: the upload that would create the zip runs only when the build holds the tx.fhir.org API key, i.e. on the credentialed canonical pipeline ([`Publisher` L827-L831](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L827-L831), calling [`TerminologyCacheManager.commit` L149](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/TerminologyCacheManager.java#L149)):

```java
      if (isGenerate && buildFlags.get("all")) {
        if (FhirSettings.hasApiKey("tx.fhir.org")) {
          page.commitTerminologyCache(FhirSettings.getApiKey("tx.fhir.org"));
        }
      }
```

So for fork coordinates, both download URLs 404 by construction, on every cold run, forever.

**Design intent, and why this is still a defect.** Namespacing *uploads* per-repo is sensible — they are authenticated and per-pipeline. But nothing about *downloads* requires it: cache entries are content-keyed (a foreign or stale entry is simply a miss), `initialize` itself version-gates whatever it unzips via `cache.ini` (`CACHE_VERSION` plus tx-server maj/min — that is what the `!version.equals(getCacheVersion())` re-checks above do), and the existing `default.zip` rung already shares one branch's cache across every branch of a repo. A cross-repo fallback to the canonical coordinates is the same operation with the same safety properties; its absence reads as an oversight, not a choice.

**Consequences.** A fork's CI build runs fully cold: every terminology answer the seed zip would have supplied becomes a live round trip to tx.fhir.org — slower for the contributor, heavier for the server. The size of the penalty is the build's warm-vs-cold terminology gap; it was not separately measured for this report. One caveat from live verification (2026-06-12): `https://tx.fhir.org/tx-cache/` currently serves an *empty* directory index, and the canonical zips (`HL7/fhir/master.zip`, `HL7/fhir/default.zip`) 404 exactly like the fork ones — so at this moment the bootstrap appears to deliver nothing to anyone, and forks are no worse off than the canonical pipeline. Whether that is a transient hosting state or a long-dead mechanism is for upstream to say; the fork-side exclusion is structural either way, and in the meantime every cold build pays two failed downloads and logs a full stack trace (`log.error(..., e)`, excerpt above) for an entirely expected 404.

**Repro.** Build a fork clone (e.g. `jmandel/fhir`) in CI with an empty tx-cache; the log shows `No - can't initialise cache from .../jmandel/fhir/master.zip: Not Found`, followed by the same for `default.zip`. Hosting state is checkable from anywhere: `curl -sI https://tx.fhir.org/tx-cache/HL7/fhir/default.zip` (404 as of June 2026) and `curl -s https://tx.fhir.org/tx-cache/` (empty index).

**Status / recommendation.** Report-only — no workspace branch carries a fix, and this is as much tx-cache hosting policy as code. In the spirit of "make it work or cut it": **(a)** if the seed hosting is meant to be alive, re-populate it and add one more rung to `initialize`'s fallback chain — after `<org>/<repo>/default.zip`, try the canonical repo (kindling builds exactly one spec, so a caller-supplied canonical coordinate, or even a final hard-coded `https://tx.fhir.org/tx-cache/HL7/fhir/default.zip`, suffices); **(b)** if it is dead, remove the bootstrap from the build path. Either way, the expected-404 stack trace deserves to become a one-line info message.

---

## 14. The cache-id terminology protocol is unused and unsafe: dead code that returns wrong answers if anyone turns it back on — cut it or make it safe

**Setup.** fhir-core's terminology client supports a `cache-id` protocol: instead of inlining the full ValueSet resource into every `$validate-code` request, the client sends the ValueSet once, then refers to it by `url`/`valueSetVersion` plus a shared `cache-id` on subsequent calls. Until September 2024 this engaged automatically whenever the server advertised support (the gate was just `if (txcaps != null)`), so every fhir-core consumer used it. Core commit `3d13e5ae5` (Sept 24 2024, "Allow for code to turn off use of cache-id on tx interface (for debugging)") added a static gate, `TerminologyClientContext.canUseCacheId` ([declaration L74](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientContext.java#L74), [engagement check L218](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientContext.java#L218), [setter L311-L313](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientContext.java#L311-L313)) — **defaulting to `false`, which turned the protocol off for the entire ecosystem in one commit**. No production code anywhere in fhir-core, kindling, or IG Publisher ever sets it to `true`; the only caller of the setter at all is kindling's redundant re-disable.

**The bug.** The inline-vs-by-reference switch lives in `BaseWorkerContext.addServerValidationParameters`. Once a ValueSet has been registered under the cache-id, later validations send only its url, and the server validates against its registered copy:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1927-L1935
```java
    if (vs != null) {
      if (terminologyClientContext != null && terminologyClientContext.isTxCaching() && terminologyClientContext.getCacheId() != null && vs.getUrl() != null && terminologyClientContext.getCached().contains(vs.getUrl() + "|" + vs.getVersion())) {
        pin.addParameter().setName("url").setValue(new UriType(vs.getUrl()));
        if (vs.hasVersion()) {
          pin.addParameter().setName("valueSetVersion").setValue(new StringType(vs.getVersion()));
        }
      } else if (options.getVsAsUrl()) {
        pin.addParameter().setName("url").setValue(new UriType(vs.getUrl()));
      } else {
```

When the ValueSet draws on a grammar-based "infinite" code system — e.g. `urn:ietf:bcp:13`, where any syntactically valid mimetype is a member — the by-reference path loses those special-system semantics: the registered ValueSet behaves as an enumerable set with no members, so valid codes are rejected. The defect reproduces identically on the legacy deployed tx.fhir.org and on current FHIRsmith (`tx/` module), so it lies in the interaction design or shared client behavior, not one server build.

kindling additionally hard-disables it at the very top of the build — same day as the core off-switch commit, no recorded rationale (commit 0b65fdc, Sept 24 2024, "No use cache-id on the tx server"; this bug is the probable rationale), and redundant given the false default:

https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L685-L687
```java
  public void execute(String folder, String[] args) throws IOException {
    TerminologyClientContext.setCanUseCacheId(false);
    tester = new PublisherTestSuites();
```

**Consequences.** Three distinct harms, in sequence:
1. **Until Sept 2024 this was an active wrong-results bug** for every consumer validating against grammar-based systems through a cache-id-capable server: false negatives like `The value provided ('application/pdf') was not found in the value set 'Mime Types'`, same for `image/jpeg`, `application/dicom`, valid BCP-47 codes, etc. Re-enabling it today takes a full spec build from Errors=0 to **Errors=285** (Warnings 3693→3821).
2. **The mitigation neutered a real optimization for everyone**: with the flag off (the universal state today), every request re-inlines its full ValueSet — a meaningful share of the request-serialization cost documented in bug 9 — and the protocol code is effectively dead.
3. **The defect is a latent landmine**: the protocol bug itself was never fixed (it reproduces on both the legacy deployed tx.fhir.org and current FHIRsmith, so it lies in the interaction design or shared client behavior, not one server build), the off-switch is an undocumented public static one call away from re-arming it, and neither the disable commit nor the code records *why* it is off — this report is that missing documentation.

**Repro.** In `Publisher.execute`, change the existing `TerminologyClientContext.setCanUseCacheId(false)` call to `true` — merely removing the line is not enough, since the core default is already `false` — and run any spec build (equivalently, build the author's kindling branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) with the optional `-Dfhir.build.tx.usecacheid=true` gate it adds); `binary-example` fails on `Binary.contentType` immediately. Minimal repro: register the mimetypes ValueSet via cache-id, then `$validate-code` `application/pdf` against it by reference. (VERIFICATION NEEDED: a raw-HTTP emulation of that two-request sequence against tx.fhir.org/r5 — inline `valueSet` + `cache-id`, then `url`+`valueSetVersion` with the same `cache-id` — was not retained by the server at all ("value set could not be found"), so the minimal repro may need the real client's full cache-id handshake; the build-level repro is the verified one.)

**Status / recommendation.** Report-only; no fix branch. The state to resolve is "unused and unsafe": nothing has exercised this code path since Sept 2024, and the only thing standing between the ecosystem and Errors=285 is an undocumented `false` default on a public static. Two clean exits, either of which is better than the status quo: **(a) cut it** — remove the protocol client-side and reclaim the dead code, or **(b) make it safe** — fix the by-reference semantics for grammar-based systems server-side, add a regression test that validates `application/pdf` through a cache-id round trip, and only then re-enable. Until one of those happens, at minimum the default deserves a comment saying *why* it is off. The `perf/integrated` branch mentioned above is on the author's fork, not upstream.
