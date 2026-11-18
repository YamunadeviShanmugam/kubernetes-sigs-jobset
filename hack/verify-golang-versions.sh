#!/usr/bin/env bash

# Verify that the Go version is consistent across the sources that decide
# which Go compiler CI uses to build and test JobSet:
#
#   go.mod                   - the version the code is written for
#   Dockerfile.ci            - builder stage of the operator image built by Prow
#   Dockerfile.ci-build-root - build root image for the Prow unit, lint,
#                              integration and code generation checks
#   .ci-operator.yaml        - legacy from-repository build root selection,
#                              checked when present so branches that still use
#                              it stay covered
#
# Two builder image naming schemes are in use and both are supported:
#   OCP golang builders:  registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.27-openshift-5.2
#   UBI go-toolset:       registry.access.redhat.com/ubi9/go-toolset:1.27
#
# Rules (following openshift/build-machinery-go make/targets/golang/version.mk):
#   1. All CI sources must declare the same Go MAJOR.MINOR version.
#   2. go.mod may declare a lower version than CI (Go is backward compatible).
#   3. go.mod must not declare a higher version than the CI builder.
#   4. Every extracted version must be a valid MAJOR.MINOR number.

set -o errexit
set -o nounset
set -o pipefail

GOMOD="go.mod"
CI_INREPO_CONFIG=".ci-operator.yaml"
CI_DOCKERFILES=("Dockerfile.ci" "Dockerfile.ci-build-root")

reports=()

fail() {
    echo "Golang version mismatch:"
    printf '%s\n' "${reports[@]}" | sort -u | sed 's/^/  - /'
    exit 1
}

# Print the Go MAJOR.MINOR version for every image reference in the given
# lines that encodes one, one per line. Lines without a recognizable
# reference print nothing. The sed expressions are applied sequentially, but
# a line can only match one of them: OCP golang builders encode the version
# after the "golang-" image-name fragment while UBI go-toolset images encode
# it in the tag after "go-toolset:".
extract_versions() {
    sed -n \
        -e 's/.*golang-\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        -e 's/.*go-toolset:\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# Print the image-relevant lines of a Dockerfile: builder stage FROM lines
# and lines declaring the builder image, which both carry the "AS builder"
# marker in the formats used by this repository.
dockerfile_lines() {
    grep -e 'AS builder' -e '^[[:space:]]*FROM' "$1" || true
}

# Print the image tag lines of the in-repo ci-operator configuration.
inrepo_config_lines() {
    grep -e 'tag: ' "$1" || true
}

valid_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]
}

# version_le MAJOR.MINOR MAJOR.MINOR - succeed when the left version is not
# newer than the right one.
version_le() {
    local left_major left_minor right_major right_minor
    left_major="${1%%.*}"
    left_minor="${1##*.}"
    right_major="${2%%.*}"
    right_minor="${2##*.}"
    [[ "${left_major}" -lt "${right_major}" ]] || { [[ "${left_major}" -eq "${right_major}" ]] && [[ "${left_minor}" -le "${right_minor}" ]]; }
}

main() {
    local ci_versions=()
    local file version extracted

    local files=("${CI_DOCKERFILES[@]}")
    if [[ -f "${CI_INREPO_CONFIG}" ]] && grep -q '^build_root_image:' "${CI_INREPO_CONFIG}"; then
        files+=("${CI_INREPO_CONFIG}")
    fi

    for file in "${files[@]}"; do
        [[ -f "${file}" ]] || continue
        if [[ "${file}" == "${CI_INREPO_CONFIG}" ]]; then
            extracted="$(inrepo_config_lines "${file}" | extract_versions)"
        else
            extracted="$(dockerfile_lines "${file}" | extract_versions)"
        fi
        if [[ -z "${extracted}" ]]; then
            echo "Error: could not extract a golang version from ${file}" >&2
            exit 1
        fi
        while IFS= read -r version; do
            [[ -n "${version}" ]] || continue
            if ! valid_version "${version}"; then
                echo "Error: could not extract a valid golang version from ${file} (got '${version}')" >&2
                exit 1
            fi
            reports+=("${file}: ${version}")
            ci_versions+=("${version}")
        done <<<"${extracted}"
    done

    if [[ ${#ci_versions[@]} -eq 0 ]]; then
        echo "Error: no CI golang version sources found" >&2
        exit 1
    fi

    local unique_count ci_version
    unique_count="$(printf '%s\n' "${ci_versions[@]}" | sort -u | grep -c .)"
    if [[ "${unique_count}" -gt 1 ]]; then
        fail
    fi
    ci_version="$(printf '%s\n' "${ci_versions[@]}" | sort -u | head -n 1)"

    local gomod_version=""
    if [[ -f "${GOMOD}" ]]; then
        gomod_version="$(sed -n 's/^go \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "${GOMOD}" | head -n 1)"
    fi
    if [[ -n "${gomod_version}" ]]; then
        if ! valid_version "${gomod_version}"; then
            echo "Error: could not extract a valid golang version from ${GOMOD} (got '${gomod_version}')" >&2
            exit 1
        fi
        reports+=("${GOMOD}: ${gomod_version}")
        if ! version_le "${gomod_version}" "${ci_version}"; then
            fail
        fi
    fi

    echo "Go versions are consistent (CI: ${ci_version}, go.mod: ${gomod_version:-none})"
}

main "$@"
