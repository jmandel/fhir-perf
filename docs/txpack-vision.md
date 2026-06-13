# The txpack vision: pinned terminology for the FHIR spec build

*The settled design, after building and CI-validating a working prototype
([jmandel/fhir @ txpack-future](https://github.com/jmandel/fhir/tree/txpack-future)). This
supersedes earlier drafts' bump/verification framing; the companion
[txpack-proposal.md](txpack-proposal.md) carries the full failure-mode analysis of the current
system.*

## North star

The spec build's terminology answers become **an ordinary pinned dependency**: named in the
repo, immutable, fetched by hash, updated by exactly one writer through reviewable commits.
Builds are fast and identical everywhere — laptop, CI, airplane — because the answers come
with the checkout, not from a server's mood.

## The moving parts

| Part | What it is | Who touches it |
|---|---|---|
| **Answer pack** | Immutable, content-addressed zip of recorded server answers (validations incl. negatives, expansions incl. deterministic refusals, capabilities, registry map). Poison (transport errors) structurally unrepresentable. ~2.3MB for the whole spec. | Created only by the recorder; stored in a release/artifact store; never in git |
| **`fhir.lock`** | The content lock, an npm package-lock v3 *profile* (packages map of name → {version, resolved, integrity}; no vendor folder — entries resolve into the shared verify-on-use store). The txpack is the first entry; ordinary FHIR packages can join with the same mechanism. Carries expectedOutput (it changes in the same commit as the pack). | **Single writer: the refresh bot.** Editors never touch it — no merge conflicts, ever |
| **Seed layer** | The build consults the pack before anything else; **misses fall through to the network gracefully**. A stale pack degrades to today's behavior, never to an error. | Inside the toolchain (fhir-core), property-driven |
| **Recorder / refresh bot** | Scheduled job: full live build with recording on (shadow recording makes it exhaustive), gated on rc=0 + output parity vs its own previous run. Packages; if the canonical hash is unchanged — stop silently (a free daily drift check). On change: upload the new pack, open a lock-bump PR. | Automation; the only producer of packs and lock changes |
| **Hermetic mode** | Opt-in switch making any terminology network attempt a loud failure naming the request. The completeness proof and diagnostic instrument — not the everyday mode. | Refresh/verification jobs; anyone proving "airplane build" |
| **Output manifest / judge** | Normalized fingerprints of published output; compares builds while excusing the stock toolchain's *documented* nondeterminism with per-file evidence (order-insensitive second-chance hashing; same-run double-build evidence). | Verification tooling; never required for an ordinary build |

All behavior lives in the shared Java toolchain (fhir-core + kindling), property-gated and
default-off; the same seam serves IG Publisher later. **Dependency footprint of every flow:
a JDK** — a committed 4KB launcher jar (gradle-wrapper pattern) bootstraps the pinned tooling
(`kindling-wrapper.properties`: url + sha256, human-written), which reads `fhir.lock` natively;
verification tools are Java CLIs in the same jar. Trust layering in one line: registries FIND
bytes, the lock TRUSTS bytes (verified on every use), the content-addressed store KEEPS bytes.
Distribution rides existing rails: packs as npm-format FHIR packages (precedent: the
expansions package), tooling on Maven — with integrity always from the lock, never assumed
from the registry or cache.

## The user experiences

**An editor, any OS.** Clone, build. Cold build ≈ warm build (~3.5 min where stock cold was
~18+), no terminology server required, no terminology ceremony of any kind. Add an example
with three new codes: the build answers everything else from the pack and asks the server just
those three questions. The PR contains *only the content change* — nothing to conflict with
anyone else's long-lived branch. Optionally, `impact` mode answers "what did my edit change in
the published output?" — a list of four files, not a 226-file noise dump; a capability the
stock build cannot offer at any price because its output is not reproducible.

**A content-PR reviewer.** Sees content. CI's check reports "this PR introduces 4 new
terminology questions" as a signal, not a gate. No lockfile churn in the diff.

**CI, every push.** ONE pack-seeded build (~4 min), signature check, misses counted and
reported. That is the entire everyday cost. (Strict hermetic is not the per-push gate — it
would fail any PR adding a code during the window before the next refresh; it is the property
of *main after a refresh*, verified there.)

**The refresh bot, nightly.** Records against the canonical server; gate: rc=0 + parity with
its own previous output. Most nights the canonical pack hash is unchanged → silence (and that
silence is a free, daily proof the server answers consistently). On change → upload + a
lock-bump PR whose body is layered: the canonical answer diff (machine-rendered, authoritative),
the published-output impact (which falls out of the recording run's own before/after — **no
extra builds**), and an AI-written explanation section (plain inference, no tools, no
authority — merge policy keys off the machine facts only: auto-merge additions-only, human
review for changed answers).

**A lock-bump reviewer.** Reads "14 answers changed: 12 SNOMED displays, 2 expansions; 12
published pages change, listed; here's the narrative." Ten-second decision with evidence,
instead of an invisible cache mutation nobody ever saw. The prototype validated the protective
outcomes live: a no-op candidate ends silently; a harmful candidate (answers removed) was
blocked twice by CI before any PR existed.

**Trust model in one line.** Verification happens **once, at recording time** (the recording
*is* a fully-gated live build); the pack replays those bytes deterministically forever; bumps
are ordinary single-writer commits that *inherit* that trust rather than re-earning it. The
optional reproducibility track (committed reference manifest, double-build evidence judging)
is a stretch goal that hardens "same commit → same bytes anywhere" — pursuing it in the
prototype surfaced seven environment-leak classes in the stock toolchain (locale, checkout
path, username, fonts, filesystem enumeration order, thread-timing ordering, designation-table
flicker) — but nothing in the txpack core depends on it.

## What this displaces

The mutable per-machine `~/.fhir/tx-cache`, the branch-keyed cache dirs, the un-gated
overwrite-in-place zip pipeline, and the committed `snomed.xml`/`loinc.xml` proto-answer-files
— each replaced by a strictly better-behaved part above, using the same credentials and the
same post-build moment the existing pipeline already owns.
