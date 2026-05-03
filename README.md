# Prometheus monitoring — central control plane + edge agents

This repo provides a **two-tier** Prometheus setup for **Linux VMs or bare metal** using **systemd** and official release binaries (no Docker Compose, no containers required for the monitoring stack itself).

- **Central node**: Prometheus (remote-write ingest), Grafana (UI), Alertmanager, **InfluxDB 2** (time-oriented metrics and probes), and **Telegraf** (e.g. ping / HTTP checks → Influx) as `systemd` units.
- **Edge agents**: `node_exporter`, optional **cAdvisor** (when the Docker engine is present), and **Grafana Alloy** forwarding metrics to central via **remote write**.

Agents open an **outbound** connection to `http://<central>:9090/api/v1/write`, so you do not need the central host to scrape every private IP or Docker socket on worker machines.

## Requirements

- Linux with **systemd** (typical on RHEL, Ubuntu, Debian, etc.).
- **root** (or `sudo`) for installation.
- **curl**, **tar**, and **python3** (central installer: InfluxDB 2 setup API + provisioning); **unzip** (`unzip` is required on agents for the Alloy zip release).
- Open **9090** (Prometheus), **3000** (Grafana), **9093** (Alertmanager), and **8086** (InfluxDB) on the central host as appropriate (usually only on a private or management network). These services **listen on 0.0.0.0** (all interfaces) unless noted otherwise in `systemd`/config. **Edge agents** keep exporters on loopback where configured (Alloy still remote-writes outbound to central).

Optional: **jq** if you prefer it for community dashboard JSON (otherwise **python3**); **gettext** (`envsubst`) to render the Grafana Influx datasource file (the installer falls back to Python if `envsubst` is missing).

## Quick install — central

From the repository root on the central server:

```bash
chmod +x scripts/install-central.sh
sudo ./scripts/install-central.sh
```

Recommended one-liner:

```bash
git clone "${REPO_URL}" monitoring && cd monitoring && sudo ./scripts/install-central.sh
```

The installer downloads optional community dashboards (**1860** Node Exporter Full, **193** Docker) when missing, **always installs** the bundled **[Monitoring · Fleet overview](deploy/central/grafana/dashboards/monitoring-fleet-overview.json)** (hero layout: fleet stats, smooth time series, CPU/memory/disk, optional cAdvisor row) and **[Monitoring · Network (Influx / Telegraf)](deploy/central/grafana/dashboards/monitoring-network-influx.json)** (when Flux + Telegraf data is present), and sets fleet overview as the **default home dashboard** plus **dark theme** in [`deploy/central/grafana/grafana.ini`](deploy/central/grafana/grafana.ini).

At the end it runs **health checks** (Prometheus `/ready`, Alertmanager, Grafana, **InfluxDB `/health`**, **Telegraf active**) and a short **security review** (Grafana env permissions, weak default password, listening sockets, Influx token file mode). The script exits non-zero if a critical health check fails.

InfluxDB org/bucket/retention and the initial admin password are read from **`/etc/monitoring/central/influx.env`** (seeded from [`deploy/central/influx.env.example`](deploy/central/influx.env.example)). A long-lived API token is written to **`/etc/monitoring/central/influx-token`** (mode `600`); Telegraf and the Grafana Flux datasource use it.

Grafana admin credentials come from **`/etc/monitoring/central/grafana.env`** (seeded from [`deploy/central/grafana.env.example`](deploy/central/grafana.env.example)). Change **`GF_SECURITY_ADMIN_PASSWORD`** before production.

It **detects this server’s IPv4** (`ip route` / `hostname -I`), prints service URLs using the **primary** address, and writes **`/etc/monitoring/central/agent-connection-hints.txt`** (URLs, `CENTRAL_PROM_REMOTE_WRITE_URL`, and Influx notes) so agents on the same machine or operators on the LAN can copy the correct value.

On each monitored host:

```bash
# optional: same host as central — URL can be omitted (see auto-detection below)
# export CENTRAL_PROM_REMOTE_WRITE_URL='http://10.0.0.10:9090/api/v1/write'
# optional: export AGENT_HOSTNAME='web-01.prod.example'  # default: primary IPv4, else FQDN/hostname
# optional: export AGENT_SKIP_DOCKER=1                   # node_exporter + Alloy only
# optional: export LOCAL_PROM_WAIT_TRIES=15              # retries waiting for local Prometheus /-/ready when URL is omitted
chmod +x scripts/install-agent.sh
sudo -E ./scripts/install-agent.sh
```

If **`CENTRAL_PROM_REMOTE_WRITE_URL` is unset**, the agent installer tries, in order:

1. **`/etc/monitoring/central/agent-connection-hints.txt`** on the **same host** (after you ran the central installer there), or  
2. **Local Prometheus** at `127.0.0.1:9090` (waits for `/-/ready`, up to `LOCAL_PROM_WAIT_TRIES` × ~2s), using `http://127.0.0.1:9090/api/v1/write`.

If none apply, it prints an error and the **detected primary IPv4** so you can build `http://<central-ip>:9090/api/v1/write` for remote agents.

It then runs **health checks** (node_exporter metrics, Alloy HTTP) and a short **security review**, and exits non-zero if a critical check fails.

Example one-liner (remote central):

```bash
git clone "${REPO_URL}" monitoring && cd monitoring && \
  CENTRAL_PROM_REMOTE_WRITE_URL='http://10.0.0.10:9090/api/v1/write' \
  sudo -E ./scripts/install-agent.sh
```

Example on **the same VM as central** (after `install-central.sh`), without exporting the URL:

```bash
sudo ./scripts/install-agent.sh
```

### Docker engine detection

- If **`/var/run/docker.sock`** exists and **`AGENT_SKIP_DOCKER` is not `1`**, the installer deploys **cAdvisor**, uses the full [`deploy/agent/config.alloy`](deploy/agent/config.alloy) (Docker label discovery + app `/metrics`), and adds **`alloy`** to the **`docker`** group when that group exists (so Alloy can read the socket).
- Otherwise it installs [`deploy/agent/config.no-docker.alloy`](deploy/agent/config.no-docker.alloy) (host **node_exporter** only).

## Docker workloads (optional)

`cAdvisor` reports container resource usage for engines it can talk to. You do **not** need Compose for your own apps.

### Opt-in application `/metrics` (Prometheus format)

When the Docker path is enabled, Alloy discovers scrape targets from container labels (dots in names are normalized per [discovery.docker](https://grafana.com/docs/alloy/latest/reference/components/discovery/discovery.docker/)):

```yaml
labels:
  - prometheus.scrape=true
  - prometheus.port=8080
  - prometheus.path=/metrics   # optional; default /metrics
```

Example for an app you run under Docker: [`examples/labeled-service.compose.yaml`](examples/labeled-service.compose.yaml) (this file only illustrates **application** labels, not the monitoring installers).

Metrics include **`agent_host`** (`external_labels` in Alloy), defaulting to **primary IPv4** when available, otherwise the host’s FQDN / short name.

## Post-install checks and security review

Both installers print a **Health checks** block (HTTP endpoints and systemd) and a **Security review** block (warnings only on the agent; on central, weak Grafana password and wide-bound Prometheus port are called out). Failures in critical health checks cause a **non-zero exit**.

Shared helpers live in [`scripts/lib/monitoring-common.sh`](scripts/lib/monitoring-common.sh).

Runtime environment for Alloy is **`/etc/monitoring/alloy/environment`** (see [`deploy/agent/alloy-environment.example`](deploy/agent/alloy-environment.example)). Alloy’s debug UI listens on **127.0.0.1:12345** only.

## Native (non-container) applications

There is **no universal, safe auto-discovery** of arbitrary processes exposing `/metrics`. You still get **node_exporter** everywhere. For app metrics, add instrumentation, **static** Alloy scrape jobs in `config.alloy` / `config.no-docker.alloy`, or exporters such as blackbox or process-exporter, wired as extra **systemd** services alongside the agent stack.

## Layout

| Path | Purpose |
|------|--------|
| [`deploy/central/prometheus/`](deploy/central/prometheus/) | Prometheus config and rule files (installed to `/etc/monitoring/prometheus/`) |
| [`deploy/central/alertmanager/`](deploy/central/alertmanager/) | Alertmanager config |
| [`deploy/central/grafana/`](deploy/central/grafana/) | `grafana.ini` (dark theme + default home dashboard), provisioning |
| [`deploy/central/grafana/dashboards/`](deploy/central/grafana/dashboards/) | Bundled **Monitoring · Fleet overview**; optional downloaded dashboards on the server |
| [`deploy/central/systemd/`](deploy/central/systemd/) | Unit files for central services |
| [`deploy/agent/config.alloy`](deploy/agent/config.alloy) | Full agent (host + optional Docker app discovery + cAdvisor) |
| [`deploy/agent/config.no-docker.alloy`](deploy/agent/config.no-docker.alloy) | Agent without Docker engine |
| [`deploy/agent/systemd/`](deploy/agent/systemd/) | Unit files for agents |
| [`scripts/lib/monitoring-common.sh`](scripts/lib/monitoring-common.sh) | IP detection, health checks, security review, agent URL bootstrap |
| [`scripts/install-central.sh`](scripts/install-central.sh) | Central bootstrap (binaries + systemd) |
| [`scripts/install-agent.sh`](scripts/install-agent.sh) | Agent bootstrap (binaries + systemd) |

## Firewall and security

- Prefer private networking. Agents need **outbound** TCP to the central Prometheus **9090** (remote write).
- Remote write is **unauthenticated** in this baseline; in untrusted networks use a reverse proxy with auth/TLS or mTLS.
- Put Grafana behind **TLS** and strong credentials (see `grafana.env`).

## Scaling beyond a single Prometheus

Many agents can **remote_write** to one Prometheus. When a single instance becomes the bottleneck, add **Grafana Mimir** or **VictoriaMetrics**, point agents at that write endpoint, and add a Grafana datasource—agents and label conventions can stay the same.

## Troubleshooting

- **Grafana empty**: confirm `GF_SECURITY_ADMIN_*` in `/etc/monitoring/central/grafana.env` and that Prometheus is up (`systemctl status prometheus`).
- **No agent metrics**: verify `CENTRAL_PROM_REMOTE_WRITE_URL` from the agent host (`curl -g …` if needed) and `journalctl -u alloy -u node_exporter`.
- **Docker apps not scraped**: confirm labels and that Alloy is in the `docker` group when using socket discovery.
