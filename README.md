# Kubernetes CPU limits: the mistake, the why, and proof

Most charts set two CPU numbers, a request and a limit, and
people treat them like the same setting with a bit of headroom.
The **request** is how much CPU is reserved for your pod if
it needs it. The **limit** is a hard cap. Hit it and the
kernel **throttles** the pod, even when the node still has
spare CPU. That is the usual cause of CPU throttling on
Kubernetes. It does not protect the pod next to you. In the
burst test below, adding a CPU limit took typical latency
from 23 ms to 87 ms, about 4x, with the limited pod throttled
in half of all CFS windows, and the average CPU graph looked
fine the whole time.

![Sample values.yaml showing a requests.cpu of 250m and a limits.cpu of 500m, with an arrow pointing out that the limit is the dangerous one](assets/values-file.svg)

## Why

Linux already shares a busy node. That sharing is called CFS
(Completely Fair Scheduler). A request is a weight in the
cgroup, not a pinned core. If the node is busy, CFS splits
time in proportion to those weights: a 16 CPU request gets
about sixteen times the CPU of a 1 CPU request. If the other
pods are idle you can use the leftover, and when they need
CPU again those cores go back. **You do not need a CPU limit
for any of that.**

![Diagram of a 4-core node with pod A requesting 1 core and pod B requesting 3, both busy and getting their share, then pod B going idle and pod A using the leftover cores, with no CPU limit involved](assets/cfs-live.svg)

A limit is a separate cap, also enforced by CFS. Every 100 ms
the kernel gives your pod a budget of CPU time, and every
thread in the pod shares that budget. When it is gone, the
pod is throttled until the next 100 ms. The node can be idle
and you still wait. A 1 CPU limit on a 32-core node can still
run on all 32 cores for a few milliseconds, then sit out the
rest of the window. Four threads working at once burn a 500m
budget in about 12 milliseconds. It is an average, not a
reserved core.

![Timeline of a single 100 ms CFS window for a pod with a 500m limit and 4 threads: the 50 ms budget burns in the first slice, then the pod sits throttled for the rest of the window](assets/limit-live.svg)

![Diagram of a traffic burst on a 4-core node where a pod requests 1 core: with no limit it borrows the leftover cores for the burst, with a 1.5-core limit it gets throttled instead](assets/borrow-live.svg)

![Side-by-side comparison of running out of CPU versus running out of memory: CPU means the app waits and catches up, so drop the limit and keep the request; memory means the app gets OOM-killed, so keep the memory limit](assets/cpu-vs-memory.svg)

## What average CPU hides

Your CPU graph usually averages a minute. CPU throttling
lasts a tenth of a second. So **the graph can look fine while
the app is being throttled all the time.** Watch
`container_cpu_cfs_throttled_periods_total`, not average CPU.

![Two views of the same 30 seconds: an average CPU graph that looks flat and fine, next to a CPU throttling graph on the same window showing the pod repeatedly hitting its limit](assets/dashboard-blind.svg)

People put a limit on because they are afraid some other app
will starve their pod. That is what the request is for. **The
app you care about is protected by its own request.** A
runaway next door can use leftover CPU, but it cannot take
the share you reserved. If leftover on the node is huge, the
requests are too small. If teams can deploy with no request
at all, give them a default request instead of putting a CPU
limit on whoever looks greedy.

![Diagram showing a CPU limit on the busy pod only stops it using leftover CPU and does not help the neighbor, while a request on your own pod is what actually reserves its share](assets/neighbor.svg)

The same blindness poisons right-sizing. Usage recorded under
a CPU limit can never go above the limit: the cap clips every
burst, so the history shows what the kernel allowed, not what
the app wanted. Size a request from that history and you copy
the cap's distortion into the request. Drop the limit first,
let the app run for a while, then measure and set requests
from numbers that were free to move.

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

![Chart comparing the burst test on both pods: the 500m-limit pod has a p50 of 87 ms and a p99 of 102 ms, throttled half the time, while the no-limit pod has a p50 of 23 ms and a p99 of 44 ms, never throttled](assets/burst.svg)

I also sent a short traffic spike that *did* go over the cap,
and the limited pod was throttled on almost every window. Then
I put another pod on the same machine that just burns CPU in a
loop, with no limit of its own. The app without a limit did
not get slower. This machine still had spare cores, so it was
not a packed production node. It only shows the direction:
**the request was enough.**

More numbers and charts: [results/run.md](results/run.md).

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

## Conclusion

![Table of what to set: keep the CPU request, keep the memory limit, drop the CPU limit unless you really know what you are doing](assets/do.svg)

- keep `requests.cpu`: it reserves your share
- keep `limits.memory`: or a leak takes the node
- drop `limits.cpu`: set it only if you really know what you are doing

After you drop CPU limits, look at that throttling metric and
at node CPU. Later you can shrink requests to what the apps
really use, and **that is what can save machines.** Deleting
the limit line by itself does not free any nodes.

**Leave `limits.memory`.** If CPU is short, the app waits. If
memory is short, the app (or the node) dies.

I would still set a CPU limit on code you do not trust, on a
benchmark that needs a hard ceiling, and on pods that pin
whole cores (request and limit set equal on purpose). For
normal services, drop `limits.cpu`, keep a request that is
roughly right, and watch node CPU.

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

## Run it

Use a throwaway cluster. One of the pods will burn CPU on
purpose.

```bash
minikube start --driver=docker --cpus=8 --memory=8192
kubectl config use-context minikube

./scripts/run.sh
./scripts/cleanup.sh
```

Needs `kubectl` and `python3`. First run downloads the .NET
SDK image, which is multi-GB, so give it a minute. After that
the whole thing takes roughly 5-10 minutes. `NS` and `KCTX`
change the namespace and cluster if you need to. The run
ends with a saturate leg that scales the hog until the node
is actually full, then measures the unlimited app again, and
it regenerates the results charts from the fresh numbers.

Expect output like this as it runs:

```
[14:02:11] target context=minikube ns=cpu-lab
[14:03:47] waiting for app-limit
[14:09:02] === burst  ~400m average, 5 rps, 45s ===
[14:09:52] load job=burst-limit rps=5 45s -> http://app-limit/burst?threads=4&ms=20
```

## Repo layout

- `app/` - the .NET test app (burst, mixed, and info endpoints)
- `k8s/` - manifests for the two pods, the load job, and the hog
- `scripts/` - `run.sh` drives the lab, `lib.sh` holds shared helpers
- `results/` - output of the last run, including `run.md` and raw JSONL
- `assets/` - diagrams and charts used in this README

## Further reading

- [Kubernetes docs: resource requests and limits](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) - how requests, limits, and CFS quota fit together.
- Dave Chiluk, ["Throttling: New Developments in Application Performance with CPU Limits"](https://www.youtube.com/watch?v=UE7QX98-kO0) (KubeCon NA 2019) - the CFS throttling bug and why limits hurt more than the naive model suggests.
- The kernel's CFS bandwidth burst feature (`cpu.max.burst`) lets a cgroup borrow a little unused budget from past periods, softening some of this without removing the limit.
