#!/usr/bin/env bash

# Source this file when you want short interactive commands:
#   source ./env.sh
#   gym status

export FHIR_PERF_HOME="${FHIR_PERF_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export FHIR_SPEC="${FHIR_SPEC:-$HOME/work/fhir}"
export FHIR_PERF_M2_REPO="${FHIR_PERF_M2_REPO:-$FHIR_PERF_HOME/m2/repository}"
export FHIR_PERF_GRADLE_USER_HOME="${FHIR_PERF_GRADLE_USER_HOME:-$FHIR_PERF_HOME/.gradle}"
export PATH="$FHIR_PERF_HOME/bin:$PATH"

