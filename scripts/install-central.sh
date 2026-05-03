#!/usr/bin/env bash
# Install central Prometheus + Alertmanager + Grafana + InfluxDB + Telegraf as systemd services (Linux bare metal / VM).
# Requires: root, curl, tar, systemd, python3 (InfluxDB v2 first-time API setup + datasource rendering). Optional: jq or python3 for Grafana dashboard import; gettext (envsubst) to render Grafana Influx provisioning (else python fallback).
set -euo pipefail

_MON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/monitoring-common.sh
source "${_MON_SCRIPT_DIR}/lib/monitoring-common.sh"

PROM_VERSION="${PROM_VERSION:-2.55.1}"
AM_VERSION="${AM_VERSION:-0.27.0}"
GRAFANA_VERSION="${GRAFANA_VERSION:-11.3.1}"
INFLUX_VERSION="${INFLUX_VERSION:-2.6.1}"
TELEGRAF_VERSION="${TELEGRAF_VERSION:-1.33.3}"

resolve_monitoring_root() {
  if [[ -n "${MONITORING_ROOT:-}" ]]; then
    (cd "${MONITORING_ROOT}" && pwd)
    return
  fi
  local script_here
  script_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [[ "$(basename "${script_here}")" == "scripts" ]] && [[ -f "${script_here}/../deploy/central/prometheus/prometheus.yml" ]]; then
    (cd "${script_here}/.." && pwd)
    return
  fi
  if [[ -f ./deploy/central/prometheus/prometheus.yml ]]; then
    pwd
    return
  fi
  echo "Cannot find deploy/central/prometheus/prometheus.yml." >&2
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
    *) echo "Unsupported machine: $(uname -m). Set ARCH manually to amd64|arm64." >&2; exit 1 ;;
  esac
}

download_dashboard() {
  local dash_id="$1"
  local out="$2"
  local raw
  raw="$(mktemp)"
  curl -fsSL "https://grafana.com/api/dashboards/${dash_id}/revisions/latest/download" -o "$raw"
  if command -v jq >/dev/null 2>&1; then
    jq 'if .dashboard then .dashboard else . end | .id = null' "$raw" >"$out"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
with open('$raw') as f:
    raw = json.load(f)
d = raw['dashboard'] if isinstance(raw, dict) and 'dashboard' in raw else raw
if not isinstance(d, dict):
    raise SystemExit('unexpected dashboard JSON')
d['id'] = None
with open('$out', 'w') as f:
    json.dump(d, f)
"
  else
    echo "Install jq or python3 to import Grafana dashboards; skipping ${dash_id}" >&2
    rm -f "$raw"
    return 1
  fi
  rm -f "$raw"
}

# First-time InfluxDB v2 setup (API), token file, Telegraf writer env, Grafana Flux datasource provisioning.
central_bootstrap_influx() {
  command -v python3 >/dev/null 2>&1 || {
    echo "InfluxDB setup requires python3." >&2
    return 1
  }
  local envf=/etc/monitoring/central/influx.env
  local tokf=/etc/monitoring/central/influx-token
  local tw=/etc/monitoring/central/telegraf-writer.env
  local ds_tmpl="${CENTRAL_DIR}/influx/grafana-datasource.yml.envsubst"
  local ds_out=/etc/grafana/provisioning/datasources/influxdb.yml
  [[ -f "$envf" ]] || {
    echo "[FAIL] Missing ${envf}" >&2
    return 1
  }
  [[ -f "$ds_tmpl" ]] || {
    echo "[FAIL] Missing ${ds_tmpl}" >&2
    return 1
  }

  local org bucket retention pw
  org="$(grep -E '^INFLUX_ORG=' "$envf" | head -1 | cut -d= -f2- | tr -d '\r')"
  bucket="$(grep -E '^INFLUX_BUCKET=' "$envf" | head -1 | cut -d= -f2- | tr -d '\r')"
  retention="$(grep -E '^INFLUX_RETENTION=' "$envf" | head -1 | cut -d= -f2- | tr -d '\r')"
  pw="$(grep -E '^INFLUX_ADMIN_PASSWORD=' "$envf" | head -1 | cut -d= -f2- | tr -d '\r')"
  org="${org:-monitoring}"
  bucket="${bucket:-network}"
  retention="${retention:-720h}"
  if [[ -z "$pw" ]]; then
    echo "[FAIL] INFLUX_ADMIN_PASSWORD is empty in ${envf}" >&2
    return 1
  fi

  local rsecs allowed_json allowed token
  rsecs="$(monitoring_influx_retention_to_seconds "$retention")"
  allowed_json="$(curl -fsS --max-time 15 "http://127.0.0.1:8086/api/v2/setup")"
  allowed="$(printf '%s' "$allowed_json" | python3 -c "import sys, json; print('yes' if json.load(sys.stdin).get('allowed') else 'no')")"

  if [[ "$allowed" == "yes" ]]; then
    token="$(
      export _INFLUX_SETUP_PW="$pw" _INFLUX_SETUP_ORG="$org" _INFLUX_SETUP_BUCKET="$bucket" _INFLUX_SETUP_RETENTION="$rsecs"
      python3 <<'PY'
import json, os, urllib.request, urllib.error
try:
    req = urllib.request.Request(
        "http://127.0.0.1:8086/api/v2/setup",
        data=json.dumps({
            "username": "admin",
            "password": os.environ["_INFLUX_SETUP_PW"],
            "org": os.environ["_INFLUX_SETUP_ORG"],
            "bucket": os.environ["_INFLUX_SETUP_BUCKET"],
            "retentionPeriodSeconds": int(os.environ["_INFLUX_SETUP_RETENTION"]),
        }).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=45) as resp:
        out = json.load(resp)
    print(out["auth"]["token"])
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8", "replace")
    raise SystemExit(f"HTTP {e.code}: {body}") from e
PY
    )"
    unset _INFLUX_SETUP_PW _INFLUX_SETUP_ORG _INFLUX_SETUP_BUCKET _INFLUX_SETUP_RETENTION
    umask 077
    printf '%s' "$token" >"$tokf"
    chmod 0600 "$tokf"
  else
    if [[ -f "$tokf" ]]; then
      token="$(tr -d '\n\r' <"$tokf")"
    else
      echo "[FAIL] InfluxDB is already initialized but ${tokf} is missing. Add an API token with write access to bucket ${bucket}, save it to that path (mode 600), and re-run this installer." >&2
      return 1
    fi
  fi

  umask 077
  {
    echo "# Generated by install-central.sh — Telegraf → InfluxDB v2."
    echo "INFLUX_TOKEN=${token}"
    echo "INFLUX_ORG=${org}"
    echo "INFLUX_BUCKET=${bucket}"
  } >"$tw"
  chmod 0600 "$tw"

  export INFLUX_ORG="$org" INFLUX_BUCKET="$bucket" GRAFANA_INFLUX_TOKEN="$token"
  if command -v envsubst >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    envsubst '${INFLUX_ORG} ${INFLUX_BUCKET} ${GRAFANA_INFLUX_TOKEN}' <"$ds_tmpl" >"$ds_out"
  else
    python3 - "$ds_tmpl" "$ds_out" <<'PY'
import os
from pathlib import Path
import sys

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
t = src.read_text()
t = t.replace("${INFLUX_ORG}", os.environ["INFLUX_ORG"])
t = t.replace("${INFLUX_BUCKET}", os.environ["INFLUX_BUCKET"])
t = t.replace("${GRAFANA_INFLUX_TOKEN}", os.environ["GRAFANA_INFLUX_TOKEN"])
dst.write_text(t)
PY
  fi
  chown grafana:grafana "$ds_out" 2>/dev/null || true
  chmod 0600 "$ds_out"
  unset GRAFANA_INFLUX_TOKEN INFLUX_ORG INFLUX_BUCKET

  if systemctl is-active --quiet grafana.service 2>/dev/null; then
    systemctl restart grafana.service || true
  fi
}

require_root
require_cmd curl
require_cmd tar
require_cmd systemctl
require_cmd python3

ARCH="$(detect_arch)"
MONITORING_ROOT="$(resolve_monitoring_root)"
CENTRAL_DIR="${MONITORING_ROOT}/deploy/central"
TMP="${TMPDIR:-/tmp}/monitoring-install-central-$$"
rm -rf "$TMP"
mkdir -p "$TMP" /etc/monitoring/prometheus /etc/monitoring/alertmanager /etc/monitoring/central \
  /etc/grafana/provisioning /var/lib/prometheus /var/lib/alertmanager /var/lib/grafana/dashboards \
  /var/log/grafana /opt/monitoring /var/lib/influxdb /etc/telegraf
# Prometheus and Alertmanager run as non-root; they must traverse and read these dirs (root umask may create 0700).
chmod 0755 /etc/monitoring/prometheus /etc/monitoring/alertmanager /etc/telegraf
# Grafana WorkingDirectory must be traversed by user grafana.
chmod 0755 /opt/monitoring

id prometheus &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin prometheus
id grafana &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin grafana
id influxdb &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin influxdb
id telegraf &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin telegraf

install -m 0644 "${CENTRAL_DIR}/prometheus/prometheus.yml" /etc/monitoring/prometheus/prometheus.yml
install -m 0644 "${CENTRAL_DIR}/prometheus/alerts.yml" /etc/monitoring/prometheus/alerts.yml
install -m 0644 "${CENTRAL_DIR}/alertmanager/alertmanager.yml" /etc/monitoring/alertmanager/alertmanager.yml
install -m 0644 "${CENTRAL_DIR}/grafana/grafana.ini" /etc/grafana/grafana.ini
cp -a "${CENTRAL_DIR}/grafana/provisioning/." /etc/grafana/provisioning/
chmod 0755 /etc/grafana /etc/grafana/provisioning

if [[ ! -f /etc/monitoring/central/grafana.env ]]; then
  if [[ -f "${CENTRAL_DIR}/grafana.env.example" ]]; then
    install -m 0600 "${CENTRAL_DIR}/grafana.env.example" /etc/monitoring/central/grafana.env
    echo "Created /etc/monitoring/central/grafana.env from example — set GF_SECURITY_ADMIN_PASSWORD before production."
  fi
fi
chown root:root /etc/monitoring/central/grafana.env 2>/dev/null || true
chmod 0600 /etc/monitoring/central/grafana.env 2>/dev/null || true

if [[ ! -f /etc/monitoring/central/influx.env ]]; then
  if [[ -f "${CENTRAL_DIR}/influx.env.example" ]]; then
    install -m 0600 "${CENTRAL_DIR}/influx.env.example" /etc/monitoring/central/influx.env
    echo "Created /etc/monitoring/central/influx.env from example — set INFLUX_ADMIN_PASSWORD before production."
  fi
fi
chown root:root /etc/monitoring/central/influx.env 2>/dev/null || true
chmod 0600 /etc/monitoring/central/influx.env 2>/dev/null || true

chown -R prometheus:prometheus /var/lib/prometheus
chown -R prometheus:prometheus /var/lib/alertmanager
chown -R grafana:grafana /var/lib/grafana /var/log/grafana
chown -R influxdb:influxdb /var/lib/influxdb
chmod 0750 /var/lib/prometheus /var/lib/alertmanager /var/lib/influxdb

echo "Installing Prometheus ${PROM_VERSION} (${ARCH})..."
curl -fsSL \
  "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-${ARCH}.tar.gz" \
  -o "$TMP/prometheus.tar.gz"
tar -xzf "$TMP/prometheus.tar.gz" -C "$TMP"
PROM_ROOT="$(find "$TMP" -maxdepth 1 -type d -name "prometheus-*" | head -1)"
install -m 0755 "${PROM_ROOT}/prometheus" /usr/local/bin/prometheus
install -m 0755 "${PROM_ROOT}/promtool" /usr/local/bin/promtool

echo "Installing Alertmanager ${AM_VERSION} (${ARCH})..."
curl -fsSL \
  "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-${ARCH}.tar.gz" \
  -o "$TMP/alertmanager.tar.gz"
tar -xzf "$TMP/alertmanager.tar.gz" -C "$TMP"
AM_ROOT="$(find "$TMP" -maxdepth 1 -type d -name "alertmanager-*" | head -1)"
install -m 0755 "${AM_ROOT}/alertmanager" /usr/local/bin/alertmanager
install -m 0755 "${AM_ROOT}/amtool" /usr/local/bin/amtool

echo "Installing InfluxDB OSS ${INFLUX_VERSION} (${ARCH})..."
curl -fsSL \
  "https://dl.influxdata.com/influxdb/releases/influxdb2-${INFLUX_VERSION}-linux-${ARCH}.tar.gz" \
  -o "$TMP/influxdb.tar.gz"
tar -xzf "$TMP/influxdb.tar.gz" -C "$TMP"
INFLUX_ROOT="$(find "$TMP" -maxdepth 1 -type d \( -name 'influxdb2-*' -o -name 'influxdb2_*' \) | head -1)"
if [[ -z "$INFLUX_ROOT" || ! -f "${INFLUX_ROOT}/influxd" ]]; then
  echo "Could not find influxd in extracted Influx archive under ${TMP}." >&2
  exit 1
fi
install -m 0755 "${INFLUX_ROOT}/influxd" /usr/local/bin/influxd
if [[ -f "${INFLUX_ROOT}/influx" ]]; then
  install -m 0755 "${INFLUX_ROOT}/influx" /usr/local/bin/influx
fi

echo "Installing Telegraf ${TELEGRAF_VERSION} (${ARCH})..."
curl -fsSL \
  "https://dl.influxdata.com/telegraf/releases/telegraf-${TELEGRAF_VERSION}_linux_${ARCH}.tar.gz" \
  -o "$TMP/telegraf.tar.gz"
tar -xzf "$TMP/telegraf.tar.gz" -C "$TMP"
TELE_ROOT="$(find "$TMP" -maxdepth 1 -type d -name "telegraf-*" | head -1)"
install -m 0755 "${TELE_ROOT}/usr/bin/telegraf" /usr/local/bin/telegraf

echo "Installing Grafana OSS ${GRAFANA_VERSION} (${ARCH})..."
curl -fsSL \
  "https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-${ARCH}.tar.gz" \
  -o "$TMP/grafana.tar.gz"
tar -xzf "$TMP/grafana.tar.gz" -C "$TMP"
GRAFANA_ROOT="$(find "$TMP" -maxdepth 1 -type d -name "grafana-*" | head -1)"
rm -rf /opt/monitoring/grafana
mv "$GRAFANA_ROOT" /opt/monitoring/grafana
chown -R root:root /opt/monitoring/grafana
chmod 0755 /opt/monitoring

if [[ ! -f /var/lib/grafana/dashboards/node-exporter-full.json ]]; then
  download_dashboard 1860 /var/lib/grafana/dashboards/node-exporter-full.json || true
fi
if [[ ! -f /var/lib/grafana/dashboards/docker-monitoring.json ]]; then
  download_dashboard 193 /var/lib/grafana/dashboards/docker-monitoring.json || true
fi
shopt -s nullglob
for bundled in "${CENTRAL_DIR}/grafana/dashboards/"*.json; do
  base="$(basename "$bundled")"
  install -m 0644 "$bundled" "/var/lib/grafana/dashboards/${base}"
done
shopt -u nullglob
chown -R grafana:grafana /var/lib/grafana/dashboards

install -m 0644 "${CENTRAL_DIR}/telegraf/telegraf.conf" /etc/telegraf/telegraf.conf

install -m 0644 "${CENTRAL_DIR}/systemd/prometheus.service" /etc/systemd/system/prometheus.service
install -m 0644 "${CENTRAL_DIR}/systemd/alertmanager.service" /etc/systemd/system/alertmanager.service
install -m 0644 "${CENTRAL_DIR}/systemd/influxdb.service" /etc/systemd/system/influxdb.service
install -m 0644 "${CENTRAL_DIR}/systemd/telegraf.service" /etc/systemd/system/telegraf.service
install -m 0644 "${CENTRAL_DIR}/systemd/grafana.service" /etc/systemd/system/grafana.service

rm -rf "$TMP"

systemctl daemon-reload
systemctl enable alertmanager.service prometheus.service influxdb.service telegraf.service grafana.service

systemctl start alertmanager.service prometheus.service influxdb.service
monitoring_wait_influx_ready 55 || {
  echo "[FAIL] InfluxDB did not become ready on http://127.0.0.1:8086/health (local check; service binds 0.0.0.0:8086 — see journalctl -u influxdb)." >&2
  exit 1
}

if ! central_bootstrap_influx; then
  echo "[FAIL] InfluxDB bootstrap (org/bucket/token and Grafana datasource) failed." >&2
  exit 1
fi

systemctl start telegraf.service grafana.service

monitoring_wait_systemd_active prometheus.service 20 || true
monitoring_wait_systemd_active influxdb.service 20 || true
monitoring_wait_systemd_active telegraf.service 30 || true
monitoring_wait_systemd_active grafana.service 25 || true

PRIMARY_IP="$(monitoring_primary_ipv4 || true)"
if [[ -z "$PRIMARY_IP" ]]; then
  PRIMARY_IP="$(monitoring_all_global_ipv4 | head -1 || true)"
fi
if [[ -z "$PRIMARY_IP" ]]; then
  PRIMARY_IP="127.0.0.1"
fi
ALL_IPV4_SPACE="$(monitoring_all_global_ipv4 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

check_failed=0
monitoring_post_install_check_central || check_failed=1
monitoring_security_review_central || true

monitoring_write_central_hints "$PRIMARY_IP" "$ALL_IPV4_SPACE"

echo ""
echo "Central stack is running under systemd."
echo "  Detected primary IPv4: ${PRIMARY_IP}"
if [[ -n "$ALL_IPV4_SPACE" ]]; then
  echo "  All detected global IPv4s: ${ALL_IPV4_SPACE}"
fi
echo "  Prometheus:   http://${PRIMARY_IP}:9090 (remote write: POST /api/v1/write)"
echo "  Grafana:      http://${PRIMARY_IP}:3000 (see /etc/monitoring/central/grafana.env)"
echo "  Alertmanager: http://${PRIMARY_IP}:9093"
echo "  InfluxDB:     http://${PRIMARY_IP}:8086 (bind 0.0.0.0:8086; token: /etc/monitoring/central/influx-token)"
echo ""
echo "Remote agents on this LAN can use:"
echo "  export CENTRAL_PROM_REMOTE_WRITE_URL='http://${PRIMARY_IP}:9090/api/v1/write'"
echo "Agents on this same host auto-detect that URL when CENTRAL_PROM_REMOTE_WRITE_URL is unset and Prometheus is healthy."
echo ""
if [[ "$check_failed" -ne 0 ]]; then
  echo "[FAIL] One or more central health checks failed; see systemd logs (journalctl -u prometheus -u grafana -u alertmanager -u influxdb -u telegraf)." >&2
  exit 1
fi
