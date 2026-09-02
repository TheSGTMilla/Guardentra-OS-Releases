#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

PIN="5ce90f3c310a9eb7cd156eb670446be845d26267"
BASE="https://raw.githubusercontent.com/TheSGTMilla/Guardentra-OS-Releases/${PIN}/bootstrap"
TMP="$(mktemp -d /tmp/guardentra-updater-bootstrap.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "Guardentra OS 0.6 Pilot - Update Center bootstrap"
echo "Installing updater prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates jq rsync zstd

echo "Downloading pinned Guardentra updater payload..."
curl --fail --location --silent --show-error \
  "${BASE}/guardentra-update-agent.sh" \
  -o "${TMP}/guardentra-update-agent.sh"
curl --fail --location --silent --show-error \
  "${BASE}/guardentra-update-center.desktop" \
  -o "${TMP}/guardentra-update-center.desktop"

install -d -m 0755 /opt/guardentra/update /usr/local/sbin /usr/share/applications
install -m 0755 "${TMP}/guardentra-update-agent.sh" /opt/guardentra/update/guardentra-update-agent.sh
install -m 0644 "${TMP}/guardentra-update-center.desktop" /usr/share/applications/guardentra-update-center.desktop

cat > /usr/local/sbin/guardentra-update <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/guardentra/update/guardentra-update-agent.sh "$@"
WRAPPER
chmod 0755 /usr/local/sbin/guardentra-update

systemctl daemon-reload || true
if systemctl list-unit-files guardentra-update-check.timer >/dev/null 2>&1; then
  systemctl enable --now guardentra-update-check.timer || true
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true

echo
echo "Guardentra Update Center is installed."
echo "Daily update checks are enabled when the Guardentra timer is available."
echo "Use the application menu: Guardentra Update Center"
echo "Or run: sudo guardentra-update all"
