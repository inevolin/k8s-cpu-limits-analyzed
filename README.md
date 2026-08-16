# Kubernetes CPU limits: the mistake, the why, and proof

Most charts set two CPU numbers, a request and a limit, and
people treat them like the same setting with a bit of headroom.
The **request** is how much CPU the scheduler promises your
pod. The **limit** is a hard cap: once you hit it, the kernel
**throttles** the pod until the next time slice, which can
happen as often as ten times a second. That does not protect
the pod next to you.

![values file](assets/values-file.svg)

## Why

Linux already shares a busy node through CFS, the Completely
Fair Scheduler. A request is how many cores you are guaranteed:
if the other pods are idle you can use the leftover, and when
they need CPU again those cores go back. **You do not need a
CPU limit for any of that.**

![cfs live](assets/cfs-live.svg)

A limit is a separate budget, also enforced by CFS. Every tenth
of a second the kernel gives your pod a slice of CPU time, and
all of its threads share that slice. When the budget is used
up, the kernel **throttles** the pod, pausing it until the next
100 ms window. Four threads working at once burn a 500m budget
in about 12 milliseconds, then wait out the rest of the window.

![limit live](assets/limit-live.svg)

![borrow live](assets/borrow-live.svg)

![cpu vs memory](assets/cpu-vs-memory.svg)

People put a limit on because they are afraid some other app
will eat the node, which is the wrong fix. **The app you care
about is protected by its own request.** If teams can deploy
with no request at all, give them a default request instead of
putting a CPU limit on whoever looks greedy.

![neighbor](assets/neighbor.svg)

## What average CPU hides

Your CPU graph usually averages a minute, while each throttle
pause lasts a tenth of a second, so **the graph can look fine
while the app is being stopped all the time.** Watch
`container_cpu_cfs_throttled_periods_total`, not average
utilization.

![dashboard](assets/dashboard-blind.svg)

## Proof

I ran the same .NET app twice on a local 8-CPU minikube. Both
asked for 250m, and I pinned .NET to 4 CPUs on both so I was
not accidentally comparing "app thinks it has 1 core" against
"app thinks it has 8." One pod had a 500m limit. The other
did not.

The useful test is a burst that *on average* stays under 500m,
but for a moment uses several threads at once, which uses up
the limit budget inside one slice. Typical response time went
up about **4x**, and the limited pod was throttled about half
the time. There were no errors, and a normal CPU graph would
have looked fine.

![burst](assets/burst.svg)

I also sent a short traffic spike that *did* go over the cap,
and the limited pod was throttled on almost every slice. Then
I put another pod on the same machine that just burns CPU in a
loop, with no limit of its own. The app without a limit did
not get slower. This machine still had spare cores, so it was
not a packed production node. It only shows the direction:
**the request was enough.**

More numbers and charts: [results/run.md](results/run.md).
A bit more on .NET: [notes.md](notes.md).

## Conclusion

![do](assets/do.svg)

After you drop CPU limits, look at that throttle metric and at
node CPU. Later you can shrink requests to what the apps
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
