# Kubernetes CPU limits: the mistake, the why, and proof

Most charts set two CPU numbers, a request and a limit, and
people treat them like the same setting with a bit of headroom.
The **request** is how much CPU is reserved for your pod if
it needs it. The **limit** is a hard cap. Hit it and the
kernel **throttles** the pod, even when the node still has
spare CPU. That is the usual cause of CPU throttling on
Kubernetes. It does not protect the pod next to you.

![values file](assets/values-file.svg)

## Why

Linux already shares a busy node. That sharing is called CFS
(Completely Fair Scheduler). A request is a weight in the
cgroup, not a pinned core. If the node is busy, CFS splits
time in proportion to those weights: a 16 CPU request gets
about sixteen times the CPU of a 1 CPU request. If the other
pods are idle you can use the leftover, and when they need
CPU again those cores go back. **You do not need a CPU limit
for any of that.**

![cfs live](assets/cfs-live.svg)

A limit is a separate cap, also enforced by CFS. Every 100 ms
the kernel gives your pod a budget of CPU time, and every
thread in the pod shares that budget. When it is gone, the
pod is throttled until the next 100 ms. The node can be idle
and you still wait. A 1 CPU limit on a 32-core node can still
run on all 32 cores for a few milliseconds, then sit out the
rest of the window. Four threads working at once burn a 500m
budget in about 12 milliseconds. It is an average, not a
reserved core.

![limit live](assets/limit-live.svg)

![borrow live](assets/borrow-live.svg)

![cpu vs memory](assets/cpu-vs-memory.svg)

People put a limit on because they are afraid some other app
will starve their pod. That is what the request is for. **The
app you care about is protected by its own request.** A
runaway next door can use leftover CPU, but it cannot take
the share you reserved. If leftover on the node is huge, the
requests are too small. If teams can deploy with no request
at all, give them a default request instead of putting a CPU
limit on whoever looks greedy.

![neighbor](assets/neighbor.svg)

## What average CPU hides

Your CPU graph usually averages a minute. CPU throttling
lasts a tenth of a second. So **the graph can look fine while
the app is being throttled all the time.** Watch
`container_cpu_cfs_throttled_periods_total`, not average CPU.

![dashboard](assets/dashboard-blind.svg)

## Proof

I ran the same .NET app twice on a local 8-CPU minikube. Both
asked for 250m, and I pinned .NET to 4 CPUs on both so I was
not accidentally comparing "app thinks it has 1 core" against
"app thinks it has 8." One pod had a 500m limit. The other
did not.

The useful test is a burst that *on average* stays under 500m,
but for a moment uses several threads at once, which uses up
the limit budget inside one 100 ms window. Typical response
time went up about **4x**, and the limited pod was throttled
about half the time. There were no errors, and a normal CPU
graph would have looked fine.

![burst](assets/burst.svg)

I also sent a short traffic spike that *did* go over the cap,
and the limited pod was throttled on almost every window. Then
I put another pod on the same machine that just burns CPU in a
loop, with no limit of its own. The app without a limit did
not get slower. This machine still had spare cores, so it was
not a packed production node. It only shows the direction:
**the request was enough.**

More numbers and charts: [results/run.md](results/run.md).
.NET, HPA, and questions that come up: [notes.md](notes.md).

## Conclusion

![do](assets/do.svg)

After you drop CPU limits, look at that throttling metric and
at node CPU. Later you can shrink requests to what the apps
really use, and **that is what can save machines.** Deleting
the limit line by itself does not free any nodes.

I would still set a CPU limit on code you do not trust, on a
benchmark that needs a hard ceiling, and on pods that pin
whole cores (request and limit set equal on purpose).

## Run it

Use a throwaway cluster. One of the pods will burn CPU on
purpose.

```bash
minikube start --driver=docker --cpus=8 --memory=8192
kubectl config use-context minikube

./scripts/run.sh
./scripts/cleanup.sh
```

Needs `kubectl` and `python3`. First run downloads a large
.NET image. `NS` and `KCTX` change the namespace and cluster
if you need to.
