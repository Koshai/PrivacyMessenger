# Hosted resource budget

Target host: OVHcloud VPS-1 class, 2 vCPU, 4 GB RAM, 40 GB NVMe, advertised network up to 500 Mbps. Advertised bandwidth is not a measured throughput. No number below was collected on that VPS unless a later results note says so.

## Planning allowances

These are the milestone planning numbers. They are not measurements and they are not container limits.

| Component | Planning allowance |
| --- | ---: |
| Go API | 300 MB |
| PostgreSQL | 600 MB |
| coturn | 150 MB |
| Caddy | 100 MB |
| Ubuntu, Docker, and system services | 700 MB |
| Cache, spikes, and headroom | 2150 MB |
| Total | 4000 MB |

## Container ceilings

`deploy/compose.validation.yml` sets these so a runaway process is more likely to hit its own ceiling than to consume the host without a trace. They are above the planning allowances. They are still not measured working sets.

| Service | Ceiling |
| --- | ---: |
| API | 512 MB |
| PostgreSQL | 1 GB |
| coturn | 256 MB |
| Caddy | 128 MB |

Sum of ceilings is about 1.9 GB, which leaves room for the operating system inside 4 GB. Do not lower a ceiling before a hosted measurement. If a container is OOM-killed, raise that ceiling, record the new measurement, and only then decide whether the VPS size is the bottleneck.

PostgreSQL `shm_size` is 512 MB so `shared_buffers=256MB` can allocate. Docker's default shared memory is 64 MB and is too small for that setting.

## Database

| Setting | Value | Why this starting point |
| --- | --- | --- |
| `shared_buffers` | 256 MB | Small cache on a 4 GB host |
| `effective_cache_size` | 1 GB | Planner hint, not an allocation |
| `work_mem` | 4 MB | `max_connections` times this stays modest |
| `maintenance_work_mem` | 64 MB | Migrations and vacuum |
| `max_connections` | 30 | One API pool plus maintenance |
| API `pool_max_conns` | 8 | Set in `DATABASE_URL` |

On 2 vCPU, an unset pgx pool would be about 4 connections. The URL sets 8 so the cap is explicit.

## Disk

Planning layout, not partitions:

| Use | Plan |
| --- | ---: |
| OS and packages | 6 GB |
| Images and containers | 5 GB |
| PostgreSQL data and WAL | 10 GB |
| Logs and temporary files | 3 GB |
| Free reserve | 16 GB |

Logs are rotated at 10 MB with 3 files per container. Prune unused images. Do not prune volumes as a cleanup step.

## Network

The relay range 49160-49260 is about 100 UDP ports. That is enough for a small number of validation calls, not for a large conference. Each call can use more than one allocation. Widen the range and the firewall together if a test shows allocation failure while CPU and RAM are fine.

Do not treat 500 Mbps as available media capacity. Measure a call before claiming headroom.

## Capacity decision

Not decided. The decision requires the workload in `docs/HOSTED_INTEGRATION_TEST_MATRIX.md` on the real VPS.

| Outcome | When to use it |
| --- | --- |
| PASS | The two-client encrypted conversation plus audio and video setup/teardown stays inside the warning lines below with no unexplained errors |
| PASS WITH LIMITATIONS | The workload completes and a measured limit is written down |
| FAIL | The workload is unreliable. Name the bottleneck before any upgrade |

Warning lines, not universal requirements: peak RAM under about 3.2 GB, disk under about 70 percent, no OOM kill, no unexpected container restart, no unexplained PostgreSQL error, API health stable, TURN relay verified from outside the host, CPU not saturated for the whole call.

## Local measurements

Taken on the developer workstation on 2026-11-05. They are not VPS measurements and they are not a capacity decision.

| Item | Measured |
| --- | --- |
| Validation API container, idle, after a successful health response | 7.07 MiB, CPU 0.00 percent, ceiling 512 MiB |
| Validation PostgreSQL 17.6 container, idle, after all 10 migrations | 58.97 MiB, CPU 0.00 percent, ceiling 1 GiB |
| Existing local `postgres:17` container, untuned, idle | 27.03 MiB |
| Existing local API process on port 4010, idle | 22 MB resident |
| API image `privacymessenger-api:validation` | 91.8 MiB |
| `postgres:17.6` image | 432.3 MiB |
| Validation Postgres first start until healthy, including role init | 16.6 seconds |
| Applying migrations `000001` through `000010` | 2.2 seconds. The second run skipped all 10 |

The idle container figures are far under the ceilings. That does not predict call or checkpoint load on the VPS. Caddy and coturn were not started, so they have no measurement.
