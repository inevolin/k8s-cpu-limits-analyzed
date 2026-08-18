# Measuring: is this actually happening in your cluster?

Everything in [01-theory.md](01-theory.md) is a mechanism. Here's how to turn it into numbers from your own Prometheus/Thanos, before and after you touch anything.

## The three capacity sums

Start with the shape of the problem: how much CPU is requested, how much is promised via limits,
and how much is actually used.

```promql
sum(kube_pod_container_resource_requests{resource="cpu"})
sum(kube_pod_container_resource_limits{resource="cpu"})
sum(kube_node_status_allocatable{resource="cpu"})
```

Run these as three separate queries in the same Explore session. For usage, average *and* P95 over
a full 24h window - a short `[5m]` instant sample can land on a quiet moment and read far too low:

```promql
sum(rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[24h]))
quantile_over_time(0.95, sum(rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))[24h:5m])
```

## Per-container throttle ratio

Ratio = `throttled_periods / total_periods` over a window. This is the metric that actually shows
the problem - average CPU usage does not.

**Top offenders, 24h:**

```promql
topk(12,
  sum by (namespace, pod, container) (
    increase(container_cpu_cfs_throttled_periods_total{container!=""}[24h])
  )
  /
  sum by (namespace, pod, container) (
    increase(container_cpu_cfs_periods_total{container!=""}[24h])
  )
)
```

**Count of containers in the severe band:**

```promql
count(
  (
    sum by (namespace, pod, container) (
      increase(container_cpu_cfs_throttled_periods_total{container!=""}[24h])
    )
    /
    sum by (namespace, pod, container) (
      increase(container_cpu_cfs_periods_total{container!=""}[24h])
    )
  ) > 0.1
)
```

## Severity bands

| Throttle ratio (24h) | Band |
|---|---|
| < 0.01 | low |
| 0.01 - 0.1 | moderate |
| > 0.1 | severe |

## What you may find: an anonymized example fleet

One real production fleet we measured, all namespaces, one snapshot re-verified over a full 24h
window:

| Metric | Cores | % of allocatable | % of requests |
|---|---|---|---|
| Node allocatable | 870 | 100.0% | 187.1% |
| CPU requests (sum) | 465 | 53.4% | 100.0% |
| CPU limits (sum) | 991 | 113.9% | 213.1% |
| Actual usage (24h avg) | 88 | 10.1% | 18.9% |
| Actual usage (24h P95 peak) | 120 | 13.8% | 25.8% |

Reading this table: requests alone already commit over half the cluster's allocatable CPU. Limits
sum to *more than the cluster physically has* - the cluster promises more CPU than exists if every
container tried to hit its limit at once. Real usage averages ~10% of allocatable and ~19% of
requests. Most requested CPU sits idle, yet containers still throttle, because limits - not
requests - cap them moment to moment.

In the same fleet, 333 of 1,749 CPU-limited containers had a 24h throttle ratio above 0.1 (severe)
at capture time. The count moved day to day (347 the next day); the order of magnitude did not. The
worst individual containers sat at throttle ratios of 0.8+ - throttled in the majority of CFS
periods, all day, every day, while their average-CPU dashboards looked unremarkable.

## After rollout: what "better" looks like

Once CPU limits are dropped in an environment (requests and memory limits unchanged), re-run the
same three query groups there. They become the success metric for the change:

- **Throttle ratio (query a):** top ratios should drop toward 0 across the board.
- **Severe count (query b):** the count of containers above 0.1 should collapse toward 0.
- **Capacity + usage (query c):** requests and allocatable stay the same, but actual usage as a
  share of allocatable should *rise*. That's expected and good - it means CPU that was previously
  reserved but throttled away is now actually being used, which supports tighter bin-packing and
  less overprovisioning. See [05-cost.md](05-cost.md).

Do not expect usage to rise dramatically in absolute terms - most of the rise is the same work
completing without stalling, not new work appearing. A flat-to-slightly-higher usage line next to a
collapsed throttle-ratio line is the signature of a successful rollout.

Next: [05-cost.md](05-cost.md) - what any of this is actually worth in node count and dollars.
