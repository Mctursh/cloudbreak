#!/usr/bin/env bash
#
# Auto-indexer eviction benchmark pipeline.
#
# You supply a Yellowstone gRPC endpoint (Helius LaserStream / Triton / ...); this script ingests
# real account data, derives a GPA workload from it, and runs the drift + tight-cap experiment for
# BASELINE (eviction off) vs PATCHED (eviction on), capturing P99 and index bytes per phase.
#
# Usage:
#   GRPC_ENDPOINT="https://<your-yellowstone-grpc>" GRPC_TOKEN="<token>" ./bench/run.sh
#
# Knobs (env vars, with defaults):
#   GRPC_ENDPOINT   (required) Yellowstone gRPC URL
#   GRPC_TOKEN      ("")        x-token for the endpoint
#   INGEST_PROGRAMS ("...")     comma-separated base58 program owners to ingest (pick ACTIVE ones)
#   INGEST_SECS     (600)       how long to ingest before benchmarking
#   CAP             (auto)      max-auto-indexes; blank = set to the #P1 patterns so the cap is
#                               exactly full after phase A (that is what makes baseline freeze)
#   THRESHOLD       (3)         index-generation-threshold (low so indexes form fast under load)
#   RPS             (10)        benchmark target requests/sec
#   PHASE_SECS      (180)       duration of each benchmark phase (B must be long enough for the
#                               patched run to evict idle P1 indexes and then index P2)
#
# NOTE: the gRPC-ingest stage is the one part not exercisable without a live endpoint; everything
# else (stack startup, workload derivation, benchmark, measurement) is local.

set -euo pipefail
cd "$(dirname "$0")/.."

# ---- knobs -------------------------------------------------------------------------------------
: "${GRPC_ENDPOINT:?Set GRPC_ENDPOINT to your Yellowstone gRPC URL}"
GRPC_TOKEN="${GRPC_TOKEN:-}"
INGEST_PROGRAMS="${INGEST_PROGRAMS:-675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8,whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc}"
INGEST_SECS="${INGEST_SECS:-600}"
CAP="${CAP:-}"   # blank = auto (set to the number of P1 patterns after the workload is derived)
THRESHOLD="${THRESHOLD:-3}"
RPS="${RPS:-10}"
PHASE_SECS="${PHASE_SECS:-180}"

DB_URL="postgres://cloudbreak:cloudbreak@localhost:5432/cloudbreak"
GEN="bench/gen"; RES="bench/results"
mkdir -p "$GEN" "$RES"
PSQL() { docker compose exec -T postgres psql -U cloudbreak -d cloudbreak "$@"; }
CB="./target/release/cloudbreak"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

# ---- 0. build + infra --------------------------------------------------------------------------
echo "==> building release binaries (cloudbreak, dbtools, integration_tests)"
cargo build --release -p cloudbreak --bin cloudbreak
cargo build --release -p cloudbreak-dbtools -p integration_tests -p cloudbreak-migration

echo "==> starting Postgres"
docker compose up -d postgres
until PSQL -c 'select 1' >/dev/null 2>&1; do sleep 1; done

# build the program-include TOML array
INC=$(printf '"%s",' ${INGEST_PROGRAMS//,/ }); INC="[${INC%,}]"

# ---- config generation -------------------------------------------------------------------------
cat > "$GEN/migration.toml" <<EOF
[pg-owner-partitions]
hash-partitions = true
hash-partition-count = 10
list-partitions = false
programs-for-list-partition = []
EOF

cat > "$GEN/index.toml" <<EOF
finalize-slot-buffer-size = 1000
accounts-owner-map-enabled = false
[database]
url = "$DB_URL"
[grpc]
endpoint = "$GRPC_ENDPOINT"
x-token = "$GRPC_TOKEN"
timeout = 60
chunk-size = 1000
max-chunk-bytes-data = 2097152
max-grpc-errors = 1
channel-size = 1000
[metrics]
host = "0.0.0.0"
port = 8875
[programs]
include = $INC
EOF

cat > "$GEN/api.toml" <<EOF
[server]
host = "0.0.0.0"
port = 4000
max-connections = 100
[database]
url = "$DB_URL"
[metrics]
host = "0.0.0.0"
port = 8878
[query-tracker-client]
endpoint = "http://localhost:4001"
timeout = "5s"
flush-interval = "5s"
[tracing]
enabled = false
[slot-syncronizer]
enabled = false
interval_ms = 200
EOF

gen_qt() { # $1 = name, $2 = eviction-enabled (true|false)
  cat > "$GEN/qt_$1.toml" <<EOF
[server]
host = "0.0.0.0"
port = 4001
max-connections = 100
[database]
url = "$DB_URL"
[metrics]
host = "0.0.0.0"
port = 8876
[query-tracker]
create-database-indexes = true
index-generation-threshold = $THRESHOLD
index-creation-delay = "2s"
query-counts-reset-interval = "24h"
included-programs = []
excluded-programs = ["TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"]
indexer-metrics = "localhost:8875"
indexer-metrics-threshold = 1000000
max-auto-indexes = $CAP
index-eviction-enabled = $2
index-eviction-interval = "10s"
index-min-idle = "20s"
index-min-age-grace = "10s"
EOF
}

cat > "$GEN/dbtools.toml" <<EOF
[[servers]]
name = "local"
database_url = "$DB_URL"
EOF

gen_bench() { # $1 = phase (p1|p2)
  cat > "$GEN/bench_$1.toml" <<EOF
[rpc1]
url = "http://localhost:4000"
name = "cloudbreak"
[rpc2]
url = "http://localhost:4000"
name = "unused"
[benchmark]
target_rps = $RPS
max_in_flight = 100
duration_secs = $PHASE_SECS
timeout_secs = 60
[source]
type = "json_file"
path = "$GEN/pool_$1.json"
# No [comparison] section on purpose: that selects the one-sided path in
# process_request (send to rpc1 and record latency). With [comparison] present,
# ratio gates BOTH endpoints, so ratio=0.0 would send nothing at all.
[print_config]
min_request_bytes = 0
min_request_duration_ms = 0
min_request_account_count = 0
EOF
}

# ---- migrate -----------------------------------------------------------------------------------
echo "==> applying migrations"
CLOUDBREAK_MIGRATION_CONFIG="$GEN/migration.toml" DATABASE_URL="$DB_URL" \
  cargo run --release -q -p cloudbreak-migration -- up

# ---- 1. ingest real data via gRPC --------------------------------------------------------------
echo "==> ingesting from gRPC for ${INGEST_SECS}s (programs: $INGEST_PROGRAMS)"
"$CB" --config "$GEN/index.toml" index > "$RES/indexer.log" 2>&1 &
INDEXER_PID=$!; PIDS+=("$INDEXER_PID")
sleep "$INGEST_SECS"
echo "==> ingest window done; indexer keeps running (the tracker needs its metrics endpoint)"
PSQL -tAc "SELECT 'accounts rows: '||count(*)||', distinct owners: '||count(distinct owner) FROM accounts"

# ---- 2. derive a P1/P2 workload from the actual ingested data ----------------------------------
echo "==> deriving workload from ingested data"
# (while-read, not mapfile — macOS default bash is 3.2)
ROWS=()
while IFS= read -r line; do [ -n "$line" ] && ROWS+=("$line"); done < <(PSQL -tA -F'|' -c "
  WITH ranked AS (
    SELECT owner, length(data) AS sz, count(*) AS c,
           row_number() OVER (PARTITION BY owner ORDER BY count(*) DESC) AS rn
    FROM accounts GROUP BY owner, length(data))
  SELECT bs58_encode(owner), sz FROM ranked WHERE rn = 1 AND sz > 0
  ORDER BY (SELECT count(*) FROM accounts a WHERE a.owner = ranked.owner) DESC LIMIT 8;")

[ "${#ROWS[@]}" -lt 2 ] && { echo "Not enough distinct programs ingested; raise INGEST_SECS or pick busier INGEST_PROGRAMS"; exit 1; }

build_pool() { # $1=file  $2..=lines "program|sz"
  local file="$1"; shift; local first=1
  { printf '['
    for row in "$@"; do
      local prog="${row%%|*}" sz="${row##*|}"
      [ "$first" = 0 ] && printf ','; first=0
      printf '{"jsonrpc":"2.0","id":"b","method":"getProgramAccounts","params":["%s",{"encoding":"base64","filters":[{"dataSize":%s}]}]}' "$prog" "$sz"
    done
    printf ']'; } > "$file"
}
P1=(); P2=(); i=0
for row in "${ROWS[@]}"; do [ $((i % 2)) -eq 0 ] && P1+=("$row") || P2+=("$row"); i=$((i+1)); done
build_pool "$GEN/pool_p1.json" "${P1[@]}"
build_pool "$GEN/pool_p2.json" "${P2[@]}"
gen_bench p1; gen_bench p2
# The cap must be exactly the number of P1 patterns: P1 fills it, so baseline freezes P2 out
# (nothing left for eviction to fix otherwise). Auto unless the user pinned CAP.
[ -z "$CAP" ] && CAP="${#P1[@]}"
echo "    P1 programs: ${P1[*]%%|*}"; echo "    P2 programs: ${P2[*]%%|*}"
echo "    max-auto-indexes (cap) = $CAP  (P1 patterns: ${#P1[@]}, P2 patterns: ${#P2[@]})"

# ---- 3. run one variant ------------------------------------------------------------------------
measure() { # $1=label
  cargo run --release -q -p cloudbreak-dbtools -- --config "$GEN/dbtools.toml" analytics indexes-count > "$RES/$1.idx.txt" 2>&1
  cargo run --release -q -p cloudbreak-dbtools -- --config "$GEN/dbtools.toml" analytics indexes-sizes >> "$RES/$1.idx.txt" 2>&1
}
run_variant() { # $1=name
  echo "==> [$1] starting query-tracker + api"
  "$CB" --config "$GEN/qt_$1.toml" query-tracker > "$RES/$1.qt.log" 2>&1 & local qt=$!; PIDS+=("$qt")
  "$CB" --config "$GEN/api.toml" api > "$RES/$1.api.log" 2>&1 & local api=$!; PIDS+=("$api")
  until curl -s http://localhost:4000 >/dev/null 2>&1; do sleep 1; done; sleep 3

  echo "==> [$1] PHASE A: hammer P1 (build indexes to the cap)"
  cargo run --release -q -p integration_tests -- benchmark gpa -c "$GEN/bench_p1.toml" > "$RES/$1.phaseA_p1.txt" 2>&1
  measure "$1.phaseA"

  echo "==> [$1] PHASE B: switch to P2 (baseline freezes; patched evicts P1, indexes P2)"
  cargo run --release -q -p integration_tests -- benchmark gpa -c "$GEN/bench_p2.toml" > "$RES/$1.phaseB_p2.txt" 2>&1
  measure "$1.phaseB"

  kill "$qt" "$api" 2>/dev/null || true; sleep 2
}

gen_qt baseline false
run_variant baseline

echo "==> resetting index state (drop ONLY registry-tracked auto-indexes); account + migration indexes untouched"
# Drop by the registry, not by name LIKE 'idx_accounts_%' — that prefix also matches the
# migration's own indexes (idx_accounts_pubkey_slot, ...), which must survive the reset.
PSQL -c "DO \$\$ DECLARE r record; BEGIN FOR r IN SELECT index_name FROM auto_index_usage LOOP EXECUTE 'DROP INDEX IF EXISTS '||quote_ident(r.index_name); END LOOP; END \$\$;"
PSQL -c "TRUNCATE auto_index_usage" 2>/dev/null || true

gen_qt patched true
run_variant patched

# ---- 4. report ---------------------------------------------------------------------------------
echo; echo "================= RESULTS (P99 lines + index counts) ================="
for f in baseline.phaseA_p1 baseline.phaseB_p2 patched.phaseA_p1 patched.phaseB_p2; do
  echo "--- $f ---"; grep -iE "P99|SUMMARY" "$RES/$f.txt" | head -6 || true
done
echo "--- index bytes per phase ---"
for f in baseline.phaseA baseline.phaseB patched.phaseA patched.phaseB; do
  echo "[$f]"; cat "$RES/$f.idx.txt"
done
echo; echo "Full output in $RES/. The win: patched phaseB P99 << baseline phaseB P99,"
echo "and patched index bytes bounded vs baseline pinned at the cap with cold P1 indexes."
