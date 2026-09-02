#!/usr/bin/env bash
set -euo pipefail

OWNER="${GUARDENTRA_UPDATE_OWNER:-TheSGTMilla}"
REPO="${GUARDENTRA_UPDATE_REPO:-Guardentra-OS-Releases}"
STATE_DIR="${GUARDENTRA_UPDATE_STATE_DIR:-/var/lib/guardentra-update}"
CACHE_DIR="${GUARDENTRA_UPDATE_CACHE_DIR:-/var/cache/guardentra-update}"
API="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
UA="Guardentra-Update-Agent/0.6.2"
ACTION="${1:-check}"

mkdir -p "$STATE_DIR" "$CACHE_DIR"

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "This action requires administrator privileges."
    echo "Run: sudo guardentra-update $ACTION"
    exit 77
  fi
}

fetch_release() {
  local output http_code
  output="$(mktemp)"
  http_code="$(curl --silent --show-error --location \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: ${UA}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "$output" -w '%{http_code}' "$API" || true)"

  case "$http_code" in
    200)
      cat "$output"
      rm -f "$output"
      return 0
      ;;
    404)
      rm -f "$output"
      return 10
      ;;
    *)
      echo "Guardentra update service returned HTTP ${http_code:-unknown}." >&2
      rm -f "$output"
      return 11
      ;;
  esac
}

stage_guardentra_update() {
  local json tag bundle_url bundle_name sha_name sha_url bundle_path sha_path expected actual rc
  if ! json="$(fetch_release)"; then
    rc=$?
    if [[ "$rc" -eq 10 ]]; then
      echo "No Guardentra component release has been published yet."
      return 10
    fi
    echo "Unable to check the Guardentra component release channel."
    return "$rc"
  fi

  tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
  bundle_url="$(printf '%s' "$json" | jq -r '.assets[]? | select(.name|test("^guardentra-os-update-.*-amd64\\.tar\\.zst$")) | .browser_download_url' | head -n1)"
  bundle_name="$(printf '%s' "$json" | jq -r '.assets[]? | select(.name|test("^guardentra-os-update-.*-amd64\\.tar\\.zst$")) | .name' | head -n1)"

  if [[ -z "$bundle_url" || -z "$bundle_name" ]]; then
    echo "No Guardentra component update bundle is published in the latest release${tag:+ ($tag)}."
    return 10
  fi

  sha_name="${bundle_name}.sha256"
  sha_url="$(printf '%s' "$json" | jq -r --arg NAME "$sha_name" '.assets[]? | select(.name==$NAME) | .browser_download_url' | head -n1)"
  [[ -n "$sha_url" ]] || { echo "Refusing Guardentra update: checksum asset missing."; exit 4; }

  bundle_path="${CACHE_DIR}/${bundle_name}"
  sha_path="${CACHE_DIR}/${sha_name}"
  curl --fail --location --silent --show-error -A "$UA" "$bundle_url" -o "$bundle_path"
  curl --fail --location --silent --show-error -A "$UA" "$sha_url" -o "$sha_path"

  expected="$(awk 'NF {print tolower($1); exit}' "$sha_path")"
  actual="$(sha256sum "$bundle_path" | awk '{print tolower($1)}')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rm -f "$bundle_path"
    echo "Refusing Guardentra update: SHA-256 verification failed."
    exit 5
  fi

  printf '%s\n' "$tag" > "${STATE_DIR}/available-version"
  printf '%s\n' "$bundle_path" > "${STATE_DIR}/staged-bundle"
  printf '%s\n' "$actual" > "${STATE_DIR}/staged-sha256"
  echo "Guardentra update ${tag:-unknown} verified and staged."
  return 0
}

validate_archive_paths() {
  local bundle="$1" entry
  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..)
        echo "Refusing Guardentra update: unsafe archive path: $entry"
        return 1
        ;;
    esac
  done < <(tar --zstd -tf "$bundle")
}

apply_guardentra_update() {
  require_root
  local bundle expected actual tmp version
  [[ -f "${STATE_DIR}/staged-bundle" ]] || { echo "No staged Guardentra update. Checking now..."; stage_guardentra_update || true; }
  [[ -f "${STATE_DIR}/staged-bundle" ]] || { echo "No Guardentra component update is available."; return 0; }

  bundle="$(cat "${STATE_DIR}/staged-bundle")"
  [[ -f "$bundle" ]] || { echo "Staged update bundle is missing. Run guardentra-update check again."; exit 6; }
  expected="$(cat "${STATE_DIR}/staged-sha256" 2>/dev/null || true)"
  actual="$(sha256sum "$bundle" | awk '{print tolower($1)}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || { echo "Refusing Guardentra update: staged checksum no longer matches."; exit 7; }

  validate_archive_paths "$bundle"
  tmp="$(mktemp -d /tmp/guardentra-update.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN
  tar --zstd -xf "$bundle" -C "$tmp"

  [[ -d "$tmp/rootfs" ]] || { echo "Refusing Guardentra update: bundle has no rootfs payload."; exit 8; }

  if [[ -f "$tmp/guardentra-update-manifest.json" ]]; then
    version="$(jq -r '.version // empty' "$tmp/guardentra-update-manifest.json")"
  else
    version="$(cat "${STATE_DIR}/available-version" 2>/dev/null || true)"
  fi

  echo "Applying Guardentra component update${version:+ $version}..."
  rsync -aHAX "$tmp/rootfs/" /
  systemctl daemon-reload || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental || true
  command -v kbuildsycoca5 >/dev/null 2>&1 && kbuildsycoca5 --noincremental || true

  printf '%s\n' "${version:-unknown}" > "${STATE_DIR}/installed-component-version"
  rm -f "${STATE_DIR}/staged-bundle" "${STATE_DIR}/staged-sha256"
  echo "Guardentra component update applied successfully."
}

update_debian_base() {
  require_root
  echo "Updating Debian 13 base packages from configured signed repositories..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  echo "Debian base packages are up to date."
}

case "$ACTION" in
  check)
    stage_guardentra_update || rc=$?
    rc="${rc:-0}"
    [[ "$rc" -eq 10 ]] && exit 0
    exit "$rc"
    ;;
  apply)
    apply_guardentra_update
    ;;
  system)
    update_debian_base
    ;;
  all|update)
    update_debian_base
    stage_guardentra_update || true
    apply_guardentra_update
    echo "Guardentra OS update cycle complete. Reboot if a kernel or core system package was updated."
    ;;
  *)
    echo "Usage: guardentra-update [check|apply|system|all]"
    echo "  check  Check and stage a Guardentra component update (default)"
    echo "  apply  Apply the staged Guardentra component update"
    echo "  system Update Debian 13 base packages"
    echo "  all    Update Debian base + Guardentra components"
    exit 64
    ;;
esac
