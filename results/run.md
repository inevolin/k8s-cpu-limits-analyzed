# numbers from this run

2026-08-16 13:21 WEST. Local minikube, 8 CPUs.
Both apps asked for 250m. I pinned .NET to 4 CPUs on both.
One also had a 500m CPU limit.

Startup times are noisy (`dotnet run` compiles every time).
I would not quote them. Everything else is one pass.

## burst

Same work on both apps: four threads spinning for 20 ms,
5 times a second, for 45 seconds. That is about 400m on
average, so it stays under the 500m limit, but it still
uses up the limit's budget inside each short slice.

![burst latency](../assets/results-burst.svg)

![windows frozen](../assets/results-throttle.svg)

| | typical (p50) | p95 | slowest 1% (p99) | throttled |
|---|---|---|---|---|
| 500m limit | 86.9 ms | 89.5 | 101.6 | half the time (254 / 509) |
| no limit | 22.7 ms | 26.1 | 43.7 | never |

No failed requests.

## spike

A quieter endpoint (a bit of CPU, then a 30 ms sleep). First
a slow trickle, then a short burst of traffic that *does* go
over the 500m cap. Typical time barely moves because most of
the work is sleep. The slow requests and the throttling are
where it shows.

![spike](../assets/results-spike.svg)

| | slow requests, quiet | typical during spike | slow requests during spike | throttled |
|---|---|---|---|---|
| 500m limit | 57.4 ms | 47.0 | 87.8 | almost always (244 / 260) |
| no limit | 52.0 ms | 46.6 | 58.8 | never |

## a pod that just burns CPU

I started a fourth-ish workload on the same machine: a small
pod with 4 tight loops, a tiny 100m request, and no CPU
limit. Then I hit the *unlimited* app again.

The machine still had spare cores (8 CPUs, one busy pod), so
nothing really had to fight and the unlimited app did not get
slower. This is not a packed production node.

![busy pod](../assets/results-hog.svg)

| | slowest 1% | throttled |
|---|---|---|
| no busy pod | 52.9 ms | never |
| busy pod on the node | 49.2 ms | never |

```
app-limit-64bdf458f-gmkc2   minikube
app-open-74cfd9d5b5-qbs9m   minikube
hog-5b894989-vks8q          minikube
```

## what .NET saw

| pod | CPUs .NET thinks it has | kernel budget |
|---|---|---|
| 500m limit | 4 | 50 ms every 100 ms |
| no limit | 4 | no budget (unlimited) |

## startup

`dotnet run` compiles on every start. Times overlapped.

| | runs (s) | median |
|---|---|---|
| 500m limit | 35, 36, 40 | 36 |
| no limit | 32, 28, 47 | 32 |

Raw log: [`run.jsonl`](run.jsonl).
