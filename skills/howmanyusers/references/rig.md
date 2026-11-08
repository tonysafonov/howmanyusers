# The rig: two boxes in one datacenter

A number is only as good as the rig behind it. The shape that works, borrowed from Arjay McCandless's server
challenges: **one target box** that runs the stand (app + database + cache + stubs) and **one load generator** in the
same datacenter. Never the laptop (you'd measure your home uplink and the laptop's own CPU) and never k6 on the target
(it steals the CPU you're measuring).

## Sizing

| Role | What | Why |
|---|---|---|
| target | the production size, or the size you want to quote (2 **dedicated** vCPU is a good "cheap server" headline), RAM as prod, Ubuntu LTS | dedicated cores: shared vCPUs drift with the neighbours (check steal time in `preflight.sh`) |
| loader | 4+ vCPU, shared is fine | k6 needs ~1 core per few thousand VUs with think times; keep it under ~50 % CPU (check during the first staircase) |

Note the CPU model (`lscpu`) in the report: Arjay's boxes and ours were the same Xeon Platinum 8260, which is what
made a per-core comparison with his published numbers meaningful.

Same region, ideally the same datacenter: RTT loader → target should be ~0.2–0.5 ms. At 20 ms you are measuring the
network, and every p95 shifts by it. `preflight.sh` pings it.

## Setup checklist (both boxes)

```bash
# loader
apt-get update && apt-get install -y ca-certificates gnupg rsync
# k6: follow https://grafana.com/docs/k6/latest/set-up/install-k6/ (apt repo or a static binary)
ulimit -n 1048576                                      # k6 holds one socket per VU at least
sysctl -w net.ipv4.ip_local_port_range="1024 65535"    # connection churn runs out of ephemeral ports otherwise

# target
curl -fsSL https://get.docker.com | sh
apt-get update && apt-get install -y python3-venv   # stock Ubuntu ships without ensurepip
python3 -m venv /opt/pyspy && /opt/pyspy/bin/pip install py-spy   # PYSPY=/opt/pyspy/bin/py-spy
ufw allow OpenSSH && ufw allow from <loader-ip> to any port 8000 && ufw enable
```

- **Docker-published ports bypass ufw.** `ports: ["5432:5432"]` opens the database to the internet whatever ufw
  says. Publish only the app port, bind the rest to `127.0.0.1` or don't publish them; use the provider's cloud
  firewall if it has one. Check from outside: `nc -vz -w 5 <target> 5432` must fail. Check your production compose files
  for the same mistake while you're at it.
- **Disk:** a 20 GB root fills with images after a dozen variant builds. Build fix variants as a thin layer over
  the base image (`FROM app:base` + `COPY` of the changed files), `docker image prune -a` between sessions, and let
  `preflight.sh` warn you at 75 %.
- **Clean state between sessions:** the provider's reinstall/rebuild call gives a fresh OS in minutes. Prefer it to
  hand-cleaning when a session is over or the box has been under days of holds (a long-running stand measured 2× the
  per-request CPU of a fresh one with a different pool config: see pitfalls).
- SSH with keys, `BatchMode=yes` (the scripts use it), no passwords anywhere in the repo.

## Provider recipe (optional): Synteq via its API

Any provider works (Hetzner, DigitalOcean, Vultr, OVH...). We used [Synteq](https://synteq.com), Arjay's sponsor at
the time (his videos carried a credit link), because his challenges are scored on their boxes and the same CPU
makes the comparison fair. Ordering went through their REST API with an API key, which lets an agent do it, **with
the owner's explicit OK for each order: it spends money.** Verify every field against their current API docs
(an OpenAPI spec is linked from the dashboard); this is what worked in late 2026:

- Auth: `X-API-Key: sk_…` header. Keep the key in a file outside the repo (`chmod 600`), read it per call, never
  print it. A key scoped to one project limits the blast radius.
- `GET /orders/catalog` → locations, images, plans. `POST /orders/preview` with the spec → the price before paying.
- `POST /orders` with `{"kind": "virtualized", "billing_cycle": "monthly", "spec": {...}, "payment": {"method":
  "credit_only", "apply_credits": true}}`. The spec picks exactly one sizing mode: a `plan_id`, **or**
  `custom_cpu_cores` + `custom_ram_gb` + `custom_disk_gb` (+ `custom_dedicated: true` for dedicated cores), **or** a
  tier; plus `bandwidth_tb`, `location_id`, `image_id`, `hostname`, an SSH public key. `credit_only` spends account
  credit and fails rather than charging a card.
- `GET /resources/vps` → IPs and state. Power and reinstall calls exist for a clean OS between runs.
- Billing was **monthly only** (no hourly). Cancelling takes effect at the end of the paid period, so schedule the
  cancellation as soon as the boxes are up and you know how long you need them.

Our pair: target 2 dedicated vCPU / 4 GB, loader 4 shared vCPU / 4 GB, same datacenter, ~$17/month together, RTT
0.21 ms.

## Environment the scripts expect

```bash
export TARGET=root@<target-ip> LOADER=root@<loader-ip> CONTAINER=<app container on target>
export BASE_URL=http://<target-private-or-public-ip>:8000      # as the loader sees it
export K6_SRC=./perf/k6 K6_DIR=/root/perf-k6 PYSPY=/opt/pyspy/bin/py-spy
export RESET_CMD='cd /opt/stand && docker compose exec -T db psql -U app -d app -c "update quotas set used = 0"'
```

Keep these in an untracked `perf/rig.env` and `source` it; IPs and keys don't belong in the repo.
