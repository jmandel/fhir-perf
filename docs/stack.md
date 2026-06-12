# FHIR Stack Wiring

## Repositories

This workspace keeps local upstream clones under `repos/`:

| Path | Upstream | Role |
| --- | --- | --- |
| `repos/fhir-core` | `https://github.com/hapifhir/org.hl7.fhir.core.git` | Core Java model, utility, conversion, and validation artifacts. |
| `repos/kindling` | `https://github.com/HL7/kindling.git` | Publisher used to build the core FHIR specification. |
| `repos/ig-publisher` | `https://github.com/HL7/fhir-ig-publisher.git` | Standalone IG Publisher CLI. |
| `~/work/fhir` | existing local checkout | FHIR specification source tree. |

## Dependency Direction

Current upstream build files show this dependency graph:

```text
ca.uhn.hapi.fhir:org.hl7.fhir.*  (repos/fhir-core)
  -> org.hl7.fhir:kindling       (repos/kindling)
       -> ~/work/fhir Gradle publish task

ca.uhn.hapi.fhir:org.hl7.fhir.*  (repos/fhir-core)
  -> org.hl7.fhir.publisher:*    (repos/ig-publisher)
```

The IG Publisher path is direct; it does not depend on Kindling.

## Version Properties

- `repos/fhir-core/pom.xml`: project version, currently a `6.x.y-SNAPSHOT`.
- `repos/kindling/pom.xml`: `fhirCoreVersion` controls which core artifacts Kindling compiles against.
- `repos/ig-publisher/pom.xml`: `core_version` controls which core artifacts Publisher compiles against.
- `~/work/fhir/gradle.properties`: `kindlingVersion` controls which Kindling artifact the spec build uses.

The gym scripts read the local project versions. Downstream builds use their
declared dependency versions by default, because upstream repos can lag each
other. Add `--local-core` or `--core-version VERSION` when the goal is to
intentionally test an in-flight core change against a downstream project.

## Local Maven Repo

All Maven builds run through the `fhir-core` Maven wrapper because this machine does not have `mvn` on `PATH`.

The wrapper is always invoked with:

```text
-Dmaven.repo.local=/home/jmandel/hobby/fhir-perf/m2/repository
```

That keeps experimental artifacts out of global `~/.m2/repository`.

## Gradle Hook for the Spec Checkout

`~/work/fhir` already declares:

```kotlin
repositories {
    mavenLocal()
    mavenCentral()
    ...
}

dependencies {
    implementation("org.hl7.fhir:kindling:${property("kindlingVersion")}")
}
```

The gym runs the spec Gradle wrapper with:

```text
--init-script /home/jmandel/hobby/fhir-perf/gradle/local-maven.init.gradle
-DfhirPerf.mavenLocal=/home/jmandel/hobby/fhir-perf/m2/repository
-PkindlingVersion=<local kindling version>
--refresh-dependencies
```

The init script rewires Gradle's `MavenLocal` repository to the gym-local Maven
repo. When `--local-core` or `--core-version VERSION` is passed, the script also
forces `ca.uhn.hapi.fhir:org.hl7.fhir.*` transitive dependencies to that core
version. Without that flag, the spec build follows Kindling's published POM
metadata.

## Common Workflows

Build and test a core change in IG Publisher:

```bash
gym build-core
gym build-publisher --local-core
gym publisher-run -help
```

Build Kindling and the spec according to their declared dependency versions:

```bash
gym build-kindling
gym spec-deps
gym spec-publish -- -nogen
```

Build and test a core change in Kindling and the spec, when Kindling is
expected to compile against the local core checkout:

```bash
gym build-core
gym build-kindling --local-core
gym spec-deps --local-core
gym spec-publish --local-core -- -nogen
```

Persistently align local clone POMs after changing `repos/fhir-core/pom.xml` version:

```bash
gym align-poms
```

Inspect what has actually been installed locally:

```bash
gym local-artifacts
```

Inspect the active branches and versions:

```bash
gym status
```

## When a Change Is Visible

A Java source change in `repos/fhir-core` becomes visible to downstream projects after:

```bash
gym build-core
```

If the relevant core change is on another local git ref, use:

```bash
gym build-core-ref origin/2026-06-gg-rendering
```

That creates a detached worktree under `tmp/worktrees/` and installs the ref's
Maven artifacts into the same gym-local Maven repo. It does not move the main
`repos/fhir-core` checkout.

A Java source change in `repos/kindling` becomes visible to `~/work/fhir` after:

```bash
gym build-kindling
```

A Java source change in `repos/ig-publisher` becomes visible in the executable Publisher jar after:

```bash
gym build-publisher
```

For snapshot dependency checks, use `gym spec-deps` or Maven dependency tree commands through:

```bash
gym mvn -f repos/ig-publisher/pom.xml -Dcore_version="$(bin/gym status | sed -n 's/^fhir-core version:[[:space:]]*//p')" dependency:tree
```

Prefer the explicit build commands for routine work; they carry the right version and local-repo flags.

## Current Upstream Mismatch Observed

At setup time, `repos/ig-publisher` `master` declares `core_version`
`6.9.10-SNAPSHOT` but fails against `repos/fhir-core` `master` because
`PublisherIGLoader` calls `Utilities.makeNameFromCode(String)`. That method is
present on core ref `origin/2026-06-gg-rendering`. Use `gym build-core-ref
origin/2026-06-gg-rendering` before `gym build-publisher` to test that
branch-specific stack.

Also at setup time, `repos/kindling` `main` declares `fhirCoreVersion`
`6.9.1-SNAPSHOT`. `gym build-kindling` succeeds with that declared dependency.
`gym build-kindling --local-core` fails against current core `6.9.10-SNAPSHOT`
until Kindling is updated for the newer core APIs.
