#!/usr/bin/env bash

# Strict mode for error handling
set -o errexit -o nounset -o pipefail

# Colors RGB & End
declare -r R="\033[1;31m"
declare -r G="\033[1;32m"
declare -r Y="\033[1;33m"
declare -r E="\033[0m"

# Color codes
declare -r A="${Y}::${E}" # Action
declare -r S="${G}::${E}" # Success
declare -r F="${R}::${E}" # Error/Fail

# Paths & Config
declare -r REPO="gabrielcapilla/parun"
declare -r BINARY_NAME="parun"
declare -r INSTALL_DIR="${HOME}/.local/bin"
declare -r API_URL="https://api.github.com/repos/${REPO}/releases/latest"
declare -r REQUIRED_SPACE_MB=10
declare -r MAX_DOWNLOAD_TIME=300
declare -r MAX_FILE_SIZE_MB=5

# Global state
declare -g TEMP_FILE=""

# Log error message and exit with a non-zero status
function log_error() {
	cleanup
	printf >&2 "${F} %s\n" "$*"
	exit 1
}

# Cleanup temporary files on exit
function cleanup() {
	if [[ -n "${TEMP_FILE}" && -f "${TEMP_FILE}" ]]; then
		rm -f -- "${TEMP_FILE}"
	fi
}

# Check if required dependencies are installed
function check_dependencies() {
	command -v curl &>/dev/null || log_error "curl is not installed"
	command -v file &>/dev/null || log_error "file is not installed"
	command -v sha256sum &>/dev/null || log_error "sha256sum is not installed"
}

# Check available disk space
function check_disk_space() {
	local available_space_mb
	available_space_mb=$(df -m "${HOME}" | awk 'NR==2 {print $4}')

	if [[ "${available_space_mb}" -lt "${REQUIRED_SPACE_MB}" ]]; then
		log_error "Insufficient disk space. Required: ${REQUIRED_SPACE_MB}MB, Available: ${available_space_mb}MB"
	fi
}

# Verify INSTALL_DIR is in PATH
function check_path() {
	if [[ ! ":${PATH}:" == *":${INSTALL_DIR}:"* ]]; then
		printf >&2 "%b Warning: %s is not in your PATH\n" "${Y}" "${INSTALL_DIR}"
		printf >&2 "%b Add the following to your shell profile:\n" "${Y}"
		printf >&2 "%b   export PATH=\"%s:\$PATH\"\n" "${Y}" "${INSTALL_DIR}"
	fi
}

# Check if binary is already installed and ask for update confirmation
function check_existing_installation() {
	local binary_path="${INSTALL_DIR}/${BINARY_NAME}"

	if [[ -f "${binary_path}" ]]; then
		printf >&2 "%b %s is already installed at %s\n" "${A}" "${BINARY_NAME}" "${binary_path}"
		printf >&2 "%b Do you want to update it? [y/N]: " "${A}"

		local response
		read -r response </dev/tty

		if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
			printf >&2 "%b Installation cancelled\n" "${S}"
			exit 0
		fi
	fi
}

# Get download URL from GitHub API
function get_download_url() {
	local download_url
	download_url=$(curl -s --fail "${API_URL}" | grep "browser_download_url.*${BINARY_NAME}" | cut -d '"' -f 4)

	[[ -n "${download_url}" ]] || log_error "Could not find download URL for ${BINARY_NAME}"

	echo "${download_url}"
}

# Validate that downloaded file is a valid ELF executable
function validate_elf() {
	local file="$1"

	if ! file "${file}" | grep -q "ELF 64-bit LSB.*executable"; then
		log_error "Invalid ELF file: downloaded file is not a valid 64-bit executable"
	fi
}

# Download binary to temporary file
function download_binary() {
	local url="$1"

	printf >&2 "%b Downloading %s...\n" "${A}" "${BINARY_NAME}"

	TEMP_FILE=$(mktemp)

	curl -sL --fail \
		--max-time "${MAX_DOWNLOAD_TIME}" \
		--max-filesize "$((MAX_FILE_SIZE_MB * 1024 * 1024))" \
		"${url}" \
		-o "${TEMP_FILE}" || log_error "Download failed"

	[[ -f "${TEMP_FILE}" ]] || log_error "Download failed: file not created"

	validate_elf "${TEMP_FILE}"
}

# Install binary to target directory
function install_binary() {
	local binary_path="${INSTALL_DIR}/${BINARY_NAME}"

	printf >&2 "%b Installing %s to %s...\n" "${A}" "${BINARY_NAME}" "${INSTALL_DIR}"

	mkdir -p -- "${INSTALL_DIR}"
	mv -- "${TEMP_FILE}" "${binary_path}"
	chmod +x -- "${binary_path}"

	TEMP_FILE="" # Clear temp file reference after successful move
}

# Verify installation
function verify_installation() {
	local binary_path="${INSTALL_DIR}/${BINARY_NAME}"

	if [[ ! -x "${binary_path}" ]]; then
		printf >&2 "%s Installation verification failed\n" "${F}"
		log_error "Could not verify installation"
	fi

	printf "%b Successfully installed %s to %s/\n" "${S}" "${BINARY_NAME}" "${INSTALL_DIR}"
}

# Main function orchestrating the script flow
function main() {
	trap cleanup EXIT

	check_dependencies
	check_disk_space
	check_path
	check_existing_installation

	local download_url
	download_url=$(get_download_url)

	download_binary "${download_url}"
	install_binary
	verify_installation
}

# Execute the main function
main "$@"
