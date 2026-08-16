# notes

## cpu.max and cpu.weight

A CPU **limit** becomes `cpu.max` in the cgroup: a quota of CPU-time per 100 ms
period, shared by every thread in the container. 500m means 50 ms of CPU time
per window. When the quota hits zero the kernel stops scheduling the cgroup
until the next window. It does not slow the threads down. It parks them.

A CPU **request** becomes `cpu.weight`. Weight only matters when the node is
busy. Then CFS splits CPU in proportion to requests. Idle CPU is up for grabs
unless a limit is in the way.

Neighbors are protected by their requests, not by your limit. The
limit just stops you from using idle CPU.

The one case where a "limit" is doing real isolation is Guaranteed QoS plus
the kubelet static CPU manager. There, request == limit pins whole cores. That
is pinning, not quota. Leave those pods alone.

## .NET reads the quota

`Environment.ProcessorCount` is `ceil(quota/period)`, not the size of the
node. A 500m limit reports 1. The ThreadPool minimum and Server GC heap count
follow that number. On a common 100m default you start with one worker thread.

This repo pins `DOTNET_PROCESSOR_COUNT=4` on both pods so the benches
compare the cap, not the runtime sizing. After you drop the limit in a
real fleet, set a default so the same service does not size itself to a
4-core node in one pool and a 16-core node in another:

```yaml
- name: DOTNET_PROCESSOR_COUNT
  value: "4"
```

A tight CPU limit can also look like a memory incident. The GC needs CPU to
reclaim. If it is parked for most of every 100 ms window, allocation wins and
the pod OOM-kills. Check `container_cpu_cfs_throttled_periods_total` before
you raise the memory limit.

## keep memory limits

Leave `limits.memory`. CPU being slow is recoverable. A leak without
a memory cap can take the node.

## when a CPU limit is still reasonable

- code you do not trust, where you want a hard backstop even if requests are a lie
- a bench that needs a fixed ceiling so runs compare
- the pinned-core case above

For ordinary first-party services, drop `limits.cpu`, keep an honest request,
and watch node CPU. If a request is a joke (10m on a service that sits at 200m),
fix the request in the same change. If requests are optional in the namespace,
a LimitRange default request is the actual gap — not a CPU limit on the greedy
pod.

HPA scales on usage vs request, not vs limit. The formula stays the same.
Usage is allowed to climb higher, so a CPU HPA may add replicas it would
not have added under a cap.
