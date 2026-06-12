# Upstream Bugs Found During FHIR Build Performance Work (June 2026)

All found while profiling/parallelizing the core FHIR spec build (kindling + org.hl7.fhir.core). Every code location below is a permalink into stock upstream code, pinned to the commits the claims were verified against: fhir-core [`master` @ 5c4d5a0ff](https://github.com/hapifhir/org.hl7.fhir.core/tree/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7) and kindling [`main` @ b6cb1f6](https://github.com/HL7/kindling/tree/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8) (June 2026). Code excerpts are verbatim from those commits. Where a measurement was originally taken on the earlier 6.9.1-SNAPSHOT line, that is noted. "Fixed in" refers to the author's workspace branches; the ones pushed for reference live on the [jmandel/org.hl7.fhir.core](https://github.com/jmandel/org.hl7.fhir.core) and [jmandel/kindling](https://github.com/jmandel/kindling) forks.

---

## 1. The cache-id terminology protocol is broken for grammar-based code systems — and was "fixed" by silently disabling it for every consumer

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
2. **The mitigation neutered a real optimization for everyone**: with the flag off (the universal state today), every request re-inlines its full ValueSet — a meaningful share of the request-serialization cost documented in bug 8 — and the protocol code is effectively dead.
3. **The defect is a latent landmine**: the protocol bug itself was never fixed (it reproduces on both the legacy deployed tx.fhir.org and current FHIRsmith, so it lies in the interaction design or shared client behavior, not one server build), the off-switch is an undocumented public static one call away from re-arming it, and neither the disable commit nor the code records *why* it is off — this report is that missing documentation.

**Repro.** Remove the `setCanUseCacheId(false)` line in `Publisher.execute` (or use the `-Dfhir.build.tx.usecacheid=true` gate on the author's workspace branch `spike/s9-tx-cold`) and run any spec build; `binary-example` fails on `Binary.contentType` immediately. Minimal repro: register the mimetypes ValueSet via cache-id, then `$validate-code` `application/pdf` against it by reference. (VERIFICATION NEEDED: a raw-HTTP emulation of that two-request sequence against tx.fhir.org/r5 — inline `valueSet` + `cache-id`, then `url`+`valueSetVersion` with the same `cache-id` — was not retained by the server at all ("value set could not be found"), so the minimal repro may need the real client's full cache-id handshake; the build-level repro is the verified one.)

**Status.** Report-only; no fix branch — the protocol defect needs an upstream design decision (fix the by-reference semantics for grammar-based systems, or document and remove the dead protocol). The kindling flag remains off, and the global default remains `false`. The `spike/s9-tx-cold` branch mentioned above is one of the author's local workspace branches, not upstream.

---

## 2. Unknown-system answers are never remembered: `validateCode(Coding)` returns early past both the per-run memo and the cache

**Setup.** `BaseWorkerContext.validateCode(Coding)` (the five-arg overload at [BaseWorkerContext.java#L1429](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1429)) tries local validation first, then asks the terminology server, and is supposed to remember negative answers in two layers: a per-run memo of unsupported code systems (`updateUnsupportedCodeSystems`) and the persistent terminology cache (`txCache.cacheValidation`). Spec example resources routinely use fictional code systems (`http://example.org/fhir/foo-types`, `http://acme.com/...`), so "this system is unknown" is one of the most-repeated answers in a build.

**The bug.** When local evaluation of an unknown system records a warning (a `VSCheckerException` of type `CODESYSTEM_UNSUPPORTED` becomes `localWarning`, [L1470-L1475](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1470-L1475)) and the server then also answers `CODESYSTEM_UNSUPPORTED` with the code's system in `unknownSystems`, the "go with the local warning" branch rebuilds a WARNING `ValidationResult` and **returns early** — skipping both the per-run memo (line 1563) and the cache write (lines 1564-1566):

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

The answer is recorded at no layer, so the next `validateCode` for the same system is a fresh server round trip — within the run, and again on every subsequent build. A second, minor bug sits in the same lines: the `setDiagnostics` call composes `"Local Warning: " + localWarning + ". Server Error: " + res.getMessage()` — but `res` was just reassigned on the previous line, so the "Server Error:" text is the local warning repeated and the server's actual message is discarded. (The comment also says "local error" where it means the local warning.)

A related asymmetry worth fixing at the same time: `processValidationResult` ([L2105](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L2105)) treats the two unknown-system response spellings differently — `x-caused-by-unknown-system` sets the error class to `CODESYSTEM_UNSUPPORTED`, while `x-unknown-system` only populates `unknownSystems` and never sets the error class — so a server using the latter spelling can never arm the memo by any path:

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

**Consequences.** Every coding from an unknown/fictional system round-trips to the server on every occurrence. We counted **22 separate POSTs for one fictional system** in one build. Narrative generation makes this unbounded: `DataRenderer.lookupCode` ([DataRenderer.java#L313-L323](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/renderers/DataRenderer.java#L313-L323)) calls `validateCode(options, system, version, code, null)` → `validateCode(Coding, vs=null)` ([BaseWorkerContext.java#L1181-L1185](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1181-L1185)) with useClient and useServer both on, so every rendered example mentioning the system pays a round trip, every build, forever. Compounding: the CodeableConcept validation path ([L1723-L1816](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1723-L1816)) neither consults nor updates the memo at all, and versioned codings are excluded from memoization (`!code.hasVersion()` in `updateUnsupportedCodeSystems`, [L1702-L1706](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1702-L1706)).

**Repro.** With a context configured with a terminology server and a tx cache, call `validateCode(new ValidationOptions(), new Coding().setSystem("http://example.org/fhir/foo-types").setCode("xyz"), null)` twice (useClient/useServer at their defaults, vs = null): the tx log shows two identical `$validate-code` round trips and nothing is written to the tx cache. Equivalently, validate any resource containing a coding from a made-up system twice, or grep a cold build's server log for `example.org` request counts.

**Status.** No upstream fix; a client-side workaround (local synthesis of unknown-system answers, byte-identical to 11/11 captured server responses) lives on the author's workspace branch `spike/core-localfirst` (gated by `-Dorg.hl7.fhir.tx.localFirst`). Suggested fix direction upstream: arm the memo and cache the rebuilt warning result before returning, and compose the diagnostics string from the server result's message rather than the rebuilt one's.

---

## 3. Registry "no server claims this system" still falls back to asking the primary server

**Setup:** fhir-core routes terminology requests through `TerminologyClientManager`, which asks the tx ecosystem registry (`resolve?...&url=<system>`) which server is authoritative for each code system, then picks a server in `chooseServer(ValueSet, Set<String>, boolean)`. The registry can answer with authoritative servers, candidate servers, or — for unknown/fictional systems — neither.

**The bug:** A clean registry negative (the resolve call succeeds but returns no `authoritative` and no `candidates` entries) is encoded as an empty `ServerOptionList`, indistinguishable in effect from "no information":

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

(The `vs != null` branch at [L300-L307](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L300-L307) does the same.) The resolve-*error* path falls back to the primary the same way, returning `new ServerOptionList(url, getMasterClient().getAddress())` at [L461-L468](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L461-L468) — so "registry definitively says nobody serves this system" and "registry unreachable" produce identical behavior.

**Consequences:** A clean negative answer from the tx ecosystem registry (no authoritative server, no candidates) produces a positive network action — a `$validate-code` POST to the primary server, which then also fails. Negative routing knowledge is discarded. Combined with bug #2 (unknown-system answers never memoized or cached), every validation of a coding from an unknown system pays both the registry resolve and the doomed primary-server POST.

**Repro:** Same as #2 — validate codings from a fictional system (e.g. `http://example.org/fhir/foo-types`); in the tx log, observe the registry resolve GET followed anyway by a primary-server `$validate-code` POST.

**Status:** Addressed as part of the author's workspace branch `spike/core-localfirst`. Worth an upstream design note regardless.

---

## 4. Terminology stack is not thread-safe; failures silently disable terminology and corrupt results

**Setup.** During a spec build, validation threads share one `BaseWorkerContext`, which owns the terminology disk cache (`TerminologyCache`) and the multi-server client routing layer (`TerminologyClientManager`). Most of `TerminologyCache` synchronizes on a shared lock object, but several mutating paths do not, and the shared client-routing maps have no synchronization at all — so running validation across a thread pool exercises live data races.

**The bug.** Three layers, in increasing severity:

1. *Unsynchronized cache maps.* `csCache`/`vsCache` are plain `HashMap`s, mutated and then fully iterated (to rewrite `cs-externals.json`/`vs-externals.json`) with no lock — `cacheValueSet`/`cacheCodeSystem` at [TerminologyCache.java#L1304-L1376](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L1304-L1376). A live `ConcurrentModificationException` was observed at `TerminologyCache.cacheCodeSystem:1170` under 12-thread validation (line number from the 6.9.1 line; the method starts at line 1341 in master). Master's June 2026 txcache rework (df9504f6e) added a TODO acknowledging exactly these unsynchronized paths — `getServerId`, `cacheValueSet`/`cacheCodeSystem`, `getReport` — but the races remain:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L346-L348
```java
  private Map<String, NamedCache> caches = new HashMap<String, NamedCache>();
  private Map<String, SourcedValueSetEntry> vsCache = new HashMap<>();
  private Map<String, SourcedCodeSystemEntry> csCache = new HashMap<>();
```
(TODO comment: [TerminologyCache.java#L87-L97](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L87-L97).)

2. *Unsynchronized client routing.* `TerminologyClientManager`'s `serverMap`/`resMap` are plain `HashMap`s ([declarations, L142-L144](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L142-L144)) mutated by concurrent `chooseServer` → `findClient`/`findServerForSystem` ([L385-L415](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/client/TerminologyClientManager.java#L385-L415)).

3. *The killer: any exception silently kills terminology for the rest of the build.* `BaseWorkerContext.getTxSupportInfo` ([L817-L862](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L817-L862)) wraps the server-support probe in `catch (Exception)` and, whenever `canRunWithoutTerminology` is set, flips `noTerminologyServer=true` and keeps going:

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

kindling sets `canRunWithoutTerminology` for all non-web builds ([Publisher.java#L2482](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/Publisher.java#L2482)), so any race-induced exception from layers 1-2 is swallowed here. A console banner is printed, but the build continues with terminology permanently disabled: every subsequent batch validation returns NOSERVICE, and `ConceptMapValidator` renders NOSERVICE results as hard `CONCEPTMAP_VS_INVALID_CONCEPT_CODE` errors ([ConceptMapValidator.java#L206-L215](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ConceptMapValidator.java#L206-L215) — only `CODESYSTEM_UNSUPPORTED`/`_VERSION` are downgraded to warnings; NOSERVICE falls through to the error branch).

**Consequences.** One swallowed race silently corrupts build output rather than failing it: a single observed occurrence produced **217-220 bogus validation errors** of the form "The code 'X' in the system http://snomed.info/sct is not valid in the value set 'null'". The corruption is timing-dependent — some runs clean, some corrupted, same inputs — which makes it look like flaky terminology data rather than a thread-safety bug.

**Repro.** Run example validation across a thread pool sharing one `BaseWorkerContext` with a cold terminology cache. The author's kindling workspace branch `spike/s3-parallel-validation` run against unfixed core reproduces within a few runs.

**Status.** Fixed in the author's workspace PR branch [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (fhir-core fork, commit a4030ee0a): synchronization, copy-on-write server list, narrowed catch, and a NOSERVICE downgrade in `ConceptMapValidator`.

---

## 5. `BaseWorkerContext` and `TerminologyCache` share one lock; whole cache-page file rewrites happen under it

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

`store` ([L696-L728](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L696-L728)) calls `save(nc, now)` ([L820](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L820-L829)), which rewrites the **entire** named cache page file — every entry, each embedding its serialized ValueSet — still inside the shared monitor. For SNOMED that is ~110KB per entry, and ~4.9GB of cumulative writes over one cold build. Meanwhile every other context operation (resource fetches, code-system lookups) is queued behind the same lock waiting for that file I/O.

**Consequences.** JFR-measured during 12-thread validation: 593 seconds of monitor-blocking inside a 67-second wall-clock window — **74% of all validator thread-time** queued behind this one lock, mostly threads in `fetchResourceWithExceptionByVersion` waiting for cache file I/O.

**Repro.** Record JFR with `jdk.JavaMonitorEnter` enabled on any multi-threaded validation workload; the blocked time concentrates on the `BaseWorkerContext` lock.

**Status.** Fixed in the author's workspace branch [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (lock split; the cache becomes a self-synchronized leaf). Upstream master had independently improved persistence — saves are now coalesced into 5s windows (`SAVE_DELAY_MS = 5000`, [L185](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L185)) — but the lock is still shared.

---

## 6. Transient server errors are cached permanently in the terminology disk cache

**Setup.** fhir-core memoizes terminology-server answers in a disk cache (`~/.fhir/tx-cache/...`) so warm builds can skip `$validate-code` round trips. Cache entries are written by `BaseWorkerContext.validateCode` with a lifetime flag; `TerminologyCache.store` is the single choke point that decides whether an entry is persisted.

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

**Consequences.** A build that runs during a transient server flake poisons `~/.fhir/tx-cache/...`: subsequent **warm** builds replay the cached error as a validation failure forever, until someone manually deletes the cache files. We reproduced a build that passes cold and then fails warm *from its own priming run's cached errors*, and found 10 poisoned `.cache` files after one flaky afternoon.

**Repro.** Run any build that overlaps a server hiccup, then:
```
grep -l "Error performing tx5\|Error from http" ~/.fhir/tx-cache/*/*/*/*.cache
```
Rerun the build warm and watch it exit rc=1 on the replayed errors.

**Fix direction.** Never persist results whose message indicates a transport/5xx/404 failure (or persist them with a transient TTL).

**Status.** Report-only — no fix branch. The author's workspace builds purge poisoned entries manually, and the workspace harness (`runs/bench.sh`) includes a poison-check.

---

## 7. `validateCodeBatch` returns degraded results vs singular validation

**Setup.** `BaseWorkerContext` has two paths for asking a terminology server to validate a coding: the singular path ([`validateOnServer2` → `addServerValidationParameters`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1893-L1980)), which carefully assembles the request, and the batch path ([`validateCodeBatch`](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1205-L1293)), which packs many codings into one `$batch` request. The two are supposed to be equivalent; they are not.

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

The full list of gaps, batch relative to singular:

1. No dependent resources — referenced ValueSets, COMPLETE/FRAGMENT CodeSystems, and supplements attached as `tx-resource` by `addDependentResources` ([L1946](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1946)).
2. No `cache-id` bookkeeping ([L1953](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1953)).
3. No `valueSetVersion` ([L1930-L1932](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1930-L1932)) — batch sends only `url` ([L1261](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1261), excerpt above).
4. Wrong expansion-parameter merge semantics — singular translates `defaultDisplayLanguage` and respects override order ([L1962-L1974](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1962-L1974)); batch dumps the raw expansion parameters into each sub-request (`constructParameters`, [L1698](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1698)).
5. No `mode=lenient-display-validation` ([L1976-L1978](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1976-L1978)).
6. No `diagnostics=true` ([L1979](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1979)).
7. Response handling passes `null` instead of the VS url to `processValidationResult` ([L1284](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1284), excerpt above) and never updates the unsupported-systems memo (`updateUnsupportedCodeSystems`, [L1702-L1706](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1702-L1706)).

**Consequences.** Identical codes validated via the batch path yield fewer/weaker messages than the singular path — a full spec build validated via batch prefill lost **~650 warnings** (3693→3037), silently. This affects every current consumer of `validateCodeBatch`: [`ConceptMapValidator` L204](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ConceptMapValidator.java#L204), the validator's [`ValueSetValidator` L520](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/type/ValueSetValidator.java#L520), and [`CodingsObserver` IPS checks L105](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/codesystem/CodingsObserver.java#L105).

**Repro.** Validate the same coded elements through both paths and diff the resulting messages; or see the reconciliation commit `fe25b5e3d` on the author's workspace branch `spike/core-batch-tx`, which enumerates and fixes all seven gaps.

**Status.** A fix exists on the author's workspace branch `spike/core-batch-tx` (commit `fe25b5e3d`); it is not in the main PR branches, and the two-pass feature that motivated it is parked. The gap matters to every current consumer of `validateCodeBatch` regardless (call sites linked above).

---

## 8. Hot-path allocation/CPU bugs: per-character varargs in `isWhitespace`; cache keys pretty-print full ValueSets per call

**Setup:** Two utility paths in fhir-core sit directly under every JSON serialization and every terminology validation call: `Utilities.escapeJson` is invoked for each string written by the JSON composers, and `TerminologyCache.generateValidationToken` builds the cache key for each `validateCode` call. Both run millions of times in a spec build, so per-call waste here dominates the allocation and CPU profiles.

**The bug:** Three independent hot-path defects, all in fhir-core:

1. `Utilities.isWhitespace` checks membership in a 25-element list via `existsInList(int, int...)`, which boxes the candidates into a fresh 25-element varargs `int[]` on **every call** — and `escapeJson` ([Utilities.java#L1004-L1030](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/Utilities.java#L1004-L1030)) calls it once **per character** of every escaped string.

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/Utilities.java#L1773-L1777
```java
  public static boolean isWhitespace(int ch) {
    return Utilities.existsInList(ch, '\\u0009', '\\n', '\\u000B','\\u000C','\\r','\\u0020','\\u0085','\\u00A0',
        '\\u1680','\\u2000','\\u2001','\\u2002','\\u2003','\\u2004','\\u2005','\\u2006','\\u2007','\\u2008','\\u2009','\\u200A',
        '\\u2028', '\\u2029', '\\u202F', '\\u205F', '\\u3000');
  }
```

2. The `TerminologyCache.generateValidationToken` overloads ([TerminologyCache.java#L491-L580](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L491-L580)) pretty-print-serialize the expansion `Parameters` — and, via `extracted(...)`/`getVSEssense(...)`, the ValueSet "essence" — to JSON on **every** `validateCode` call:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/terminologies/utilities/TerminologyCache.java#L501-L503
```java
      JsonParser json = new JsonParser();
      json.setOutputStyle(OutputStyle.PRETTY);
      String expJS = expParameters == null ? "" : json.composeString(expParameters);
```

This cost is paid even on cache hits, because the token is generated before the cache is consulted ([BaseWorkerContext.java#L1437-L1441](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L1437-L1441)).

3. `JsonParserBase.compose` wraps its output stream in an **unbuffered** `OutputStreamWriter` ([JsonParserBase.java#L204](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/formats/JsonParserBase.java#L204) and [#L258](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/formats/JsonParserBase.java#L258)), so every token round-trips through the charset encoder individually.

**Consequences:** In a profiled spec build, JFR attributed **104GB** of `int[]` allocation to the `isWhitespace` varargs path alone — roughly half of a **3.1GB/s** allocation storm. About **73%** of validation-phase CPU was JSON serialization for cache keys (item 2). The unbuffered writer (item 3) accounted for **34GB** of `HeapCharBuffer` allocation. None of this work produces different results; it is pure overhead on the hottest paths of the build.

**Repro:** Record JFR with `jdk.ObjectAllocationSample` and `jdk.ExecutionSample` enabled on any validation-heavy workload (e.g. a spec build); the three sites above dominate the allocation and CPU profiles.

**Status:** Fixed in the author's workspace branch [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (switch-based `isWhitespace`, memoized cache keys, buffered writers).

---

## 9. kindling forces a full GC after every validated example

**Setup.** During the core spec build, kindling validates every example resource in the specification via `ExampleInspector.doValidate(...)`, called once per example file. The build runs with a large heap (14GB in the measured configuration), so any full collection has to walk a large live set.

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

**Consequences.** JFR shows **934 explicit-GC events per build** (`jdk.SystemGC`), totaling **272s of stop-the-world pause — 40% of the entire stock build** (683s total, 14GB heap). Each forced full collection walks the whole live heap, once per example file.

**Repro.** Run JFR on a stock build and count `jdk.SystemGC` events; or simply run the build with `-XX:+DisableExplicitGC`: 683s → 379s with zero code change.

**Status.** Fixed in the author's workspace branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) (commit 1).

---

## 10. Terminology cache keyed to the alphabetically-first local git branch, not the checked-out branch

**Setup.** When kindling builds the spec from a local GitHub clone (i.e., outside CI), `Publisher.checkGit` inspects the repository to derive an org/repo/branch triple. That triple selects the persistent terminology cache directory (`~/.fhir/tx-cache/{org}/{repo}/{branch}`) and the URL of the CI cache-bootstrap zip downloaded from tx.fhir.org.

**The bug.** `checkGit` never asks which branch is checked out. It iterates `git.branchList().call()` — JGit returns local branch refs in alphabetical order — and returns out of the loop on the **first ref**, so `ghBranch` (and `ciDir`, copied from it) is the alphabetically-first local branch name:

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

**Consequences.** Observed live: building `master` while the cache read/wrote `.../integrate-FHIR-11050-empty-2/`. Caches are silently shared and mixed across branches; creating a new local branch that sorts first makes every build cold; and the CI bootstrap zip URL is wrong (it names a branch that may not exist on tx.fhir.org).

**Repro.** In a checkout that has any local branch sorting alphabetically before the checked-out one, run a build and read the `Load Terminology Cache from ...` log line ([PageProcessor L10356](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/PageProcessor.java#L10356)) — the path ends in the wrong branch name.

**Status.** Fixed in the author's workspace branch [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) (kindling fork), commit 5: uses `getFullBranch()` for the checked-out branch, with a fallback for detached HEAD.

---

## 11. kindling's local terminology short-circuits are bypassed by the validation paths that need them

**Setup.** kindling's `BuildWorkerContext` extends fhir-core's `BaseWorkerContext` and adds local short-circuits for terminology the spec build hits constantly: it overrides the 5-arg `validateCode(options, system, version, code, display)` to answer SNOMED, LOINC, UCUM, and `http://example.org` codes locally (UCUM via a local `UcumEssenceService`), so those lookups never need to reach tx.fhir.org.

**The bug.** The override covers only one overload — and the validator paths that generate the traffic never call it.

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

But the binding-driven checks that dominate example validation go through the `Coding`/`CodeableConcept` overloads of `InstanceValidator.checkCodeOnServer` ([InstanceValidator.java L8972–L9022](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L8972-L9022)), which call the `Coding`/`CodeableConcept` forms of `context.validateCode` — overloads kindling does not override, so they go straight to `BaseWorkerContext` and the network.

The only validator route into the 5-arg overload is `InstanceValidator.checkCode` ([L1239–L1247](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L1239-L1247), reached from `checkTerminologyCoding` at [L2082](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L2082) and `checkCodedElement` at [L2445](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.validation/src/main/java/org/hl7/fhir/validation/instance/InstanceValidator.java#L2445)). That route is pre-gated by `getTxSupportInfo`, which classifies `example.org`/`acme.com` systems as unsupported up front:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/context/BaseWorkerContext.java#L829-L831

```java
        if (system.startsWith("http://example.org") || system.startsWith("http://acme.com") || system.startsWith("http://hl7.org/fhir/valueset-")) {
          return new SystemSupportInformation(false);
        } else {
```

So for exactly the systems the override special-cases, it is unreachable from validation. The local `UcumService` ([loadUcum L421](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L421-L423), [getUcumService L645](https://github.com/HL7/kindling/blob/b6cb1f66e49ac8ef4ace2932ad5345cb3e5624d8/src/main/java/org/hl7/fhir/tools/publisher/BuildWorkerContext.java#L645-L647)) is consulted only by the FHIRPath engine and by that same hard-to-reach override — not by the binding validations that produce the UCUM traffic.

**Consequences.** 150 UCUM and dozens of example.org validations per cold build go to the network, past a local safety net that was built for them.

**Repro.** Set a breakpoint (or add logging) on the 5-arg `validateCode` overload in `BuildWorkerContext` during a spec build: in our builds it never fired for example validation — all observed traffic flowed through the `Coding`/`CodeableConcept` overloads.

**Status.** Superseded by the author's workspace branch `spike/core-localfirst` (fhir-core), which plugs in properly at the `ValueSetValidator.findSpecialCodeSystem` level. Either way, the effectively-dead override is worth removing or re-wiring upstream.

---

## 12. The spec build is not deterministic (same inputs → different published bytes)

**Setup:** A spec build (kindling driving fhir-core generators) should be a pure function of its inputs: building the same commit twice should publish byte-identical output (after normalizing timestamps). It doesn't — several independent sources of nondeterminism are baked into stock upstream code.

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

2. **Random UUIDs in published bytes (fhir-core).** The hierarchical table generator embeds a fresh per-process UUID into every generated table script (`// 6fbd5028-...`); random UUIDs also appear in image filenames:

https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xhtml/HierarchicalTableGenerator.java#L126-L128
```java
  private static final String BACKGROUND_ALT_COLOR = "#F7F7F7";
  public static boolean ACTIVE_TABLES = false;
  public static String uuid = UUIDUtilities.makeUuidLC();
```

The UUID is written into output at [HierarchicalTableGenerator.java#L922-L923](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xhtml/HierarchicalTableGenerator.java#L922-L923) (`String js= "  // "+uuid+"\n";`). Notably, a `forTesting()` hook already pins it to a constant ([#L1500-L1502](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.utilities/src/main/java/org/hl7/fhir/utilities/xhtml/HierarchicalTableGenerator.java#L1500-L1502)) — an existing acknowledgment that the randomness breaks output comparison.

3. **ShEx generation varies between identical runs (fhir-core).** Whole `EXTENDS @<BackboneElement>` blocks appear/disappear between runs (~78 `.shex` files plus their `.html` renderings differ per run). Likely unordered-set iteration in the ShEx generator — at this SHA the generation logic lives in `ShExGeneratorBase` (r5), which tracks its working state in hash-backed collections (declarations at [ShExGeneratorBase.java#L281-L294](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/conformance/ShExGeneratorBase.java#L281-L294), e.g. `HashSet<String> uniq_structure_urls`); the `EXTENDS @<...>` text is emitted at [#L640-L649](https://github.com/hapifhir/org.hl7.fhir.core/blob/5c4d5a0ff3b66f26f1365bc8a3e32ad5c561a6f7/org.hl7.fhir.r5/src/main/java/org/hl7/fhir/r5/conformance/ShExGeneratorBase.java#L640-L649). TTL/JSON-LD output shows the same class of run-to-run variance.

4. **Build reads its own prior output.** The first build in a fresh checkout differs from converged builds (e.g. `structuredefinition-category` extensions appear only from run 2 onward) — the build reads state produced by prior builds.

**Consequences:** Two consecutive builds of the same commit publish different bytes: ~226 files differ even after timestamps are normalized. This defeats output caching, undermines signing/attestation of published artifacts, generates spurious diffs for anyone comparing published output across builds, and means a fresh-checkout build is not even self-consistent with a converged one.

**Repro:** Run two consecutive `-nopartial` builds of the same commit; diff the publish directories with timestamps normalized → ~226 files differ. Manifest tooling in this workspace automates the comparison (`runs/manifest.py`, `runs/noise-files-v2.txt` — author's workspace, not upstream).

**Status:** Report-only; no fix branch. Matters for caching, signing, and anyone diffing published output.

---

## 13. XML comments grow one space per compose/reparse cycle

**Setup:** fhir-core's element-model XML pipeline round-trips resources through compose (`org.hl7.fhir.utilities.xml.XMLWriter`) and parse (`org.hl7.fhir.r5.elementmodel.XmlParser`). Comments attached to elements (`Element.getComments()`) are supposed to survive these round trips unchanged; downstream composers (e.g. Turtle) re-emit them verbatim.

**The bug:** The writer pads the comment text with one space *inside* each delimiter, and the parser reaps the raw DOM text content — padding included — so the two halves of the round trip are asymmetric.

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

**Consequences:** Every compose→parse round trip grows every comment by one leading and one trailing space. This is visible in published TTL (`#   <priority value="5" />` vs `#  <priority ...>`) because the Turtle composer emits comments verbatim — example outputs ended up depending on how many XML round trips the pipeline happened to take.

**Repro:** Parse a resource containing an XML comment, compose it, re-parse, and compare the `Element.getComments()` strings — they differ by two spaces per cycle.

**Status:** Report-only. In the author's workspace, the build's round-trip count was made deterministic instead, which hides the symptom locally; the asymmetry itself remains upstream.

---

## 14. CI terminology-cache bootstrap 404s for forks

**Setup.** When a build runs in CI (GitHub org/repo/branch known), fhir-core's r5 `TerminologyCacheManager` tries to seed the local terminology cache by downloading a pre-built cache zip from `tx.fhir.org/tx-cache/`, keyed by the repository coordinates. A seeded cache avoids re-asking the terminology server for answers the canonical build already has.

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

**Consequences.** A fork's "cold" CI build is fully cold — every terminology answer is a fresh round trip to the tx server — while the canonical repo's cold build starts from a seeded cache. Contributors testing spec changes on forks see materially slower (and harder-on-tx.fhir.org) builds than the canonical pipeline for the same commit.

**Repro.** Build a fork clone (e.g. `jmandel/fhir`) in CI with an empty tx-cache; the log shows `No - can't initialise cache from .../jmandel/fhir/master.zip: Not Found`, followed by the same for `default.zip`.

**Fix direction.** Extend the fallback chain: fork → canonical upstream repo (e.g. `HL7/fhir`) → default.

**Status.** Report-only — this is as much tx-cache hosting infrastructure/policy as code; no workspace branch carries a fix.
