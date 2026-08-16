# notes

## What request and limit actually become

A CPU limit is a hard cap: how much CPU time the container
may use every 100 milliseconds. 500m means 50 ms of CPU time
per window, shared by every thread. When the budget is gone,
the pod is **throttled** until the next window, even if the
node is idle.

A CPU request is a reservation. Linux CFS (Completely Fair
Scheduler) turns it into a weight, and that only matters when
the node is actually busy: CFS splits CPU in proportion to
those weights. Idle leftover is free unless a limit is in the
way. The same CFS is also what throttles you when a limit's
budget runs out.

**The app next to you is protected by its request, not by your
limit.** Your limit only stops *you* from using idle CPU.

There is one setup where the "limit" is doing something else:
request and limit set equal, and the node is configured to pin
whole cores to that pod. That is reserved cores, not a freeze.
Leave those alone.

## .NET looks at the limit

If you do not set `DOTNET_PROCESSOR_COUNT`, .NET counts CPUs
from the limit. A 500m limit (or the common 100m default)
shows up as 1 CPU, so the thread pool and garbage collector
follow that and you start with one worker thread.

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
garbage collector needs CPU to free memory, and if it is
throttled most of the time, memory grows and the pod gets
killed. Check `container_cpu_cfs_throttled_periods_total`
before you raise the memory limit.

## Memory limits stay

**Leave `limits.memory`.** If CPU is short, the app waits. If
memory is short, the app (or the node) dies.

## When a CPU limit still makes sense

- code you do not trust
- a benchmark that needs a fixed ceiling
- pods that pin whole cores, as above

For normal services, **drop `limits.cpu`**, keep a request that
is roughly right, and watch node CPU. If someone can deploy
with no request, add a default request. Do not paper over
that with a CPU limit.

Autoscaling on CPU compares use to the *request*, not the
limit. Removing the limit does not change that formula. Use
can go higher, so you may get more replicas, which is
usually fine.

## Questions that come up

**How is a request enforced?** It is a CFS weight
(`cpu.shares` / `cpu.weight`). The Kubernetes scheduler will
not pack more requested CPU onto a node than the node has.
When the node is actually busy, CFS splits time in those
weights. A 16 CPU request next to sixteen 1 CPU requests
gets about half the machine. Nothing else is required.

**Doesn't a limit stop a bad pod from eating the node?** It
stops that pod from using leftover CPU. It does not give
CPU to anyone else. The neighbor is protected by *its*
request. If leftover is huge, requests on that node are too
small. A limit still makes sense on code you do not trust.

**Don't Go / Java / .NET need the limit to size the thread
pool?** They often read the quota and treat it as the CPU
count. Drop the limit and they may size themselves to the
whole node. Set `GOMAXPROCS`, the JVM equivalent, or
`DOTNET_PROCESSOR_COUNT`. Do not keep a CPU limit just to
shrink the runtime.

**Does HPA look at the limit?** No. CPU autoscaling is use
divided by the request. After you drop the limit, use can
run past 100% of the request and you may get more replicas.

**Don't I want a limit so the app behaves the same on a
quiet node and a busy one?** That is what a limit buys:
the same cap everywhere, including when the node is idle.
You pay for that with throttling. Most services want the
leftover.

**Is this a reserved core?** Only if the node pins whole
cores (`cpuManagerPolicy: static`, integer request, request
equal to limit). Setting request equal to limit by itself
does not pin. That is the Uber-style cpuset setup. Leave
those alone.
