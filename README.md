# fhir-perf

Performance and correctness work on the core FHIR specification build
(HL7 [kindling](https://github.com/HL7/kindling) publisher +
[org.hl7.fhir.core](https://github.com/hapifhir/org.hl7.fhir.core) libraries).

## Results (June 2026, full `-nopartial` core build, 12-core/62GB, Java 17)

- **Warm build: 683s stock → ~197s** (forced-GC removal, parallel validation, hot-path fixes).
- **Cold build: 1117s stock → 195s** with an immutable terminology answer pack — cold ≡ warm.
- **Hermetic ("airplane") build proven**: full cold build, **zero network requests**, 231s,
  byte-identical output to the reference (Errors=0 / Warnings=3693 / Info=345).
- 15 upstream bugs found, verified against stock code, documented with repros.

### Documents

| Doc | What |
|---|---|
| [docs/txpack-vision.md](docs/txpack-vision.md) | **The settled vision**: moving parts, user experiences, single-writer trust model |
| [docs/txpack-proposal.md](docs/txpack-proposal.md) | Design proposal: immutable, content-addressed terminology answer packs (`tx.lock`) replacing the mutable per-machine cache and the un-gated zip publish pipeline |
| [docs/upstream-bugs.md](docs/upstream-bugs.md) | Consolidated bug report — 15 bugs, each with verified cause location and repro |
| [docs/upstream-plan.md](docs/upstream-plan.md) | PR sequencing plan: what goes upstream, in what order, stacked vs parallel, with branch links |
| [docs/perf-findings.md](docs/perf-findings.md) | Full measurement log and root-cause analysis |
| [docs/cold-start-moonshots.md](docs/cold-start-moonshots.md) | Idea inventory for cold-start work (incl. negative results) |

### Code

All code lives as plain branches on forks (nothing is PR'd upstream yet — see the plan doc):

All branches went through a per-commit adversarial review round; all 24 confirmed major
findings are fixed and re-verified (see the plan doc's verification table).

- fhir-core: [`perf/tx-thread-safety`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/tx-thread-safety) (master-based, suites green),
  [`perf/narrative-lookup-cache`](https://github.com/jmandel/org.hl7.fhir.core/tree/perf/narrative-lookup-cache) (master-based),
  [`txpack/chain`](https://github.com/jmandel/org.hl7.fhir.core/tree/txpack/chain) (the measured txpack chain, 6.9.1 line; default-off everywhere)
- kindling: [`perf/integrated`](https://github.com/jmandel/kindling/tree/perf/integrated) (main-based, parity-verified),
  [`perf/overlap-validation`](https://github.com/jmandel/kindling/tree/perf/overlap-validation) (opt-in),
  [`perf/terminology-fold`](https://github.com/jmandel/kindling/tree/perf/terminology-fold) (compiles against released core),
  [`perf/integration-eval`](https://github.com/jmandel/kindling/tree/perf/integration-eval) (composed PR set: hermetic full build, 211s, zero network, exact output)

### Measurement harness (runs/)

`run-spec.sh` (instrumented build runner), `cold-run.sh` (tx-cache stash/restore),
`manifest.py` (normalized output hashing), `judge.sh` + `noise-files-v2.txt` (parity judge with
known-nondeterminism allowlist). Committed evidence pair: `runs/ref.manifest` (reference build)
vs `runs/hermetic-v4.manifest` (zero-network build). Large artifacts (run logs, caches, packs,
the gym m2, clones/worktrees) are not committed; everything is reproducible from the branches +
harness.

### Workspace tooling

This repo is also a local build "gym" for the fhir-core → kindling → spec dependency chain
(isolated Maven repo, version alignment, spec-build wiring): see [docs/gym.md](docs/gym.md).
