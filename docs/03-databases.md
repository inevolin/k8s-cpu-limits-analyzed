# Databases: Postgres and CPU limits

Postgres doesn't size itself from the container's CPU quota the way .NET does from `cpu.max` - it sees the node's full core count regardless of any limit, which can make its self-tuning quietly wrong.

## Postgres sees node cores, regardless of limits

Postgres does not read cgroup `cpu.max` the way .NET does. It sizes itself off the CPUs visible via
the process's scheduling affinity, which cgroup v2 CPU quota does not restrict (quota controls how
much CPU-*time* the cgroup gets, not which or how many cores it may run on). A container with a
250m or 1000m CPU limit still reports the node's full core count to anything that asks. Operational
tuning that derives settings from detected core count (manual sizing, or automated tools like
pgtune) will therefore size for the node, not for the pod's actual CPU share.

## max_parallel_workers derived from node cores (mechanism, not measured)

`max_worker_processes`, `max_parallel_workers`, and `max_parallel_workers_per_gather` are static
config values, commonly set (by hand or by a tuning tool) from the host's detected CPU count. On a
throttled pod, this produces a parallel-worker budget far larger than the CPU-time the pod is
actually entitled to. Under a CPU limit, those extra parallel workers do not add throughput: they
compete with each other and the backend for the same small quota, spending more time context
switching and stalling than a smaller, honest worker count would.

A one-off parallel-query check run while preparing this material (a single `generate_series`
count scan on limited vs unlimited Postgres pods; not part of this repo's lab) did not show this
effect clearly: limited vs. unlimited runtime differed by well under 1%, within single-run noise.
The mechanism above follows from Postgres reading node-wide core count regardless of cgroup quota
(still true, see the section above), but a single sequential-scan-heavy query with default
`max_parallel_workers_per_gather` may not create enough parallel-worker contention to make the
effect visible. **Treat this section as mechanism derived from CFS quota theory** (same as
[01-theory.md](01-theory.md)), **not as something measured and confirmed here.**

## Checkpointer, autovacuum, and bgwriter share the same throttled quota (mechanism, not measured)

Checkpointer, autovacuum workers, and the background writer are ordinary processes in the same
cgroup as the backends serving queries. A CPU limit throttles the cgroup as a whole, not per
process, so a burst of query load can starve these background processes of CPU time. The visible
consequences: checkpoints falling behind (WAL buildup), autovacuum falling behind (table and index
bloat), and bgwriter falling behind (more dirty-page writing pushed onto foreground queries at
checkpoint time, i.e., worse tail latency exactly when the system is already under load).

This is derived from the same CFS quota mechanics as [01-theory.md](01-theory.md); it is not
something this lab directly measures (no long-running checkpoint-lag or autovacuum-lag capture).

## Stalls pile up connections toward max_connections (mechanism, not measured)

When CFS throttling stalls a backend mid-query, that backend holds its connection (and any locks)
for longer than the query's real CPU cost would require. Under steady incoming load, stalled
backends do not free up their connections as fast as new ones arrive, so concurrent connections
trend upward toward `max_connections`. This looks like a connection-pool-exhaustion incident but
the root cause is CPU throttling extending the effective duration of every query, not a genuine
spike in concurrent client demand. This is inference from the same quota mechanics, not something
observed in a live connection-count trend here.

## Recommendation

No CPU limit on Postgres pods. Keep CPU requests honest, since they still drive scheduling and
`cpu.weight`-based fairness under node contention. Tune `max_parallel_workers` (and related
settings) to the CPU *request*, not to the node's detected core count, so the parallel-worker
budget matches the CPU-time the pod can actually rely on.

This repo's lab does not include a Postgres scenario. The measured evidence behind this chapter
is one informal pgbench comparison from the same preparatory run as above, and it's mixed: pgbench
throughput was a modest (single-digit percent) lower on the limited variant in one run - a real
signal that limits can hurt Postgres throughput, but from one trial, not a repeated study. The
parallel `generate_series` query showed no meaningful difference and should be read as a null
result, not as confirmation of the parallel-worker-contention mechanism described above.

Next: [04-measuring.md](04-measuring.md) - how to check whether any of this is actually happening
in your own cluster.
