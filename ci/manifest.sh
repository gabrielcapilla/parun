#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
umask 077

readonly MAX_ARTIFACT_BYTES=67108864
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
readonly NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly TOKEN_RE='^[a-z0-9][a-z0-9._-]*$'

TEMP_OUTPUT=""

function fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

function usage() {
    cat >&2 <<'USAGE'
Usage:
  manifest.sh <project> <version> <binary> <output> \
    <os|arch|variant|filename|path> [...]

The version is written without the leading release-tag "v". Each artifact
path must name the same file as its filename field.
USAGE
    exit 1
}

function byte_count() {
    local count

    count=$(wc -c <"$1") || fail "could not measure ${1}"
    count="${count//[[:space:]]/}"
    [[ "${count}" =~ ^[0-9]+$ ]] || fail "invalid byte count for ${1}"
    printf '%s\n' "${count}"
}

function sha256_file() {
    local output digest

    if command -v sha256sum >/dev/null 2>&1; then
        output=$(sha256sum -- "$1") || fail "could not hash ${1}"
    elif command -v shasum >/dev/null 2>&1; then
        output=$(shasum -a 256 "$1") || fail "could not hash ${1}"
    else
        fail "sha256sum or shasum is required"
    fi

    read -r digest _ <<<"${output}"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 output for ${1}"
    printf '%s\n' "${digest}"
}

function validate_name() {
    [[ "$1" =~ ${NAME_RE} ]] || fail "invalid $2: $1"
}

function validate_token() {
    [[ "$1" =~ ${TOKEN_RE} ]] || fail "invalid $2: $1"
}

function cleanup() {
    if [[ -n "${TEMP_OUTPUT}" && (-e "${TEMP_OUTPUT}" || -L "${TEMP_OUTPUT}") ]]; then
        rm -f -- "${TEMP_OUTPUT}" || true
    fi
}

function main() {
    local project version binary output
    local specification os arch variant filename artifact_path target_key
    local size digest output_dir
    local -a fields=()
    local -a records=()
    local -A seen_targets=()
    local -A seen_filenames=()

    (($# >= 5)) || usage

    project="$1"
    version="$2"
    binary="$3"
    output="$4"
    shift 4

    validate_name "${project}" "project name"
    [[ "${version}" =~ ${VERSION_RE} ]] || fail "invalid version: ${version}"
    validate_name "${binary}" "binary name"
    (($# > 0)) || fail "at least one artifact is required"

    for specification in "$@"; do
        fields=()
        IFS='|' read -r -a fields <<<"${specification}"
        ((${#fields[@]} == 5)) || fail "artifact specification must have five fields"

        os="${fields[0]}"
        arch="${fields[1]}"
        variant="${fields[2]}"
        filename="${fields[3]}"
        artifact_path="${fields[4]}"

        validate_token "${os}" "artifact operating system"
        validate_token "${arch}" "artifact architecture"
        validate_token "${variant}" "artifact CPU variant"
        validate_name "${filename}" "artifact filename"
        [[ "${artifact_path##*/}" == "${filename}" ]] || fail "artifact path does not end in ${filename}"
        [[ -f "${artifact_path}" ]] || fail "artifact is not a regular file: ${artifact_path}"

        target_key="${os}|${arch}|${variant}"
        [[ -z "${seen_targets[${target_key}]+present}" ]] || fail "duplicate artifact target: ${target_key}"
        [[ -z "${seen_filenames[${filename}]+present}" ]] || fail "duplicate artifact filename: ${filename}"

        size=$(byte_count "${artifact_path}")
        [[ "${size}" =~ ^[1-9][0-9]*$ ]] || fail "invalid size for ${filename}"
        ((size <= MAX_ARTIFACT_BYTES)) || fail "artifact ${filename} exceeds ${MAX_ARTIFACT_BYTES} bytes"
        digest=$(sha256_file "${artifact_path}")

        seen_targets["${target_key}"]="present"
        seen_filenames["${filename}"]="present"
        records+=("artifact|${os}|${arch}|${variant}|${filename}|${digest}|${size}")
    done

    output_dir="${output%/*}"
    [[ "${output_dir}" != "${output}" ]] || output_dir="."
    [[ -d "${output_dir}" ]] || fail "manifest output directory does not exist: ${output_dir}"

    TEMP_OUTPUT=$(mktemp "${output}.XXXXXX") || fail "could not create manifest staging file"
    trap cleanup EXIT INT TERM

    {
        printf 'format|1\n'
        printf 'project|%s\n' "${project}"
        printf 'version|%s\n' "${version}"
        printf 'binary|%s\n' "${binary}"
        printf '%s\n' "${records[@]}" | sort -t'|' -k1,1 -k2,2 -k3,3 -k4,4
    } >"${TEMP_OUTPUT}"

    mv -f -- "${TEMP_OUTPUT}" "${output}"
    TEMP_OUTPUT=""
    printf 'Generated %s\n' "${output}"
}

main "$@"
