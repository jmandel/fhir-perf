# txpack: Immutable Terminology Answer Packs for the FHIR Core Build

**Proposal.** Replace the spec build's mutable per-machine terminology cache and its zip publish pipeline with **txpacks**: immutable, content-addressed snapshots of recorded terminology-server answers, pinned by a ~1KB `tx.lock` file in the repo. The design is implemented and measured: a fully cold build with a pack matches a warm build (195s vs 197s, byte-identical output), and a hermetic build — full cold build, **zero network requests** — completes in 231s with the exact reference output signature (rc=0, Errors=0 / Warnings=3693 / Info=345). Working branches: fhir-core [`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain), kindling [`perf/terminology-fold`](https://github.com/jmandel/kindling/tree/perf/terminology-fold).

All measurements: full `-nopartial` core build, 12-core/62GB machine, on top of separately-proposed build optimizations (parallel validation, lock fixes — under which the stock 683s warm build runs at ~197s). Detailed run logs are in the companion `perf-findings.md`.

---

## 1. The current system

The spec build asks a terminology server roughly 1,900–2,700 unique questions per fully-cold build: `validate-code` (membership and display checks), `$expand` (page rendering), resource lookups (`CodeSystem?url=`), and registry resolutions. Five mechanisms mediate this:

1. **In-memory request cache (per run).** `TerminologyCache` (fhir-core, org.hl7.fhir.r5) memoizes request→response pairs within a run, keyed by a hash of the canonicalized request. Sound; this proposal keeps it unchanged.
2. **Mutable on-disk cache (per machine, per branch).** The same class persists entries under `~/.fhir/tx-cache/{ghOrg}/{ghRepo}/{ghBranch}/` as text "page" files, read at start and written during/after every run. Branch detected by `Publisher.checkGit`.
3. **Zip publish/bootstrap pipeline.** At the start of every build, for every user, `TerminologyCacheManager.initialize()` fetches `https://tx.fhir.org/tx-cache/{org}/{repo}/{branch}.zip` (fallback `default.zip`) whenever the local version stamp mismatches. At the end of every successful full build, *if* `fhir-settings.json` holds a tx.fhir.org API key (in practice HL7's CI and the tx maintainer), `Publisher.execute` zips the entire cache dir and HTTP-PUTs it **to the same URL, overwriting in place**. Nothing schedules, gates, hashes, or reviews this; nothing goes to git.
4. **Committed answer files.** `tools/tx/snomed/snomed.xml` (81KB, ~625 concepts) and `loinc.xml` (15KB) are committed to the repo: code→display answers loaded at start, consulted before the network, refreshed on miss, written back at build end as a reviewable diff. A 20-year-old proto-answer-pack, limited to display/existence lookups.
5. **Direct-to-server bypasses.** `BuildWorkerContext.lookupLoinc` and bootstrap metadata fetches call the HTTP client directly, skipping the cache entirely.

### 1.1 Failure modes of the current system

Each of the following is a reproduced, evidenced property of the system as shipped — not a hypothetical.

| # | Property | Evidence |
|---|---|---|
| F1 | **Transient server errors are cached permanently.** One flaky server window writes error bodies into `.cache` files; every subsequent warm build replays them as build failures. Controlled repro: identical code and inputs, rc=0 cold, then rc=1 warm from the priming run's own cached errors. The only fix is tribal knowledge (`grep -l "Error performing tx5"` and purge, or `rm -rf ~/.fhir/tx-cache`). | 10 poisoned `.cache` files reproduced and purged |
| F2 | **The cache is keyed to the wrong branch.** `checkGit` takes the *alphabetically first* local branch, not the checked-out one — a machine building `master` reads and writes `…/integrate-FHIR-11050-empty-2/`. Caches silently cross branches; a new branch that sorts first re-colds every machine; the upload publishes under the wrong name. | build logs: "Load Terminology Cache from …" |
| F3 | **Publication is ungated.** Any keyed build that exits 0 uploads — including one that ran through a server flake, distributing F1's poison to every consumer. No hash, no diff, no review, no provenance; one URL overwritten in place. | code: `TerminologyCacheManager.commit` |
| F4 | **Forks are always cold.** `{fork-org}/{repo}/{branch}.zip` 404s. | observed live: `jmandel/fhir/master.zip: Not Found` |
| F5 | **Version bumps re-cold the world.** A `CACHE_VERSION` change invalidates every machine simultaneously, against a server that sheds load above ~4 concurrent requests per IP (nginx 404s) and whose latency varies ±40% by hour (identical config: 415s at 5pm, 585s at 8pm). | bench + throttle experiments |
| F6 | **Negative answers are not first-class.** "Server doesn't know system X" is deliberately never persisted; resource-lookup negatives only partially. Result: 22 requests per run for one fictional system, and 56 LOINC probes that have 404'd on every build ever run. A compounding bug: the in-memory negative memo never arms, because the client checks `x-caused-by-unknown-system` while the server sends `x-unknown-system`. | request census; code read |
| F7 | **Silent drift.** Server-side changes (curation, fixes, edition defaults) mutate build output with no visibility: the same commit produced 3690 vs 3693 warnings depending on which server answered, and nothing records why. Build output is a function of un-pinned, un-audited server state. | local-vs-remote parity runs |
| F8 | **Failed builds don't persist their fetches**, so the dominant dev loop (fail → fix → rerun) re-pays the entire network bill. | repeated cold-cost measurement on failing runs |

### 1.2 Cost context

| Scenario | Wallclock |
|---|---|
| Warm cache, local tx server | 197s (the floor) |
| Warm cache, remote tx.fhir.org | 212s (rc=1 — F1 poison) |
| Cold, remote tx.fhir.org | 415s, ±40% by hour, ~2,000 requests at ≤4 concurrency |
| Cold, local tx server | 240s (the cost is the network, not the work) |

### 1.3 What the current design gets right

The proposal deliberately builds on the existing system rather than replacing its good parts. The request/response page format is sound and is reused verbatim. The committed answer files prove the community accepts derived terminology data in the repo with reviewable diffs. The zip pipeline proves centralized seeding works operationally — the credentials, hosting, and post-build publish moment all exist. The in-memory cache is correct. The failures above are all *lifecycle* failures: mutation in place, no provenance, no gate, no integrity, negatives excluded.

---

## 2. Design goals

1. **Poison is structurally impossible** — there must be no representation for a transient error in the persistent artifact (eliminates F1, F3).
2. **Build output is a pinned, auditable function of its inputs** — the repo names exactly which terminology answers a commit builds against, and server-state drift becomes a reviewable diff (eliminates F7).
3. **Cold = warm** — a fresh clone, a fork, a new branch, and CI all build at warm speed with near-zero server load (eliminates F2, F4, F5, F8).
4. **Negatives are first-class** — "the server doesn't know X" is an answer like any other (eliminates F6).
5. **Provable completeness** — there is a mode in which the build demonstrably needs no network at all.
6. **Reversible adoption** — every transition step degrades gracefully to today's behavior and can be rolled back independently.

---

## 3. The txpack design

### 3.1 The artifact

A **txpack** is an immutable, content-addressed snapshot of recorded server answers. It contains:

- validate-code and `$expand` answers in the existing page-file format;
- ValueSet/CodeSystem resource resolutions, **with negatives as first-class entries**;
- the tx-registry system map and server capability statements;
- a `manifest.json` recording: source server and software version, **effective terminology edition versions extracted from the responses themselves**, generation time, per-system entry counts, and the content sha256 that names the pack.

Transport and transient errors are **structurally unrepresentable**: the packager refuses to encode them (a two-tier predicate — transport markers rejected unconditionally; HTTP-wrapper markers admitted only for an allowlist of deterministic server refusals such as "too costly to expand" and grammar-based systems, which are real answers and are kept). Size for the full core build: **51MB raw, 2.3MB zipped**.

### 3.2 Consumption

- The repo carries a ~1KB **`tx.lock`**: pack hash, fetch URL, edition pins. Packs live in a shared content-addressed store (`~/.fhir/tx-packs/<sha>/`, sibling to `~/.fhir/packages`): write-once, integrity-verified on load, self-healing (corrupt → delete → refetch), safe to share across projects precisely because no entry is ever mutated.
- At build start the resolved pack loads as a **read-only seed layer consulted before everything else** — ahead of any mutable cache. **Misses fall through to the network silently**: a stale or absent pack degrades to today's behavior, never to an error.
- `-Dorg.hl7.fhir.tx.hermetic=true` (opt-in, for CI and maintainers) makes any network attempt a hard failure naming the exact request. This is the enforcement and diagnostic dial — it is how every completeness gap in the implementation was found and closed — not the default experience.

### 3.3 Production: recording runs

1. A **recording build** runs from an **ephemeral scratch directory** (born empty, deleted afterwards — no interaction with any per-machine cache). `-Dorg.hl7.fhir.tx.recordSemanticErrors=true` makes deterministic negative answers persistable. **Shadow recording** makes the run exhaustive: at each point where a repeat probe would normally be suppressed by the in-memory memo, the probe is also sent to the server and captured, while the caller still receives the memo answer — so the recording run's own output is identical to a normal run. (Shadow recording captured 284 probe shapes that thread-timing variance otherwise hides.) Serial validation is recommended for recording runs — their job is completeness, not speed.
2. **Gate**: the run must exit rc=0 *and* its published output must be byte-identical to the reference. Nothing un-gated becomes a pack.
3. The packager emits `txpack-<sha>`. Packs are **merge-able**: a pack-seeded recording run captures only residual new shapes, and `packager merge` folds them in (top-up rather than full re-record).

---

## 4. Measured results

All runs: full cold build (empty caches), exact output parity meaning byte-identical published output, Errors=0 / Warnings=3693 / Info=345.

| Run | Wallclock | Output | Server requests |
|---|---|---|---|
| Cold, no pack, local tx | 220s | exact | ~1,930 |
| Cold **with pack**, local tx | **195s** | **exact** | ~152 |
| Cold **with pack**, remote tx.fhir.org | **214s** | **exact** | ~152 |
| Cold, no pack, remote tx.fhir.org | 415s ±40% | exact when server healthy | ~2,000 |
| **Hermetic: cold with pack, network disabled** | **231s** | **exact, rc=0** | **0** |

- **A cold build with a pack is indistinguishable from a warm build** (195s vs 197s), byte-identical, regardless of server weather or time of day.
- **The hermetic build is proven end-to-end**: a full cold build with zero network requests, rc=0, exact output signature.[^1] Closing the gap from ~152 residual requests to zero required folding kindling's direct-to-server bypasses (mechanism 5 above) into the cached path, and fixing one fhir-core gap worth noting independently: the "go with the local warning" early return in `validateCode(Coding)` (`BaseWorkerContext` ~:1689) returns a locally-determined WARNING result **without ever caching it or arming the memo**, so stock builds re-ask the server for the same narrative-path shape on every example, forever. Caching that answer is a standalone upstream win whether or not txpack lands.
- Per-run server load drops from ~2,000 requests to ~0 (pack misses only — for a typical PR, the handful of genuinely new codes it introduces).

---

## 5. Operations

### 5.1 The main-branch refresh job (replaces the zip pipeline)

The refresh job uses the **same credentials and the same post-build moment** as today's zip upload, but every step leaves an artifact:

1. Recording build (§3.3) against the canonical server; gate on rc=0 + byte parity.
2. Package; **if the resulting hash equals the current lock's, stop silently**. This is the common case — and a daily, free proof that the server answered identically.
3. On change: upload once to an immutable hash-keyed URL, then open an automated PR bumping `tx.lock` whose body renders the answer diff ("14 changed: 12 SNOMED displays, 2 expansions; 31 added"). **This PR is the drift-visibility channel that does not exist today (F7).** Merge policy is a dial: auto-merge additions-only, human review for changed answers.

Automation is equal-or-greater than today; the difference is the gate verdict, the hash, and the diff.

### 5.2 Branches and forks

Packs are keyed by request content, not by repo or branch — every branch and every fork inherits the master pack instantly (strictly better than per-branch cache dirs, and F2/F4 cannot occur). Branch-introduced questions miss through to the network gracefully (~1–5s per run for typical PRs). Terminology-heavy branches can build a **personal top-up pack** in one command (recording run + `packager merge`); CI-built per-PR packs are a clean later bolt-on if demand appears. On merge to master, the refresh job folds the deltas into the canonical pack.

### 5.3 Transition — each phase independently reversible

- **Phase 0**: pack consulted first as a seed layer; everything else unchanged. Pure opt-in; misses behave exactly as today.
- **Phase 1**: default runs stop writing the on-disk cache (in-memory + pack only). F1, F2, and F8 become impossible.
- **Phase 2**: retire the zip pipeline and the branch-keyed cache dirs; recording runs write only to ephemeral scratch.

**End state**: the mutable per-machine `~/.fhir/tx-cache` ceases to exist. Packs live in the content-addressed store; the repo's `tx.lock` says which one; recording runs use ephemeral scratch.

---

## 6. A day in the life: today vs txpack

### Grahame fixes a terminology server bug
**Today:** the fix is live instantly for *cold* builders and invisible to *warm* ones — each machine picks it up whenever its cache happens to invalidate (new branch, version bump, never). Two editors build the same commit and get different warnings; nobody can say why. The lever for updating the world is a `CACHE_VERSION` bump: every machine re-colds, and ~2,000 requests × every builder land on his server.
**With txpack:** he pings the refresh job (or waits for the nightly). One recording run hits his server; the lock PR renders exactly what the fix changed in the build ("12 SNOMED display warnings resolved"); everyone's next pull ships the fixed answers pre-warmed. Server load for propagating the fix: one build's worth, total. *The honest difference: freshness arrives with `git pull` rather than ambiently — but "ambient" today means unbounded, invisible, per-machine staleness. txpack replaces inconsistent staleness with versioned freshness.*

### A spec editor's normal PR (new example, three new SNOMED codes)
**Today:** the first build after branching goes cold-ish (new branch = new cache dir; the bootstrap zip may or may not exist) — coffee break; later builds warm *on that machine only*. The CI build re-pays everything.
**With txpack:** the branch inherits the master pack instantly. The three genuinely-new codes miss through to the server (~1s); everything else is answered locally. CI behaves identically to the laptop. On merge, the refresh folds the three answers into the canonical pack.

### A first-time contributor clones a fork
**Today:** the bootstrap zip 404s (fork URLs aren't published), so their first build is fully cold against a server that throttles them — 7 minutes becomes 20+, varying by time of day. Nobody told them; they assume the build is just slow.
**With txpack:** `tx.lock` resolves the same content-addressed pack as everyone else (forks are irrelevant — packs aren't keyed by repo). Their first build is everyone's build. On an airplane, with hermetic mode, it still works.

### The 3am "build fails only on my machine"
**Today:** a transient server flake last Tuesday wrote an error into the cache; every warm build since fails one validation. The fix is tribal knowledge (`rm -rf ~/.fhir/tx-cache`), and nothing explains why it worked.
**With txpack:** this failure class is unrepresentable — packs are built only from gate-clean runs and the packager refuses transport errors structurally. There is no mutable per-machine state to rot.

### HL7's CI on master
**Today:** every keyed successful build silently overwrites the public branch zip in place — including builds that ran through server flakes. The upload is invisible; consumers can't tell which build produced their seed, or what changed.
**With txpack:** the same credential and the same post-build moment, but the artifact is hash-named and immutable, publication is a reviewable lock-bump PR with a rendered answer diff, and an un-gated build *cannot* publish. Most days the hash doesn't change and nothing happens — which is itself a daily verification that the server is answering consistently.

### An IG author (the analogous future — out of scope here)
**Today:** IG Publisher has its own warm/cold terminology behavior with the same mutable-cache character, multiplied across a much larger population of authors and CI systems.
**With txpack (someday):** the pack format and seed layer live in fhir-core, which IG Publisher already consumes — an `ig.lock`-style pack per IG is the same mechanism pointed at a different corpus. Nothing in the design is spec-build-specific; that ecosystem simply hasn't been measured.

---

## 7. Open questions

- **The values argument.** Terminology requests don't pin editions, so an answer is f(request, *server state*) — and one can argue the build *should* float with the server. The pack pins server state explicitly in its manifest and surfaces evolution as reviewable diffs; we think that is more respectful of server evolution than today's silent drift, but it is a design-values question for this discussion, not a settled fact.
- **Scope of measurement.** All numbers are from the fhir-core 6.9.1 line, one machine, the core spec build. The master-port branches compile and pass test suites but have not been wallclock-measured. IG Publisher is out of scope.
- **Pack growth over time**, multi-server packs, and whether recording should also run against a CI-hosted server instance (fully reproducible derivation, zero production-server traffic) are designed but unbuilt.
- **A pre-existing 1-in-N parallel search-param race** occasionally fails recording runs; serial-validation recording sidesteps it, but the underlying race deserves its own fix.

---

[^1]: Hermetic evidence artifact: pack `txpack-36913cc2…`, fhir-core [`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain), kindling [`perf/terminology-fold`](https://github.com/jmandel/kindling/tree/perf/terminology-fold). Output judged clean against the reference except `all-valuesets.zip`, a known zip nondeterminism that differs even between two stock runs.

*Companion documents: `perf-findings.md` (full measurement log), `upstream-bugs.md` (14 bugs with repros), `cold-start-moonshots.md` (design alternatives considered).*
