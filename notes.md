# notes

## What request and limit actually become

A CPU limit is a budget: how much CPU time the container may use
every 100 milliseconds. 500m means 50 ms of CPU time per slice,
shared by every thread. When the budget is gone, the kernel
stops the whole container until the next slice.

A CPU request is a share. Linux CFS (Completely Fair Scheduler)
turns it into a weight. That only matters when the node is
actually busy: CFS splits CPU in proportion to those weights.
Idle leftover is free unless a limit is in the way. The same
CFS is also what pauses you when a limit's budget runs out.

The app next to you is protected by *its* request, not by your
limit. Your limit only stops *you* from using idle CPU.

There is one setup where the "limit" is doing something else:
request and limit set equal, and the node is configured to pin
whole cores to that pod. That is reserved cores, not a freeze.
Leave those alone.

## .NET looks at the limit

If you do not set `DOTNET_PROCESSOR_COUNT`, .NET counts CPUs
from the limit. A 500m limit (or the common 100m default)
shows up as 1 CPU. The thread pool and garbage collector
follow that. You start with one worker thread.

This lab sets `DOTNET_PROCESSOR_COUNT=4` on both pods so the
test is about the limit, not about .NET shrinking itself. In
a real fleet, set one default after you drop limits, or the
same service will behave differently on a 4-core node than on
a 16-core node:

```yaml
- name: DOTNET_PROCESSOR_COUNT
  value: "4"
```

A tight CPU limit can also look like a memory problem. The
garbage collector needs CPU to free memory. If it is paused
most of the time, memory grows and the pod gets killed. Check
`container_cpu_cfs_throttled_periods_total` before you raise
the memory limit.

## Memory limits stay

Leave `limits.memory`. If CPU is short, the app waits. If
memory is short, the app (or the node) dies.

## When a CPU limit still makes sense

- code you do not trust
- a benchmark that needs a fixed ceiling
- pods that pin whole cores, as above

For normal services, drop `limits.cpu`, keep a request that
is roughly right, and watch node CPU. If someone can deploy
with no request, add a default request. Do not paper over
that with a CPU limit.

Autoscaling on CPU compares use to the *request*. Removing
the limit does not change that formula. Use can go higher,
so you may get more replicas. That is usually fine.
