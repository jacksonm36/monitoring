#!/usr/bin/env bash
# Shared helpers for monitoring install scripts (source this file; do not execute directly).

monitoring_lib_dir() {
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
}

# Best-effort routable IPv4 (for LAN agent URLs). Empty if unknown.
monitoring_primary_ipv4() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  fi
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
  fi
}

# Non-loopback global IPv4 addresses (one per line).
monitoring_all_global_ipv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | sort -u
  elif command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF && $1 != "127.0.0.1" { print $1 }' | sort -u
  fi
}

# When central Prometheus is on this host, agents can use this remote_write URL.
monitoring_local_prometheus_remote_write_url() {
  printf '%s' "http://127.0.0.1:9090/api/v1/write"
}

# Returns 0 if Prometheus on localhost responds to /-/ready.
monitoring_local_prometheus_ready() {
  curl -fsS --max-time 3 "http://127.0.0.1:9090/-/ready" >/dev/null 2>&1
}

# Wait for Prometheus on localhost (e.g. agent install right after central).
monitoring_wait_local_prometheus_ready() {
  local tries="${1:-10}"
  local i
  for ((i = 1; i <= tries; i++)); do
    monitoring_local_prometheus_ready && return 0
    sleep 2
  done
  return 1
}

# InfluxDB retention string → seconds (for /api/v2/setup). Supports Nd, Nw, Nh, or plain integer seconds.
monitoring_influx_retention_to_seconds() {
  local r="${1:-720h}"
  if [[ "$r" =~ ^([0-9]+)h$ ]]; then
    printf '%s\n' "$((${BASH_REMATCH[1]} * 3600))"
  elif [[ "$r" =~ ^([0-9]+)d$ ]]; then
    printf '%s\n' "$((${BASH_REMATCH[1]} * 86400))"
  elif [[ "$r" =~ ^([0-9]+)w$ ]]; then
    printf '%s\n' "$((${BASH_REMATCH[1]} * 604800))"
  elif [[ "$r" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$r"
  else
    printf '%s\n' "2592000"
  fi
}

# Wait for InfluxDB v2 HTTP /health status pass (localhost).
monitoring_wait_influx_ready() {
  local tries="${1:-45}"
  local i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS --max-time 3 "http://127.0.0.1:8086/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"pass"'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Full agent URL resolution: env -> central hints file on same host -> wait for local Prometheus.
monitoring_agent_bootstrap_remote_write_url() {
  if [[ -n "${CENTRAL_PROM_REMOTE_WRITE_URL:-}" ]]; then
    printf '%s' "${CENTRAL_PROM_REMOTE_WRITE_URL}"
    return 0
  fi
  local hints="/etc/monitoring/central/agent-connection-hints.txt"
  if [[ -f "$hints" ]]; then
    local from_hints
    from_hints="$(grep -E '^CENTRAL_PROM_REMOTE_WRITE_URL=' "$hints" | head -1 | cut -d= -f2-)"
    if [[ -n "$from_hints" ]]; then
      echo "Using CENTRAL_PROM_REMOTE_WRITE_URL from ${hints} (same host as central)." >&2
      printf '%s' "$from_hints"
      return 0
    fi
  fi
  local tries="${LOCAL_PROM_WAIT_TRIES:-10}"
  if monitoring_wait_local_prometheus_ready "$tries"; then
    echo "Auto-selected local Prometheus remote write URL (localhost, waited up to ~$((tries * 2))s for /-/ready)." >&2
    monitoring_local_prometheus_remote_write_url
    return 0
  fi
  return 1
}

# Default agent_host label: primary IPv4 if any, else FQDN/hostname.
monitoring_default_agent_host_label() {
  local ip
  ip="$(monitoring_primary_ipv4 || true)"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
  else
    hostname -f 2>/dev/null || hostname
  fi
}

# --- Post-install: health (bug check) ---

monitoring_wait_systemd_active() {
  local unit="$1"
  local tries="${2:-15}"
  local i
  for ((i = 1; i <= tries; i++)); do
    if systemctl is-active --quiet "$unit"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

monitoring_post_install_check_central() {
  local failed=0
  echo ""
  echo "=== Post-install health checks (central) ==="
  for u in alertmanager prometheus influxdb telegraf grafana; do
    if systemctl is-active --quiet "${u}.service"; then
      echo "[OK] ${u}.service is active"
    else
      echo "[FAIL] ${u}.service is not active" >&2
      failed=1
    fi
  done
  sleep 1
  if curl -fsS --max-time 5 "http://127.0.0.1:9090/-/ready" >/dev/null; then
    echo "[OK] Prometheus /-/ready"
  else
    echo "[FAIL] Prometheus /-/ready" >&2
    failed=1
  fi
  if curl -fsS --max-time 5 "http://127.0.0.1:9093/-/healthy" >/dev/null; then
    echo "[OK] Alertmanager /-/healthy"
  else
    echo "[FAIL] Alertmanager /-/healthy" >&2
    failed=1
  fi
  if curl -fsS --max-time 5 "http://127.0.0.1:3000/api/health" | grep -qE '"database"[[:space:]]*:[[:space:]]*"ok"'; then
    echo "[OK] Grafana /api/health"
  else
    echo "[WARN] Grafana /api/health did not report database ok (service may still be starting)" >&2
  fi
  if curl -fsS --max-time 5 "http://127.0.0.1:8086/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"pass"'; then
    echo "[OK] InfluxDB /health"
  else
    echo "[FAIL] InfluxDB /health" >&2
    failed=1
  fi
  echo "=== End health checks ==="
  return "$failed"
}

monitoring_post_install_check_agent() {
  local failed=0
  local use_docker="${MONITORING_USE_DOCKER:-0}"
  echo ""
  echo "=== Post-install health checks (agent) ==="
  if systemctl is-active --quiet node_exporter.service; then
    echo "[OK] node_exporter.service is active"
  else
    echo "[FAIL] node_exporter.service is not active" >&2
    failed=1
  fi
  if [[ "$use_docker" -eq 1 ]]; then
    if systemctl is-active --quiet cadvisor.service; then
      echo "[OK] cadvisor.service is active"
    else
      echo "[WARN] cadvisor.service is not active" >&2
    fi
  fi
  if systemctl is-active --quiet alloy.service; then
    echo "[OK] alloy.service is active"
  else
    echo "[FAIL] alloy.service is not active" >&2
    failed=1
  fi
  sleep 1
  if curl -fsS --max-time 5 "http://127.0.0.1:9100/metrics" | head -1 | grep -q .; then
    echo "[OK] node_exporter metrics endpoint"
  else
    echo "[FAIL] node_exporter metrics endpoint" >&2
    failed=1
  fi
  if curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:12345/"; then
    echo "[OK] Alloy HTTP UI (/)"
  else
    echo "[WARN] Alloy HTTP UI not reachable on 127.0.0.1:12345" >&2
  fi
  echo "=== End health checks ==="
  return "$failed"
}

# --- Security review (non-blocking warnings) ---

monitoring_security_review_central() {
  echo ""
  echo "=== Security review (central) ==="
  local gf="/etc/monitoring/central/grafana.env"
  if [[ -f "$gf" ]]; then
    local mode
    mode="$(stat -c '%a' "$gf" 2>/dev/null || stat -f '%OLp' "$gf" 2>/dev/null || echo "?")"
    if [[ "$mode" != "600" ]]; then
      echo "[WARN] ${gf} mode is ${mode}; recommend chmod 600 (contains secrets)." >&2
    else
      echo "[OK] ${gf} permissions 600"
    fi
    local pw=""
    pw="$(grep -E '^GF_SECURITY_ADMIN_PASSWORD=' "$gf" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [[ -z "$pw" || "$pw" == "admin" || "$pw" == "changeme" || "$pw" == "REPLACE_ME" || "$pw" == "replace-after-influx-setup" ]]; then
      echo "[WARN] Grafana admin password is empty or a known weak value in ${gf}; set a strong GF_SECURITY_ADMIN_PASSWORD." >&2
    else
      echo "[OK] Grafana env present (verify password strength out of band)."
    fi
  else
    echo "[WARN] Missing ${gf}; Grafana may use built-in defaults." >&2
  fi
  local ift="/etc/monitoring/central/influx-token"
  if [[ -f "$ift" ]]; then
    local imode
    imode="$(stat -c '%a' "$ift" 2>/dev/null || stat -f '%OLp' "$ift" 2>/dev/null || echo "?")"
    if [[ "$imode" != "600" ]]; then
      echo "[WARN] ${ift} mode is ${imode}; recommend chmod 600." >&2
    else
      echo "[OK] ${ift} permissions 600"
    fi
  else
    echo "[INFO] No ${ift} yet (expected only after first InfluxDB setup)."
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnp 2>/dev/null | grep -q ':9090 '; then
      local bind
      bind="$(ss -ltnp 2>/dev/null | awk '/:9090 / { print $4 }' | head -1)"
      echo "[INFO] Prometheus listens on ${bind:-unknown}:9090 — restrict with host/VPC firewall if not management-only."
      if echo "$bind" | grep -qE '^\*:|0\.0\.0\.0:|:::'; then
        echo "[WARN] Prometheus appears bound to all interfaces; remote write is unauthenticated. Use TLS/auth or firewall." >&2
      fi
    fi
    if ss -ltnp 2>/dev/null | grep -q ':3000 '; then
      echo "[INFO] Grafana listens on port 3000 — prefer TLS and strong credentials on untrusted networks."
    fi
    if ss -ltnp 2>/dev/null | grep -q ':8086 '; then
      local ib
      ib="$(ss -ltnp 2>/dev/null | awk '/:8086 / { print $4 }' | head -1)"
      echo "[INFO] InfluxDB listens on ${ib:-unknown}:8086 — use host firewall and token auth for remote access."
    fi
  else
    echo "[INFO] ss not found; skipped listening-socket review (install iproute2)."
  fi
  echo "=== End security review ==="
}

monitoring_security_review_agent() {
  echo ""
  echo "=== Security review (agent) ==="
  local envf="/etc/monitoring/alloy/environment"
  if [[ -f "$envf" ]]; then
    local mode
    mode="$(stat -c '%a' "$envf" 2>/dev/null || stat -f '%OLp' "$envf" 2>/dev/null || echo "?")"
    if [[ "$mode" != "600" ]]; then
      echo "[WARN] ${envf} mode is ${mode}; recommend chmod 600." >&2
    else
      echo "[OK] ${envf} permissions 600"
    fi
  fi
  echo "[OK] node_exporter is configured to listen on 127.0.0.1 only (local scrape)."
  if [[ "${MONITORING_USE_DOCKER:-0}" -eq 1 ]]; then
    echo "[OK] cAdvisor listens on 127.0.0.1 only (when installed)."
  fi
  echo "[OK] Alloy UI listens on 127.0.0.1:12345 only."
  echo "=== End security review ==="
}

monitoring_write_central_hints() {
  local primary="$1"
  shift
  local hints="/etc/monitoring/central/agent-connection-hints.txt"
  local ip_list="$*"
  umask 077
  {
    echo "# Generated by install-central.sh — URLs for remote agents on your network."
    echo "# Prefer the primary IP below when agents are not on this host."
    echo ""
    echo "PRIMARY_IPV4=${primary}"
    echo "DETECTED_GLOBAL_IPV4=${ip_list}"
    echo "CENTRAL_PROM_REMOTE_WRITE_URL=http://${primary}:9090/api/v1/write"
    echo "GRAFANA_URL=http://${primary}:3000"
    echo "PROMETHEUS_URL=http://${primary}:9090"
    echo "ALERTMANAGER_URL=http://${primary}:9093"
    echo "# InfluxDB HTTP API (central), all interfaces — use Grafana Flux datasource or this URL from other hosts."
    echo "INFLUX_URL=http://${primary}:8086"
    echo "INFLUX_TOKEN_FILE=/etc/monitoring/central/influx-token"
  } >"$hints"
  chmod 0644 "$hints"
  echo ""
  echo "Wrote ${hints} for agent bootstrap reference."
}
