#!/usr/bin/env bash
set -euo pipefail

OWNER="${GUARDENTRA_UPDATE_OWNER:-TheSGTMilla}"
REPO="${GUARDENTRA_UPDATE_REPO:-Guardentra-OS-Releases}"
STATE_DIR="${GUARDENTRA_UPDATE_STATE_DIR:-/var/lib/guardentra-update}"
CACHE_DIR="${GUARDENTRA_UPDATE_CACHE_DIR:-/var/cache/guardentra-update}"
CHANNEL_URL="${GUARDENTRA_UPDATE_CHANNEL_URL:-https://raw.githubusercontent.com/${OWNER}/${REPO}/main/channel/stable.json}"
UA="Guardentra-Update-Agent/0.6.5"
ACTION="${1:-check}"

mkdir -p "$STATE_DIR" "$CACHE_DIR"

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "This action requires administrator privileges."
    echo "Run: sudo guardentra-update $ACTION"
    exit 77
  fi
}

fetch_channel() {
  curl --fail --silent --show-error --location \
    -H "Accept: application/json" \
    -H "User-Agent: ${UA}" \
    "$CHANNEL_URL"
}

stage_guardentra_update() {
  local json version installed bundle_url expected encoding payload_path bundle_path actual

  if ! json="$(fetch_channel)"; then
    echo "Unable to read the Guardentra update channel."
    return 11
  fi

  version="$(printf '%s' "$json" | jq -r '.version // empty')"
  bundle_url="$(printf '%s' "$json" | jq -r '.bundle_url // empty')"
  expected="$(printf '%s' "$json" | jq -r '.sha256 // empty' | tr '[:upper:]' '[:lower:]')"
  encoding="$(printf '%s' "$json" | jq -r '.encoding // "raw"')"

  [[ -n "$version" && -n "$bundle_url" && -n "$expected" ]] || {
    echo "Guardentra update channel metadata is incomplete."
    return 12
  }

  installed="$(cat "${STATE_DIR}/installed-component-version" 2>/dev/null || true)"
  if [[ "$installed" == "$version" ]]; then
    echo "Guardentra components are already up to date ($version)."
    return 10
  fi

  bundle_path="${CACHE_DIR}/guardentra-os-update-${version}-amd64.tar.zst"
  payload_path="${bundle_path}.download"

  echo "Downloading Guardentra component update $version..."
  curl --fail --location --silent --show-error -A "$UA" "$bundle_url" -o "$payload_path"

  case "$encoding" in
    base64)
      base64 --decode "$payload_path" > "$bundle_path"
      rm -f "$payload_path"
      ;;
    raw|none|"")
      mv "$payload_path" "$bundle_path"
      ;;
    *)
      rm -f "$payload_path"
      echo "Unsupported Guardentra update encoding: $encoding"
      return 13
      ;;
  esac

  actual="$(sha256sum "$bundle_path" | awk '{print tolower($1)}')"
  if [[ "$expected" != "$actual" ]]; then
    rm -f "$bundle_path"
    echo "Refusing Guardentra update: SHA-256 verification failed."
    echo "Expected: $expected"
    echo "Actual:   $actual"
    return 5
  fi

  printf '%s\n' "$version" > "${STATE_DIR}/available-version"
  printf '%s\n' "$bundle_path" > "${STATE_DIR}/staged-bundle"
  printf '%s\n' "$actual" > "${STATE_DIR}/staged-sha256"
  echo "Guardentra update $version verified and staged."
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

  if [[ ! -f "${STATE_DIR}/staged-bundle" ]]; then
    echo "No staged Guardentra update. Checking now..."
    set +e
    stage_guardentra_update
    local rc=$?
    set -e
    if [[ "$rc" -eq 10 ]]; then
      return 0
    elif [[ "$rc" -ne 0 ]]; then
      return "$rc"
    fi
  fi

  bundle="$(cat "${STATE_DIR}/staged-bundle")"
  [[ -f "$bundle" ]] || { echo "Staged update bundle is missing. Run guardentra-update check again."; return 6; }

  expected="$(cat "${STATE_DIR}/staged-sha256" 2>/dev/null || true)"
  actual="$(sha256sum "$bundle" | awk '{print tolower($1)}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || {
    echo "Refusing Guardentra update: staged checksum no longer matches."
    return 7
  }

  validate_archive_paths "$bundle"
  tmp="$(mktemp -d /tmp/guardentra-update.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN
  tar --zstd -xf "$bundle" -C "$tmp"

  [[ -d "$tmp/rootfs" ]] || { echo "Refusing Guardentra update: bundle has no rootfs payload."; return 8; }

  if [[ -f "$tmp/guardentra-update-manifest.json" ]]; then
    version="$(jq -r '.version // empty' "$tmp/guardentra-update-manifest.json")"
  else
    version="$(cat "${STATE_DIR}/available-version" 2>/dev/null || true)"
  fi

  echo "Applying Guardentra component update${version:+ $version}..."
  rsync -aHAX "$tmp/rootfs/" /

  if [[ -f "$tmp/guardentra-post-apply.sh" ]]; then
    echo "Running Guardentra post-update configuration..."
    bash "$tmp/guardentra-post-apply.sh"
  fi

  systemctl daemon-reload || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental || true
  command -v kbuildsycoca5 >/dev/null 2>&1 && kbuildsycoca5 --noincremental || true

  printf '%s\n' "${version:-unknown}" > "${STATE_DIR}/installed-component-version"
  rm -f "${STATE_DIR}/staged-bundle" "${STATE_DIR}/staged-sha256" "${STATE_DIR}/available-version"
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
    set +e
    stage_guardentra_update
    rc=$?
    set -e
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
    set +e
    stage_guardentra_update
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      apply_guardentra_update
    elif [[ "$rc" -ne 10 ]]; then
      exit "$rc"
    fi
    echo "Guardentra OS update cycle complete. Reboot if a kernel, boot configuration, or Guardentra visual component was updated."
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
