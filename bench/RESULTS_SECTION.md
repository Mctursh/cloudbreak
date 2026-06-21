<!--
Drop this into the PR #2 description once `bench/run.sh` has produced numbers.
Replace every <FILL ...>. Keep the methodology/reproduce/caveats — that is what makes it credible.
-->

## Benchmark

Measured with the repo's own tooling: `integration_tests benchmark gpa` for latency and
`cloudbreak-dbtools analytics indexes-count/-sizes` for index storage. Baseline (eviction off) and
patched (eviction on) ran on the **identical** ingested dataset and workload, on the same machine;
the only thing that differs between the two runs is `index-eviction-enabled`.

### Setup
- **Data:** live Yellowstone gRPC stream (<FILL: provider>), ingesting programs <FILL: P1 ids> and
  <FILL: P2 ids>; <FILL: N> accounts over <FILL: T> minutes.
- **Env:** Postgres 16 (the repo's `docker-compose.yaml`), <FILL: CPU / RAM / OS>.
- **Knobs:** `max-auto-indexes = <FILL>`, `index-generation-threshold = <FILL>`, eviction
  interval/min-idle/min-age-grace = <FILL>, load = <FILL> rps for <FILL> s per phase.
- **Experiment (workload drift):** Phase A hammers program set **P1** until indexes build to the
  cap; Phase B switches to a disjoint set **P2**.

### Results

| Phase | Variant | GPA P99 | auto-index count | auto-index bytes |
| --- | --- | --- | --- | --- |
| A (P1) | baseline | <FILL> | <FILL> | <FILL> |
| A (P1) | patched  | <FILL> | <FILL> | <FILL> |
| B (P2) | **baseline** | <FILL> (cap frozen by cold P1 indexes) | <FILL> | <FILL> |
| B (P2) | **patched**  | <FILL> | <FILL> | <FILL> |

**Takeaway:** <FILL: e.g. "with eviction off, P2's P99 stays at X ms because the cap is frozen by
idle P1 indexes; with eviction on, the cold P1 indexes are reclaimed, P2 gets indexed, and its P99
drops to Y ms. Index bytes stay bounded near the live working set instead of pinned at the cap.">

<details>
<summary>Raw tool output</summary>

```
# baseline — phase B (P2) — integration_tests SUMMARY
<FILL: paste>

# patched — phase B (P2) — integration_tests SUMMARY
<FILL: paste>

# dbtools analytics indexes-count / indexes-sizes, per phase/variant
<FILL: paste>
```
</details>

### Reproduce
Baseline and patched differ only by the eviction toggle; the harness ingests, derives the P1/P2
workload from the real data, runs both variants, and captures the numbers:

```sh
GRPC_ENDPOINT="<your-yellowstone-grpc>" GRPC_TOKEN="<token>" ./bench/run.sh
```

Script + full runbook: <FILL: link to the branch/gist with `bench/run.sh` and `BENCHMARK_PLAN.md`>.
Happy to re-run it against your own snapshot/infra.

### Caveats
- <FILL: single run / median of N runs>. Phase B's P99 is **blended** (slow before eviction frees
  the cap, fast after), so it *understates* the steady-state win; a longer `PHASE_SECS` sharpens it.
- Absolute latencies are machine-dependent; the result is the **relative** baseline-vs-patched delta
  on an identical dataset, which is what the eviction change is responsible for.
