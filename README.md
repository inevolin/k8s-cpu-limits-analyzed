# Kubernetes CPU limits: the mistake, the why, and a small proof

People set a CPU request and a CPU limit as if they were one knob
with a safety margin. They are not. The request is your share when
the node is busy. The limit freezes *your* container, even when
cores are idle. It does not protect the pod next to you.

![mistake](assets/mistake.svg)

## Why

The request becomes `cpu.weight`. CFS splits a busy node by
weight. Idle leftover is free to borrow.

The limit becomes `cpu.max`: a budget of CPU-time every 100 ms,
shared by every thread. When it hits zero the kernel stops
scheduling the cgroup. Four busy threads burn a 500m quota in
about 12 ms, then sit until the window resets.

![quota](assets/quota.svg)

![borrow](assets/borrow.svg)

The usual CPU graph averages a minute. Throttling is a yes/no
inside 100 ms. Watch
`container_cpu_cfs_throttled_periods_total`.

![dashboard](assets/dashboard.svg)

![cpu vs memory](assets/cpu-vs-memory.svg)

A limit on the hog only blocks leftover CPU. The victim is
protected by *its* request. If requests are optional, add a
LimitRange. That is the gap.

![neighbor](assets/neighbor.svg)

## Proof

Same .NET app twice on minikube (8 CPU). Both 250m request,
both `DOTNET_PROCESSOR_COUNT=4`. One has a 500m limit.

The burst stays under the cap on average (~400m) but burns the
quota inside one window. Typical latency roughly quadrupled.
About half the windows froze. No errors. The CPU graph would
have looked fine.

![burst](assets/burst.svg)

A traffic spike over the cap froze almost every window on the
limited pod. A hog on the same node did not make the unlimited
app worse (fat 8-core node; the request still held).

Tables: [results/run.md](results/run.md). Extra (.NET, exceptions):
[notes.md](notes.md).

## Conclusion

![do](assets/do.svg)

Then watch throttle ratio and node CPU. After a while, shrink
requests from real p95. That is what can drop nodes.

Keep a CPU limit only on untrusted code, benches that need a
fixed ceiling, and Guaranteed + static CPU manager (those
limits are core pins).

## Run it

Disposable cluster. The hog burns CPU.

```bash
minikube start --driver=docker --cpus=8 --memory=8192
kubectl config use-context minikube

./scripts/run.sh
./scripts/cleanup.sh
```

Needs `kubectl` and `python3`. First run pulls the .NET 10 SDK
image. `NS` / `KCTX` override ns and context (`cpu-lab` / current).
