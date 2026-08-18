# Runtimes: what a CPU limit changes under the hood

Most managed-runtime languages read the container's CPU quota at startup and size thread pools, GC, or `GOMAXPROCS` from it. A tight limit doesn't just throttle CPU-time - it shrinks the runtime's idea of how parallel it's allowed to be.

## .NET: ProcessorCount drives everything

Since .NET Core 3.0, the runtime reads the container's `cpu.max` (quota/period) at startup and sets
`Environment.ProcessorCount` to the ceiling of that ratio, not the host's logical core count. A
100m CPU limit (`cpu.max` = `10000 100000`) gives quota/period = 0.1, rounded up: `ProcessorCount = 1`.
A 300m or 500m limit also rounds up to 1. This single number then drives everything below it.

**ThreadPool sizing and starvation.** The ThreadPool's default minimum worker thread count is
`Environment.ProcessorCount`. Above that minimum, the pool grows via a hill-climbing algorithm that
injects new threads slowly (on the order of one thread per second under sustained demand),
specifically to avoid thread-storm overhead. With `ProcessorCount = 1`, the pool starts at one
worker thread and grows into extra concurrent load a full second at a time. Any burst of concurrent
work (a rebalance, a batch of HTTP requests) queues behind that single starting thread until the
pool catches up: classic thread-pool starvation, proportional to the limit, not to the actual work
available.

**Server GC heap count.** With Server GC (the default for ASP.NET Core apps), the runtime creates
one GC heap per logical processor, i.e., per `Environment.ProcessorCount`. A pod capped at
`ProcessorCount = 1` runs Server GC with a single heap: none of Server GC's parallel-collection
benefit, just its higher baseline memory overhead versus Workstation GC.

**GC starvation causes OOM kills.** The GC needs CPU to reclaim memory. Under a tight CPU limit, a
pod under memory pressure gets throttled precisely when it most needs to collect, so allocation
outruns reclamation and the pod dies out-of-memory. The CPU limit converts a routine memory peak
into an OOM kill.

This is not hypothetical. In one production incident (anonymized here), an API pod ran with `limits.cpu: 100m`, was
throttled in **98.9% of CFS periods** during the incident, threw in-process
`OutOfMemoryException`s, and was OOMKilled; root-cause analysis found the GC could not get CPU to
reclaim memory, turning a routine memory peak into a death spiral. The same starvation blew a
downstream timeout on a config/flag read, so the app silently fell back to defaults in production.
The dependency it was calling was healthy the whole time; the errors it emitted were symptoms of
the starved pod, not a real outage on the other end. Fix applied: `cpu: 1`, `memory: 1Gi`. Two
lessons: a CPU limit can cause a *memory* incident, and throttling routinely presents as someone
else's dependency failing.

**What changes when limits are dropped.** Without a CPU limit, `cpu.max` reads `max`, and
`Environment.ProcessorCount` falls back to the node's total logical core count, which can be 8, 16,
or more: far above the pod's actual CPU share (its request). Sizing ThreadPool minimums, GC heap
count, and any `Parallel.For`/`Parallel.ForEach` degree of parallelism off that inflated number
over-subscribes the pod's real CPU share. The fix is to set `DOTNET_PROCESSOR_COUNT` explicitly
before dropping the limit, not after:

```yaml
env:
  - name: DOTNET_PROCESSOR_COUNT
    value: "4"   # shared default; services override only when they need to
```

Once requests are right-sized (see [06-rollout.md](06-rollout.md) step 5), the downward API can
derive it from the request automatically:

```yaml
env:
  - name: DOTNET_PROCESSOR_COUNT
    valueFrom:
      resourceFieldRef:
        resource: requests.cpu
        divisor: "1"
```

Caveat: `divisor: "1"` rounds up to whole cores. With typical 10m-250m requests this yields 1,
which recreates the tiny-ThreadPool problem (without the freezes). Use a static default until
requests are honest.

Other knobs worth setting alongside dropping the limit:

- `DOTNET_gcServer=0` for small pods (low CPU request): Server GC's per-core heap overhead isn't
  worth it below a few cores; Workstation GC is often the better default.
- `DOTNET_GCHeapHardLimitPercent=75` (with the memory limit, which stays): caps the managed heap at
  75% of the container's memory limit, so GC growth hits a controlled ceiling instead of racing the
  kubelet OOM killer. 75 is a starting point, not a validated constant; tune it to the workload's
  native-memory footprint.

**Rule: never drop a CPU limit before pinning the runtime's processor-count knob.** Dropping the
limit without setting `DOTNET_PROCESSOR_COUNT` swaps "sized for 1 core" for "sized for the whole
node," which over-subscribes a pod that only actually gets its request's worth of CPU-time under
contention.

## Go: GOMAXPROCS sees the whole node

Go's runtime sets `GOMAXPROCS` to the number of logical CPUs it detects, and by default that means
the *node's* CPU count, not the container's quota or request - Go does not read `cpu.max` on its
own. With a CPU limit in place this is already wrong (a 300m-limited pod scheduling goroutines
across `GOMAXPROCS=16` invites the same quota-burn-in-milliseconds problem as .NET's ThreadPool).
Without a limit it gets worse, not better: nothing constrains `GOMAXPROCS` at all. Set it
explicitly, matched to the CPU request:

```yaml
env:
  - name: GOMAXPROCS
    value: "2"
```

(Libraries like `uber-go/automaxprocs` do this automatically from cgroup limits at startup, but
they read the limit - if you drop the limit, pin `GOMAXPROCS` directly or the library has nothing
to read.)

## JVM: ActiveProcessorCount

Modern JVMs (10+) are cgroup-aware and set `ActiveProcessorCount` from the container's CPU quota,
which then feeds `ForkJoinPool.commonPool()`, the GC's parallel worker count, and any
`Runtime.availableProcessors()` call. The same shrink-to-quota problem applies as .NET's
`ProcessorCount`. If you drop the limit, pin it explicitly rather than let the JVM see the node:

```
-XX:ActiveProcessorCount=2
```

## Python and Node: usually explicit already

Python (gunicorn/celery worker counts) and Node (`UV_THREADPOOL_SIZE`, cluster worker count) mostly
take concurrency as explicit config rather than reading the container's CPU quota automatically.
The risk here is smaller but not zero: if worker/process counts were ever tuned by someone reading
`os.cpu_count()` on the node, the same "sees the whole node, not the quota" trap applies. Check for
that pattern specifically before assuming these runtimes are unaffected.

## The rule, restated

No service's CPU limit should be dropped until its runtime's processor-count knob is pinned
explicitly. For most fleets this is a one-time shared-default PR for the dominant runtime (.NET in
the example above), plus a per-service env var added in the same PR that drops a non-default
runtime's limit. See [06-rollout.md](06-rollout.md) step 1.

Next: [03-databases.md](03-databases.md) - the same story for Postgres.
