# FHIR Perf Gym

Local workspace for testing FHIR Java stack changes across the upstream dependency chain.

## Layout

- `repos/fhir-core`: `hapifhir/org.hl7.fhir.core`, Maven artifacts under `ca.uhn.hapi.fhir`.
- `repos/kindling`: `HL7/kindling`, the FHIR specification publisher used by `~/work/fhir`.
- `repos/ig-publisher`: `HL7/fhir-ig-publisher`, the standalone IG Publisher.
- `~/work/fhir`: existing local checkout of the FHIR specification. This gym references it; it is not recloned here.
- `m2/repository`: isolated Maven local repository for this gym.
- `.gradle`: isolated Gradle user home for spec-build dependency resolution.

## Quick Start

```bash
source ./env.sh
gym status
gym doctor
gym build-core
gym build-kindling
gym build-publisher
gym local-artifacts
```

By default, build commands install artifacts with tests skipped. Add `--with-tests` to run each repo's tests:

```bash
gym build-core --with-tests
```

When a downstream repo needs a core branch that is not checked out in
`repos/fhir-core`, build that ref through a temporary git worktree:

```bash
gym build-core-ref origin/2026-06-gg-rendering
```

This installs that ref's `6.x-SNAPSHOT` artifacts into `./m2/repository`
without moving the main core checkout.

## Dependency Chain

The current stack has two top-level consumers:

```text
fhir-core -> ig-publisher
fhir-core -> kindling -> ~/work/fhir
```

IG Publisher does not currently depend on Kindling. It consumes core artifacts directly using the root `core_version` property in `repos/ig-publisher/pom.xml`.

The FHIR spec checkout depends on `org.hl7.fhir:kindling` via `~/work/fhir/build.gradle.kts`. That build already uses `mavenLocal()`, and this gym adds a Gradle init hook so `mavenLocal()` points at `./m2/repository` rather than your global `~/.m2/repository`.

## Local Build Flow

Build all local artifacts in dependency order:

```bash
gym build-all
```

Or build one layer at a time:

```bash
gym build-core
gym build-kindling
gym build-publisher
```

By default, `gym build-kindling` and `gym build-publisher` honor the core
versions declared in each repository's POM. This matters because the upstream
repos do not always advance in lockstep. For example, Kindling may declare an
older `fhirCoreVersion` than current `repos/fhir-core`.

To intentionally test a local core API change against a downstream repo, add:

```bash
gym build-kindling --local-core
gym build-publisher --local-core
```

That passes `-DfhirCoreVersion=<local core version>` for Kindling or
`-Dcore_version=<local core version>` for IG Publisher.

For a persistent local checkout alignment, run:

```bash
gym align-poms
```

That updates `repos/kindling/pom.xml` and `repos/ig-publisher/pom.xml` so their checked-in core dependency properties match the local `fhir-core` version.

## Demonstrating Local Changes

To show Gradle resolving the spec build through the local Maven repo:

```bash
gym build-core
gym build-kindling
gym spec-deps
```

If the spec build should force transitive core artifacts to the current local
core version, use:

```bash
gym spec-deps --local-core
```

To run the spec publisher through `~/work/fhir` with local Kindling and
Kindling's declared transitive core version:

```bash
gym spec-publish -- -nogen
```

Add `--local-core` only after `gym build-kindling --local-core` succeeds for the
core changes you are testing.

To build and run the local IG Publisher jar:

```bash
gym build-core
gym build-publisher
gym publisher-run -help
```

If Publisher has moved ahead of core `master`, first install the matching core
ref, then rebuild Publisher:

```bash
gym build-core-ref origin/2026-06-gg-rendering
gym build-publisher
```

The local publisher jar path is:

```bash
gym publisher-jar
```

## More Detail

See [docs/stack.md](docs/stack.md) for the version wiring, Maven/Gradle hook details, and common workflows.
