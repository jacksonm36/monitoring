#!/usr/bin/env bash
# Install edge agent as systemd services: node_exporter, optional cAdvisor, Grafana Alloy (Linux bare metal / VM).
# Requires: root, curl, tar, unzip, systemd.
set -euo pipefail

_MON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/monitoring-common.sh
source "${_MON_SCRIPT_DIR}/lib/monitoring-common.sh"

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
CADVISOR_VERSION="${CADVISOR_VERSION:-0.47.2}"
ALLOY_VERSION="${ALLOY_VERSION:-1.7.5}"

resolve_monitoring_root() {
  if [[ -n "${MONITORING_ROOT:-}" ]]; then
    (cd "${MONITORING_ROOT}" && pwd)
    return
  fi
  local script_here
  script_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [[ "$(basename "${script_here}")" == "scripts" ]] && [[ -f "${script_here}/../deploy/agent/config.alloy" ]]; then
    (cd "${script_here}/.." && pwd)
    return
  fi
  if [[ -f ./deploy/agent/config.alloy ]]; then
    pwd
    return
  fi
  echo "Cannot find deploy/agent/config.alloy." >&2
  echo "Clone this repository, cd into it, and run again; or export MONITORING_ROOT to the repo root." >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Run this installer as root (use sudo)." >&2
    exit 1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) echo "Unsupported machine: $(uname -m)." >&2; exit 1 ;;
  esac
}

require_root
require_cmd curl
require_cmd tar
require_cmd unzip
require_cmd systemctl

if ! resolved_rw="$(monitoring_agent_bootstrap_remote_write_url)" || [[ -z "$resolved_rw" ]]; then
  echo "Could not determine CENTRAL_PROM_REMOTE_WRITE_URL." >&2
  echo "Set it explicitly, e.g. export CENTRAL_PROM_REMOTE_WRITE_URL='http://<central-ip>:9090/api/v1/write'" >&2
  if [[ -f /etc/monitoring/central/agent-connection-hints.txt ]]; then
    echo "Or see /etc/monitoring/central/agent-connection-hints.txt on the central server." >&2
  fi
  this_ip="$(monitoring_primary_ipv4 || true)"
  if [[ -n "$this_ip" ]]; then
    echo "Detected primary IPv4 on this host: ${this_ip} — if this machine runs central, use: http://${this_ip}:9090/api/v1/write" >&2
  fi
  exit 1
fi
CENTRAL_PROM_REMOTE_WRITE_URL="$resolved_rw"
export CENTRAL_PROM_REMOTE_WRITE_URL

ARCH="$(detect_arch)"
MONITORING_ROOT="$(resolve_monitoring_root)"
AGENT_DIR="${MONITORING_ROOT}/deploy/agent"
TMP="${TMPDIR:-/tmp}/monitoring-install-agent-$$"
rm -rf "$TMP"
mkdir -p "$TMP" /etc/monitoring/alloy /var/lib/alloy

AGENT_HOSTNAME="${AGENT_HOSTNAME:-$(monitoring_default_agent_host_label)}"

USE_DOCKER=0
if [[ -S /var/run/docker.sock ]] && [[ "${AGENT_SKIP_DOCKER:-0}" != "1" ]]; then
  USE_DOCKER=1
fi
export MONITORING_USE_DOCKER="$USE_DOCKER"

curl -fsSL \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
  -o "$TMP/node_exporter.tar.gz"
tar -xzf "$TMP/node_exporter.tar.gz" -C "$TMP"
NE_ROOT="$(find "$TMP" -maxdepth 1 -type d -name "node_exporter-*" | head -1)"
install -m 0755 "${NE_ROOT}/node_exporter" /usr/local/bin/node_exporter

if [[ "$USE_DOCKER" -eq 1 ]]; then
  echo "Installing cAdvisor ${CADVISOR_VERSION} (${ARCH})..."
  curl -fsSL \
    "https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-${ARCH}" \
    -o /usr/local/bin/cadvisor
  chmod 0755 /usr/local/bin/cadvisor
fi

echo "Installing Alloy ${ALLOY_VERSION} (${ARCH})..."
curl -fsSL \
  "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-linux-${ARCH}.zip" \
  -o "$TMP/alloy.zip"
unzip -qo "$TMP/alloy.zip" -d "$TMP"
ALLOY_BIN="$TMP/alloy-linux-${ARCH}"
if [[ ! -f "$ALLOY_BIN" ]]; then
  ALLOY_BIN="$(find "$TMP" -type f -name "alloy-linux-${ARCH}" | head -1 || true)"
fi
if [[ -z "${ALLOY_BIN}" ]] || [[ ! -f "$ALLOY_BIN" ]]; then
  echo "Could not locate Alloy binary in ${TMP}/alloy.zip" >&2
  exit 1
fi
install -m 0755 "$ALLOY_BIN" /usr/local/bin/alloy

id node_exporter &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin node_exporter
id alloy &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin alloy
chown -R alloy:alloy /var/lib/alloy
chmod 0750 /var/lib/alloy

if [[ "$USE_DOCKER" -eq 1 ]] && getent group docker >/dev/null; then
  usermod -aG docker alloy 2>/dev/null || true
fi

if [[ "$USE_DOCKER" -eq 1 ]]; then
  DOCKER_HOST_INTERNAL="${DOCKER_HOST_INTERNAL:-127.0.0.1}"
  cat >/etc/monitoring/alloy/environment <<EOF
REMOTE_WRITE_URL=${CENTRAL_PROM_REMOTE_WRITE_URL}
AGENT_HOST=${AGENT_HOSTNAME}
DOCKER_HOST_INTERNAL=${DOCKER_HOST_INTERNAL}
EOF
  install -m 0644 "${AGENT_DIR}/config.alloy" /etc/monitoring/alloy/config.alloy
else
  cat >/etc/monitoring/alloy/environment <<EOF
REMOTE_WRITE_URL=${CENTRAL_PROM_REMOTE_WRITE_URL}
AGENT_HOST=${AGENT_HOSTNAME}
EOF
  install -m 0644 "${AGENT_DIR}/config.no-docker.alloy" /etc/monitoring/alloy/config.alloy
fi

chown root:root /etc/monitoring/alloy/environment
chmod 0600 /etc/monitoring/alloy/environment

install -m 0644 "${AGENT_DIR}/systemd/node_exporter.service" /etc/systemd/system/node_exporter.service

if [[ "$USE_DOCKER" -eq 1 ]]; then
  install -m 0644 "${AGENT_DIR}/systemd/cadvisor.service" /etc/systemd/system/cadvisor.service
fi

install -m 0644 "${AGENT_DIR}/systemd/alloy.service" /etc/systemd/system/alloy.service
if [[ "$USE_DOCKER" -eq 1 ]]; then
  sed -i '/^\[Unit\]/a Wants=cadvisor.service' /etc/systemd/system/alloy.service
  sed -i 's/^After=network-online.target node_exporter.service$/After=network-online.target node_exporter.service cadvisor.service/' /etc/systemd/system/alloy.service
  if getent group docker >/dev/null; then
    sed -i '/^Group=alloy$/a SupplementaryGroups=docker' /etc/systemd/system/alloy.service
  fi
fi

rm -rf "$TMP"

systemctl daemon-reload
systemctl enable --now node_exporter.service
if [[ "$USE_DOCKER" -eq 1 ]]; then
  systemctl enable --now cadvisor.service
else
  systemctl disable --now cadvisor.service 2>/dev/null || true
fi
systemctl enable --now alloy.service

sleep 1
check_failed=0
monitoring_post_install_check_agent || check_failed=1
monitoring_security_review_agent || true

echo ""
echo "Agent stack is running under systemd."
echo "  agent_host label: ${AGENT_HOSTNAME}"
this_ip="$(monitoring_primary_ipv4 || true)"
if [[ -n "$this_ip" ]]; then
  echo "  Detected primary IPv4: ${this_ip}"
fi
echo "  Alloy debug UI: http://127.0.0.1:12345"
echo "  Remote write:   ${CENTRAL_PROM_REMOTE_WRITE_URL}"
if [[ "$USE_DOCKER" -eq 0 ]]; then
  echo "  (Docker not detected or AGENT_SKIP_DOCKER=1 — only node_exporter metrics are forwarded.)"
fi
echo "Verify in central Prometheus: up{job=\"node_exporter\",agent_host=\"${AGENT_HOSTNAME}\"}"

if [[ "$check_failed" -ne 0 ]]; then
  echo "[FAIL] One or more agent health checks failed; see journalctl -u alloy -u node_exporter -u cadvisor." >&2
  exit 1
fi
