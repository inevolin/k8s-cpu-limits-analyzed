# Theory: CFS quota mechanics

How a CPU limit actually turns into a stall, and why a request already does the job people expect a limit to do.

## cpu.max: quota and period

cgroup v2 exposes `/sys/fs/cgroup/cpu.max` as two numbers: `quota period` (microseconds). Period
defaults to 100000us (100ms). Quota is how much CPU-time the cgroup may consume per period, across
all its threads combined. Kubernetes derives quota from the CPU limit: 1000m of limit = 100ms quota
per 100ms period (one full core); 300m = 30ms quota per period; 500m = 50ms quota per period. No
CPU limit means `cpu.max` reads `max 100000`: unlimited quota, no throttling, ever.

Requests do not appear in `cpu.max` at all. They map to `cpu.weight`, a separate file (see below).

## Multi-thread quota burn

Quota is CPU-*time*, not CPU-*percent*, and it is shared across every thread in the cgroup running
in parallel. A single thread on a 300m limit can run for the full 30ms before the quota is spent.
Sixteen threads running in parallel on the same 300m limit burn that same 30ms quota roughly 16x
faster in wall-clock terms: 30ms / 16 ~= 1.9ms of wall time before the cgroup hits zero quota. A
thread pool with 16 dedicated worker threads does exactly this on every burst of concurrent work:
quota exhausted in under 2ms, then the cgroup is frozen for the remaining ~98ms of the period. See
[02-runtimes.md](02-runtimes.md) for the language-runtime version of this story.

## Throttling arrives as a stall, not a slowdown

Once quota is exhausted, the kernel does not run the cgroup's threads *more slowly*: it does not
schedule them *at all* until the next period starts. From the app's perspective a request that
would take 2ms takes 100ms, in one discontinuous jump. This is why throttling shows up as p99/p999
latency spikes and probe flapping, not as a gradually rising baseline. Average CPU usage can look
completely fine (well under the limit) while the tail is destroyed, because usage is averaged over
the period and throttling is a binary state within it. The burst leg of this repo's lab
(`scripts/run.sh`, the `/burst` endpoint) demonstrates this directly: average CPU stays below the
limit, p99 still stalls hard. See `results/run.md`.

**Watch `container_cpu_cfs_throttled_periods_total`, not the average CPU graph** - see
[04-measuring.md](04-measuring.md) for the queries.

## cpu.weight: what requests actually buy

CPU requests are translated to `cpu.weight` (range 1-10000, proportional to millicores requested).
`cpu.weight` only matters when the node is CPU-saturated: the kernel's CFS scheduler splits
contended CPU time between cgroups in proportion to their weight. If the node has spare CPU, a pod
with no limit and a low weight still gets to use it; nothing throttles it. If the node is
saturated, weight ensures a pod that requested more gets proportionally more of the contended time,
and a pod that requested little cannot starve everyone else, whether or not it has a limit set.
**This is the mechanism that protects co-tenants, not the limit.**

## Limits provide no protection that requests do not already provide

Given honest requests, `cpu.weight` already caps how much of a *contended* node a pod can take
relative to its neighbors. A CPU limit adds one behavior on top: it also throttles the pod when the
node is *not* contended, i.e., when there is idle capacity nobody else wants. That is pure downside
for that workload (and, transitively, for anything waiting on it: connection pools, message-queue
session timeouts, HTTP clients) and provides no additional isolation to the rest of the cluster,
because the rest of the cluster was already protected by weight.

## Hyperthreading does not change the quota math

`cpu.max`'s quota is CPU-*time*, counted the same way regardless of whether a thread lands on a
physical core or a hyperthread (SMT sibling). The kernel does not give a discount for running on a
sibling of an already-busy core, and it does not charge extra either: the accounted time is
wall-clock time the thread spent scheduled, full stop. What hyperthreading does change is how much
real throughput that time buys. Two sibling threads contending for the same core's execution units
finish their work slower, in wall-clock terms, than two threads on independent physical cores would
- so a quota sized by counting logical CPUs (as `nproc` and most container runtimes report them)
can be quietly optimistic about how much actual compute that quota represents, on a node where SMT
siblings are busy. This is a capacity-planning wrinkle, not a reason to keep a limit: the quota
still throttles on time, not "logical cores used," and a request still reserves a `cpu.weight`
share of whatever real throughput the node has, siblings included.

## The one real exception: Guaranteed QoS + static CPU manager

Kubernetes' kubelet `CPUManager` in `static` policy mode gives exclusive whole cores to containers
in the `Guaranteed` QoS class (CPU and memory requests == limits, for every container in the pod).
In that specific configuration, the "limit" is not doing CFS quota throttling: it is pinning the pod
to dedicated physical cores that no other pod can use, which is real isolation and can matter for
latency-critical or NUMA-sensitive workloads. The recommendation in this repo (drop CPU limits,
keep requests honest) does not apply to workloads deliberately configured for static core pinning;
it applies to the default `Burstable`-QoS majority of most fleets, which gets no such benefit from a
limit, only the quota-throttling downside described above. See [07-objections.md](07-objections.md)
for the fuller list of when limits do make sense.

Next: [02-runtimes.md](02-runtimes.md) - what this does to .NET, Go, the JVM, and Python/Node.
