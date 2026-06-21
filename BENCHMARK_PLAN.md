# Auto-indexer eviction benchmark — runbook

Goal: quantify the eviction win under **workload drift + a tight cap**. Baseline (eviction off)
vs patched (eviction on). The win: after the hot set shifts, baseline stays frozen at the cap with
dead indexes and the new hot set's P99 stays high; patched evicts the cold indexes, indexes the new
hot set, and its P99 drops.

## Automated path: `bench/run.sh`

One command does everything below: `GRPC_ENDPOINT=... GRPC_TOKEN=... ./bench/run.sh` (its header
documents the env knobs — `INGEST_PROGRAMS`, `INGEST_SECS`, `CAP`, `THRESHOLD`, `RPS`, `PHASE_SECS`).
It ingests via gRPC, derives the P1/P2 workload from the real ingested data, runs baseline then
patched, and writes P99 + index bytes to `bench/results/` plus a printed summary. The manual steps
below are the reference for what it automates.

## Components (all already in the repo)

| Role | Binary | Config |
| --- | --- | --- |
| Schema | `cloudbreak-migration` | `cloudbreak.migration.toml` |
| Representative data | `cloudbreak ... snapshot` | `example.cloudbreak.snapshot.toml` |
| Serve GPA + feed tracker | `cloudbreak ... api` | `example.cloudbreak.api-with-query-tracker-client.toml` |
| Build/evict indexes | `cloudbreak ... query-tracker` | `example.cloudbreak.query-tracker.toml` |
| Load generator + P99 | `integration_tests benchmark gpa` | `example.cloudbreak.integration_tests.toml` |
| Measure index count/bytes | `cloudbreak-dbtools analytics` | `example.cloudbreak.dbtools.toml` |

## The data dependency (the one external input)

GPA latency only means something if `accounts` holds representative rows. The chosen path is a
**live Yellowstone gRPC stream** (e.g. Helius LaserStream, Triton) feeding the indexer — real
on-chain data, the project's normal ingestion path, no snapshot/synthetic.

Build an `index.toml` from `example.cloudbreak.index.toml`:
- `[grpc] endpoint`, `x-token` → the provider's Yellowstone/Dragon's-Mouth URL + token.
- `[programs] include = [...]` → the P1 and P2 program owners you'll benchmark (the indexer writes
  only accounts owned by these). Pick **active** programs so the working set fills fast.
- **Omit the `[snapshot]` section** → pure-stream ingestion (no tracker/snapshot needed). Note this
  leaves `snapshot_accounts` empty, which is fine: the eviction win is measured on `accounts`.
- `[database]` → the local docker Postgres.

```sh
cargo run -p cloudbreak --bin cloudbreak -- --config index.toml index   # ingest...
# let it accumulate a working set (minutes–hours, depending on program activity), then STOP it
# so the dataset is static during the benchmark.
```

Caveats: Yellowstone gRPC is a **paid** provider feature; the stream is a **live delta** (not
history) so choose active programs and run long enough; **stop ingestion before benchmarking** so
the dataset doesn't shift mid-run.

(If no gRPC access is available, a snapshot via `cloudbreak --config snapshot.toml snapshot` through
the `solana-tracker` compose service is the alternative, or a synthetic `INSERT ... generate_series`
bulk load for directional-only numbers.)

## Two-variant isolation

Indexes live in the DB, so baseline and patched must not share index state. Two ways:

- **Rigorous (side-by-side P99):** two databases (`cloudbreak_baseline`, `cloudbreak_patched`),
  each with its own API + query-tracker. API baseline → `:4000`, API patched → `:4001`.
  `integration_tests` runs `rpc1=:4000`, `rpc2=:4001` → one run, directly comparable histograms.
- **Simpler (sequential):** one DB. Run the whole drift workload against baseline, record numbers,
  `migrate fresh` + reload data, flip to the patched config, rerun, compare. Single endpoint each.

Both query-tracker configs share: `create-database-indexes = true`, a **low**
`index-generation-threshold` (e.g. 3, so indexes form fast under load), a **tight**
`max-auto-indexes` (e.g. 5). They differ only in:
- baseline: `index-eviction-enabled = false`
- patched: `index-eviction-enabled = true`, and short windows for a fast run, e.g.
  `index-eviction-interval = "30s"`, `index-min-idle = "60s"`, `index-min-age-grace = "30s"`.

## Workload: two disjoint request pools

`pool_p1.json` and `pool_p2.json`, in the `gpa_benchmark_requests.json` format — each an array of
`getProgramAccounts` requests whose `params[0]` programs are **disjoint** between the two files, and
whose filters (`memcmp`/`dataSize`) are indexable patterns. P1 programs drive phase A; P2 phase B.

## Procedure

```sh
# 0. infra
docker compose up -d postgres            # (+ solana-tracker if using a real snapshot)
export DATABASE_URL=postgres://cloudbreak:cloudbreak@localhost:5432/cloudbreak
export CLOUDBREAK_MIGRATION_CONFIG=./cloudbreak.migration.toml
cargo run -p cloudbreak-migration -- up

# 1. load representative data via the live gRPC stream (Helius/Triton), then stop the indexer
cargo run -p cloudbreak --bin cloudbreak -- --config index.toml index   # Ctrl+C once enough data

# 2. start the stack (baseline variant shown; patched = its own config/db/ports)
cargo run -p cloudbreak --bin cloudbreak -- --config api.toml api &
cargo run -p cloudbreak --bin cloudbreak -- --config qt-baseline.toml query-tracker &

# 3. PHASE A — hammer P1 (source.path = pool_p1.json), let indexes build to the cap
cargo run -p integration_tests -- benchmark gpa -c bench.toml
cargo run -p cloudbreak-dbtools -- --config dbtools.toml analytics indexes-count
cargo run -p cloudbreak-dbtools -- --config dbtools.toml analytics indexes-sizes

# 4. PHASE B — switch to P2 (source.path = pool_p2.json), run long enough for the
#    patched instance's eviction interval to free room and index P2
cargo run -p integration_tests -- benchmark gpa -c bench.toml
cargo run -p cloudbreak-dbtools -- --config dbtools.toml analytics indexes-count
cargo run -p cloudbreak-dbtools -- --config dbtools.toml analytics indexes-sizes
```

(`benchmark gpa` prints avg/P50/P90/P99 per endpoint, size, and encoding.)

## Result table (the PR evidence)

| Phase | Variant | P99 | auto-index count | auto-index bytes |
| --- | --- | --- | --- | --- |
| A (P1) | baseline | … | at cap | … |
| A (P1) | patched | … | at cap | … |
| B (P2) | **baseline** | **high** (frozen) | at cap, dead P1 idx | pinned |
| B (P2) | **patched** | **drops** | P1 evicted, P2 built | tracks live set |

Win = patched B-phase P99 ≪ baseline B-phase P99, and patched bytes bounded near the live working
set vs baseline pinned at the cap with cold P1 indexes.

## What I need to actually run it
- A Yellowstone gRPC endpoint + token (Helius LaserStream / Triton / etc. — a paid feature).
- Disk/RAM for the ingested working set.
- That's the only external input — every other piece (configs, pools, commands) is above and
  reproducible on the local docker stack.

## Reporting on the PR / issue

Add a short **Benchmark** section with:
- **Methodology:** real data via a Yellowstone gRPC stream (provider, programs P1/P2, ~N accounts
  ingested over T minutes), tight `max-auto-indexes`, baseline (eviction off) vs patched (on).
- **The result table** above, filled in.
- **Evidence:** paste the `integration_tests benchmark gpa` per-endpoint histogram and the
  `dbtools analytics indexes-count/-sizes` output for each phase.

Frame the headline as the relative win — patched B-phase P99 ≪ baseline, patched index bytes bounded
vs baseline pinned at the cap with cold indexes — which holds regardless of absolute latencies.

## Note: the cost-aware (PR #1) experiment reuses this harness
Same stack; instead of drift, mix a frequent-cheap program with a rare-expensive one under a tight
cap and compare the rare-expensive program's P99 with `cost-weighting` off vs on. Separate result,
same tooling.
