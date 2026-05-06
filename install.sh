#!/usr/bin/env bash

set -euo pipefail

readonly REPO="gabrielcapilla/parun"
readonly BINARY_NAME="parun"
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly REQUIRED_SPACE_MB=10
readonly MAX_DOWNLOAD_TIME=300
readonly MAX_FILE_SIZE_MB=8

readonly RED=$'\033[1;31m'
readonly GREEN=$'\033[1;32m'
readonly YELLOW=$'\033[1;33m'
readonly RESET=$'\033[0m'
readonly ACTION="${YELLOW}::${RESET}"
readonly SUCCESS="${GREEN}::${RESET}"
readonly FAILURE="${RED}::${RESET}"

TEMP_FILE=""

cleanup() {
	if [[ -n "${TEMP_FILE}" && -f "${TEMP_FILE}" ]]; then
		rm -f -- "${TEMP_FILE}"
	fi
}

fail() {
	printf >&2 "%b %s\n" "${FAILURE}" "$*"
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

check_dependencies() {
	require_cmd curl
	require_cmd df
	require_cmd file
	require_cmd readelf
}

check_disk_space() {
	local available_space_mb
	available_space_mb=$(df -Pm "${HOME}" | awk 'NR == 2 { print $4 }')
	[[ "${available_space_mb}" =~ ^[0-9]+$ ]] || fail "could not read available disk space"

	if ((available_space_mb < REQUIRED_SPACE_MB)); then
		fail "insufficient disk space: need ${REQUIRED_SPACE_MB}MB, have ${available_space_mb}MB"
	fi
}

cpu_has_flag() {
	local flag="$1"
	awk -v flag="${flag}" '
    /^flags[[:space:]]*:/ {
      for (i = 3; i <= NF; i++) {
        if ($i == flag) {
          found = 1
          exit
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' /proc/cpuinfo
}

supports_x86_64_v3() {
	[[ "$(uname -m)" == "x86_64" ]] || return 1
	[[ -r /proc/cpuinfo ]] || return 1

	local flag
	for flag in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
		cpu_has_flag "${flag}" || return 1
	done

	cpu_has_flag lzcnt || cpu_has_flag abm || return 1
}

select_asset() {
	[[ "$(uname -m)" == "x86_64" ]] || fail "unsupported architecture: $(uname -m)"

	if supports_x86_64_v3; then
		printf 'parun-linux-x86_64-v3\n'
	else
		printf 'parun-linux-x86_64\n'
	fi
}

release_url_for() {
	local asset="$1"
	printf 'https://github.com/%s/releases/latest/download/%s\n' "${REPO}" "${asset}"
}

check_path() {
	if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
		printf >&2 "%b warning: %s is not in PATH\n" "${ACTION}" "${INSTALL_DIR}"
		printf >&2 "%b add this to your shell profile:\n" "${ACTION}"
		printf >&2 "  export PATH=\"%s:\$PATH\"\n" "${INSTALL_DIR}"
	fi
}

confirm_existing_installation() {
	local binary_path="${INSTALL_DIR}/${BINARY_NAME}"
	[[ -e "${binary_path}" ]] || return 0

	if [[ ! -t 0 ]]; then
		printf >&2 "%b replacing existing %s\n" "${ACTION}" "${binary_path}"
		return 0
	fi

	local response
	printf >&2 "%b %s already exists. Update it? [y/N]: " "${ACTION}" "${binary_path}"
	read -r response
	[[ "${response}" == "y" || "${response}" == "Y" ]] || exit 0
}

validate_binary() {
	local file_path="$1"

	[[ -s "${file_path}" ]] || fail "downloaded file is empty"
	file "${file_path}" | grep -q 'ELF 64-bit' || fail "downloaded file is not a 64-bit ELF binary"
	file "${file_path}" | grep -q 'executable' || fail "downloaded ELF is not executable"
	readelf -h "${file_path}" >/dev/null || fail "downloaded ELF header is invalid"
}

download_binary() {
	local asset="$1"
	local url="$2"

	TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/parun.XXXXXX")
	printf >&2 "%b downloading %s\n" "${ACTION}" "${asset}"

	curl --fail --location --silent --show-error \
		--max-time "${MAX_DOWNLOAD_TIME}" \
		--max-filesize "$((MAX_FILE_SIZE_MB * 1024 * 1024))" \
		--output "${TEMP_FILE}" \
		"${url}" || fail "download failed: ${url}"

	validate_binary "${TEMP_FILE}"
}

install_binary() {
	local binary_path="${INSTALL_DIR}/${BINARY_NAME}"

	mkdir -p -- "${INSTALL_DIR}"
	install -m 0755 "${TEMP_FILE}" "${binary_path}"
	TEMP_FILE=""

	[[ -x "${binary_path}" ]] || fail "installation verification failed"
	printf "%b installed %s\n" "${SUCCESS}" "${binary_path}"
}

main() {
	trap cleanup EXIT

	check_dependencies
	check_disk_space
	check_path
	confirm_existing_installation

	local asset
	asset=$(select_asset)

	download_binary "${asset}" "$(release_url_for "${asset}")"
	install_binary
}

main "$@"
