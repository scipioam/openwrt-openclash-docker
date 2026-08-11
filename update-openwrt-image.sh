#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
DOWNLOAD_DIR="${PROJECT_DIR}/downloads"
BUILD_DIR="${PROJECT_DIR}/build"
DOCKERFILE="${PROJECT_DIR}/Dockerfile"

OPENWRT_RELEASES_URL="https://downloads.openwrt.org/releases"
OPENCLASH_REPO="vernesong/OpenClash"

BASE_REPOSITORY="local-openwrt-base"
FINAL_REPOSITORY="local-openwrt"

CURL_RETRIES=3
FORCE_BUILD=0
LATEST_OPENWRT=0
LATEST_OPENCLASH=0
REQUESTED_OPENWRT=""
REQUESTED_OPENCLASH=""

log() {
    echo "[OpenWrt Build] $*"
}

die() {
    echo "[OpenWrt Build] ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

get_env_value() {
    local key="$1"
    [ -f "${ENV_FILE}" ] || return 0
    sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n 1
}

set_env_value() {
    local key="$1"
    local value="$2"

    touch "${ENV_FILE}"

    if grep -q "^${key}=" "${ENV_FILE}"; then
        sed -i "s/^${key}=.*/${key}=${value}/" "${ENV_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
}

normalize_openclash_version() {
    printf '%s\n' "${1#v}"
}

usage() {
    cat <<'USAGE'
Usage:
  ./update-openwrt-image.sh
  ./update-openwrt-image.sh --latest
  ./update-openwrt-image.sh --latest-openwrt
  ./update-openwrt-image.sh --latest-openclash
  ./update-openwrt-image.sh --openwrt VERSION
  ./update-openwrt-image.sh --openclash VERSION
  ./update-openwrt-image.sh --force

Behavior:
  No arguments
      Rebuild/select the exact versions pinned in .env.

  --latest
      Select the newest patch release in the current OpenWrt series and the
      latest OpenClash GitHub release.

  --latest-openwrt
      Select only the newest patch release in the current OpenWrt series.

  --latest-openclash
      Select only the latest OpenClash GitHub release.

  --openwrt VERSION
      Select an explicit OpenWrt version, including a new release series.

  --openclash VERSION
      Select an explicit OpenClash release tag (with or without leading v).

  --force
      Rebuild the final derived image even if its exact tag already exists.

The script never recreates the running OpenWrt container. After a successful
build, inspect with `docker compose config` and deploy manually with
`docker compose up -d`.
USAGE
}

find_latest_openwrt_patch() {
    local current_version="$1"
    local series latest

    series="$(printf '%s\n' "${current_version}" | awk -F. '{print $1 "." $2}')"

    latest="$(
        curl --fail --silent --show-error --location \
            --retry "${CURL_RETRIES}" \
            "${OPENWRT_RELEASES_URL}/" \
        | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
        | cut -d'"' -f2 \
        | tr -d '/' \
        | grep -E "^${series//./\\.}\.[0-9]+$" \
        | sort -V \
        | tail -n 1
    )"

    [ -n "${latest}" ] || die "Could not determine latest OpenWrt ${series}.x release"
    printf '%s\n' "${latest}"
}

github_curl() {
    local url="$1"
    local -a headers

    headers=(
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
    fi

    curl --fail --silent --show-error --location \
        --retry "${CURL_RETRIES}" \
        "${headers[@]}" \
        "${url}"
}

fetch_openclash_release() {
    local requested="$1"
    local json_path="$2"
    local api_url

    if [ "${requested}" = "latest" ]; then
        api_url="https://api.github.com/repos/${OPENCLASH_REPO}/releases/latest"
    else
        api_url="https://api.github.com/repos/${OPENCLASH_REPO}/releases/tags/v${requested}"
    fi

    github_curl "${api_url}" > "${json_path}.tmp"
    mv "${json_path}.tmp" "${json_path}"

    python3 - "${json_path}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    release = json.load(f)

tag = str(release.get("tag_name") or "").removeprefix("v")
if not tag:
    raise SystemExit("Missing OpenClash tag_name in GitHub release response")

assets = release.get("assets") or []
candidates = [a for a in assets if str(a.get("name", "")).endswith(".apk")]
preferred = [a for a in candidates if str(a.get("name", "")).startswith("luci-app-openclash")]
asset = (preferred or candidates or [None])[0]
if asset is None:
    raise SystemExit("No .apk asset found in OpenClash release")

name = str(asset.get("name") or "")
url = str(asset.get("browser_download_url") or "")
digest = str(asset.get("digest") or "")
if not url:
    raise SystemExit("OpenClash APK asset has no browser_download_url")

print(tag)
print(name)
print(url)
print(digest)
PY
}

download_openwrt_base() {
    local version="$1"
    local base_image="${BASE_REPOSITORY}:${version}"
    local release_url="${OPENWRT_RELEASES_URL}/${version}/targets/x86/64"
    local version_dir="${DOWNLOAD_DIR}/openwrt/${version}"
    local rootfs_name="openwrt-${version}-x86-64-rootfs.tar.gz"
    local rootfs_path="${version_dir}/${rootfs_name}"
    local sums_path="${version_dir}/sha256sums"
    local expected actual reported

    if docker image inspect "${base_image}" >/dev/null 2>&1; then
        reported="$(
            docker run --rm --entrypoint /bin/sh "${base_image}" \
                -c '. /etc/openwrt_release; printf "%s" "$DISTRIB_RELEASE"'
        )"
        [ "${reported}" = "${version}" ] \
            || die "Existing ${base_image} reports OpenWrt ${reported}"
        log "Base image already valid: ${base_image}"
        return
    fi

    mkdir -p "${version_dir}"

    log "Downloading OpenWrt ${version} checksums..."
    curl --fail --show-error --location --retry "${CURL_RETRIES}" \
        --retry-delay 2 \
        --output "${sums_path}.tmp" \
        "${release_url}/sha256sums"
    mv "${sums_path}.tmp" "${sums_path}"

    expected="$(
        awk -v filename="${rootfs_name}" \
            '{name=$2; if (substr(name, 1, 1) == "*") name=substr(name, 2); if (name == filename) {print $1; exit}}' \
            "${sums_path}"
    )"
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
        || die "Could not find SHA256 for ${rootfs_name}"

    if [ ! -f "${rootfs_path}" ]; then
        log "Downloading official OpenWrt rootfs..."
        curl --fail --show-error --location --retry "${CURL_RETRIES}" \
            --retry-delay 2 \
            --output "${rootfs_path}.tmp" \
            "${release_url}/${rootfs_name}"
        mv "${rootfs_path}.tmp" "${rootfs_path}"
    fi

    actual="$(sha256sum "${rootfs_path}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        rm -f "${rootfs_path}"
        die "OpenWrt rootfs SHA256 mismatch. Expected ${expected}, got ${actual}"
    fi

    log "OpenWrt rootfs SHA256 verified."
    log "Importing ${base_image}..."

    docker import \
        --change 'CMD ["/sbin/init"]' \
        "${rootfs_path}" \
        "${base_image}" >/dev/null

    reported="$(
        docker run --rm --entrypoint /bin/sh "${base_image}" \
            -c '. /etc/openwrt_release; printf "%s" "$DISTRIB_RELEASE"'
    )"
    [ "${reported}" = "${version}" ] \
        || die "Imported base image reports OpenWrt ${reported}, expected ${version}"

    log "Base image validated: ${base_image}"
}

download_openclash_apk() {
    local requested_version="$1"
    local output_vars_file="$2"
    local metadata_dir="${DOWNLOAD_DIR}/openclash/metadata"
    local metadata_path
    local parsed tag name url digest
    local version_dir apk_path actual expected

    mkdir -p "${metadata_dir}"

    if [ "${requested_version}" = "latest" ]; then
        metadata_path="${metadata_dir}/latest.json"
    else
        metadata_path="${metadata_dir}/v${requested_version}.json"
    fi

    log "Resolving OpenClash release ${requested_version}..."
    mapfile -t parsed < <(fetch_openclash_release "${requested_version}" "${metadata_path}")

    tag="${parsed[0]:-}"
    name="${parsed[1]:-}"
    url="${parsed[2]:-}"
    digest="${parsed[3]:-}"

    [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid OpenClash tag resolved from GitHub: ${tag}"

    version_dir="${DOWNLOAD_DIR}/openclash/${tag}"
    apk_path="${version_dir}/${name}"
    mkdir -p "${version_dir}"

    if [ ! -f "${apk_path}" ]; then
        log "Downloading OpenClash v${tag} APK..."
        curl --fail --show-error --location --retry "${CURL_RETRIES}" \
            --retry-delay 2 \
            --output "${apk_path}.tmp" \
            "${url}"
        mv "${apk_path}.tmp" "${apk_path}"
    fi

    actual="$(sha256sum "${apk_path}" | awk '{print $1}')"

    if [[ "${digest}" == sha256:* ]]; then
        expected="${digest#sha256:}"
        if [ "${actual}" != "${expected}" ]; then
            rm -f "${apk_path}"
            die "OpenClash APK SHA256 mismatch. Expected ${expected}, got ${actual}"
        fi
        log "OpenClash APK SHA256 verified using GitHub asset digest."
    else
        log "OpenClash APK SHA256: ${actual} (GitHub release metadata did not expose a SHA256 digest)"
    fi

    printf 'OPENCLASH_RESOLVED_VERSION=%q\n' "${tag}" > "${output_vars_file}"
    printf 'OPENCLASH_APK_PATH=%q\n' "${apk_path}" >> "${output_vars_file}"
}

validate_final_image() {
    local image="$1"
    local expected_openwrt="$2"
    local expected_openclash="$3"
    local reported_openwrt label_openclash

    reported_openwrt="$(
        docker run --rm --entrypoint /bin/sh "${image}" \
            -c '. /etc/openwrt_release; printf "%s" "$DISTRIB_RELEASE"'
    )"
    [ "${reported_openwrt}" = "${expected_openwrt}" ] \
        || die "${image} reports OpenWrt ${reported_openwrt}"

    docker run --rm --entrypoint /bin/sh "${image}" \
        -c 'apk info -e luci-app-openclash >/dev/null' \
        || die "${image} does not contain luci-app-openclash"

    label_openclash="$(
        docker image inspect "${image}" \
            --format '{{index .Config.Labels "org.openclash.version"}}'
    )"
    [ "${label_openclash}" = "${expected_openclash}" ] \
        || die "${image} OpenClash label is ${label_openclash}, expected ${expected_openclash}"
}

# ---------------------------------------------------------------------------
# Dependencies and arguments
# ---------------------------------------------------------------------------

require_command curl
require_command docker
require_command sha256sum
require_command awk
require_command sed
require_command grep
require_command sort
require_command python3

[ -f "${ENV_FILE}" ] || die "Missing ${ENV_FILE}"
[ -f "${DOCKERFILE}" ] || die "Missing ${DOCKERFILE}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --latest)
            LATEST_OPENWRT=1
            LATEST_OPENCLASH=1
            shift
            ;;
        --latest-openwrt)
            LATEST_OPENWRT=1
            shift
            ;;
        --latest-openclash)
            LATEST_OPENCLASH=1
            shift
            ;;
        --openwrt)
            [ "$#" -ge 2 ] || die "--openwrt requires VERSION"
            REQUESTED_OPENWRT="$2"
            shift 2
            ;;
        --openclash)
            [ "$#" -ge 2 ] || die "--openclash requires VERSION"
            REQUESTED_OPENCLASH="$(normalize_openclash_version "$2")"
            shift 2
            ;;
        --force)
            FORCE_BUILD=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

CURRENT_OPENWRT="$(get_env_value OPENWRT_VERSION)"
CURRENT_OPENCLASH="$(normalize_openclash_version "$(get_env_value OPENCLASH_VERSION)")"

[[ "${CURRENT_OPENWRT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid OPENWRT_VERSION in .env: ${CURRENT_OPENWRT}"
[[ "${CURRENT_OPENCLASH}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid OPENCLASH_VERSION in .env: ${CURRENT_OPENCLASH}"

TARGET_OPENWRT="${REQUESTED_OPENWRT:-${CURRENT_OPENWRT}}"
TARGET_OPENCLASH="${REQUESTED_OPENCLASH:-${CURRENT_OPENCLASH}}"

if [ "${LATEST_OPENWRT}" -eq 1 ]; then
    TARGET_OPENWRT="$(find_latest_openwrt_patch "${CURRENT_OPENWRT}")"
fi

if [ "${LATEST_OPENCLASH}" -eq 1 ]; then
    TARGET_OPENCLASH="latest"
fi

[[ "${TARGET_OPENWRT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid target OpenWrt version: ${TARGET_OPENWRT}"

mkdir -p "${DOWNLOAD_DIR}" "${BUILD_DIR}"

# Resolve/download OpenClash before constructing the final exact image tag.
OPENCLASH_VARS="$(mktemp)"
trap 'rm -f "${OPENCLASH_VARS}"' EXIT

download_openclash_apk "${TARGET_OPENCLASH}" "${OPENCLASH_VARS}"
# shellcheck disable=SC1090
source "${OPENCLASH_VARS}"

TARGET_OPENCLASH="${OPENCLASH_RESOLVED_VERSION}"
BASE_IMAGE="${BASE_REPOSITORY}:${TARGET_OPENWRT}"
FINAL_IMAGE="${FINAL_REPOSITORY}:${TARGET_OPENWRT}-oc${TARGET_OPENCLASH}"

log "Target OpenWrt : ${TARGET_OPENWRT}"
log "Target OpenClash: ${TARGET_OPENCLASH}"
log "Final image     : ${FINAL_IMAGE}"

if docker image inspect "${FINAL_IMAGE}" >/dev/null 2>&1 && [ "${FORCE_BUILD}" -eq 0 ]; then
    validate_final_image "${FINAL_IMAGE}" "${TARGET_OPENWRT}" "${TARGET_OPENCLASH}"
    log "Final image already exists and is valid; build skipped."
else
    download_openwrt_base "${TARGET_OPENWRT}"

    cp "${OPENCLASH_APK_PATH}" "${BUILD_DIR}/openclash.apk"

    TEMP_IMAGE="${FINAL_REPOSITORY}:build-${TARGET_OPENWRT}-oc${TARGET_OPENCLASH}-$$"

    log "Building derived OpenWrt + OpenClash image..."
    docker build \
        --file "${DOCKERFILE}" \
        --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
        --build-arg "OPENWRT_VERSION=${TARGET_OPENWRT}" \
        --build-arg "OPENCLASH_VERSION=${TARGET_OPENCLASH}" \
        --tag "${TEMP_IMAGE}" \
        "${PROJECT_DIR}"

    validate_final_image "${TEMP_IMAGE}" "${TARGET_OPENWRT}" "${TARGET_OPENCLASH}"

    docker tag "${TEMP_IMAGE}" "${FINAL_IMAGE}"
    docker image rm "${TEMP_IMAGE}" >/dev/null

    log "Final image validated: ${FINAL_IMAGE}"
fi

# Update Compose pins only after the exact final image is known-good.
set_env_value OPENWRT_VERSION "${TARGET_OPENWRT}"
set_env_value OPENCLASH_VERSION "${TARGET_OPENCLASH}"

log ""
log "Build/selection completed successfully."
log "Pinned versions in .env:"
log "  OPENWRT_VERSION=${TARGET_OPENWRT}"
log "  OPENCLASH_VERSION=${TARGET_OPENCLASH}"
log ""
log "The running container was NOT changed."
log "Review: docker compose config"
log "Deploy: docker compose up -d"
