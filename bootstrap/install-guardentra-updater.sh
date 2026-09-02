#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

PIN="798384c5b213d4550a44234b7596360c5f3c5780"
BASE="https://raw.githubusercontent.com/TheSGTMilla/Guardentra-OS-Releases/${PIN}/bootstrap"
TMP="$(mktemp -d /tmp/guardentra-updater-bootstrap.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "Guardentra OS 0.6 Pilot - Update Center bootstrap 0.6.5"
echo "Checking system clock before package verification..."

REMOTE_DATE="$(curl -fsSI "${BASE}/guardentra-update-agent.sh" | awk -F': ' 'tolower($1)=="date" {gsub("\r", "", $2); print $2; exit}' || true)"
if [[ -n "$REMOTE_DATE" ]]; then
  echo "Synchronizing system time from the HTTPS release channel: $REMOTE_DATE"
  date -u -s "$REMOTE_DATE" >/dev/null
  hwclock --systohc --utc >/dev/null 2>&1 || true
else
  echo "Unable to read trusted HTTPS server time; refusing to run apt with an unverified clock."
  exit 12
fi

echo "Current UTC time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Installing updater and time-sync prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates jq rsync zstd systemd-timesyncd

systemctl enable --now systemd-timesyncd.service || true
timedatectl set-ntp true >/dev/null 2>&1 || true

for _ in $(seq 1 20); do
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]] && break
  sleep 1
done

echo "Time status after NTP setup:"
timedatectl status || true

echo "Downloading pinned Guardentra OTA updater..."
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
echo "Guardentra Update Center 0.6.5 is installed."
echo "Static OTA channel: Guardentra-OS-Releases/channel/stable.json"
echo "Run now: sudo guardentra-update all"
