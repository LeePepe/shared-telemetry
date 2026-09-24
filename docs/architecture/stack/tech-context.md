---
layer: Stack
owns: [stack/**]
depends_on: []
red_lines:
  - Ports bind to 127.0.0.1 only.
  - Real credentials live in the gitignored stack/.env; only stack/.env.example is committed.
  - Grafana dashboards and provisioning are edited deliberately, one dashboard per PR.
---

# Stack

Docker Compose deployment of Loki and Grafana (`stack/docker-compose.yml`),
Loki config, Grafana datasource/dashboard provisioning and dashboards.
There is no automated gate: the stack needs Docker and is verified manually with
`docker compose -f stack/docker-compose.yml up -d` and `curl -s localhost:3100/ready`.
This leaf lives under `docs/architecture/` so the Grafana asset tree is unchanged.
