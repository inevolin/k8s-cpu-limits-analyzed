# Cost: where the savings actually come from

Dropping a CPU limit frees zero nodes by itself. The savings - and they can be real - come from what dropping the limit *enables*: honest requests, which is what the scheduler actually bin-packs against.

## Why requests drive cost, not limits

The Kubernetes scheduler places pods on nodes based on **requests** (it must guarantee the request
is available), never on limits. Node-pool sizing is therefore a function of total requested CPU,
not total limit or total usage. Inflated requests, whatever the reason, directly inflate the number
of nodes a cluster needs.

## How CPU limits inflate requests indirectly

Be precise about attribution: the savings come from right-sizing requests, not from deleting the
limit line. Removing limits frees zero nodes by itself. It is the *enabler* that makes right-sizing
possible - usage measured under throttling is suppressed demand, not real demand, so sizing from it
copies the cap's distortion into the new request. And the throttling that motivated the original
request inflation would otherwise stay.

Throttling under a CPU limit shows up as latency, not as a clean "at capacity" signal. The common
team response to a throttling-driven latency or reliability problem is to raise requests (to get a
bigger, less-contended slice) and add replicas (to spread load), rather than diagnose throttling as
the root cause. Both responses increase total requested CPU without increasing real headroom
against actual usage. Dropping the limit removes the throttling that motivates this pattern in the
first place, so bursts ride idle CPU instead of forcing requests upward.

## Worked model, using the example fleet from 04-measuring.md

| | Cores |
|---|---|
| Total CPU requested | 465 |
| Total CPU used (24h average) | 88 |
| Total CPU used (24h P95 peak) | 120 |
| Node allocatable | 870 |

Requests here run at roughly 5.3x average usage (465 / 88) and 3.9x the P95 peak (465 / 120). If
requests were right-sized to 2x the measured P95 peak (size on the peak, not the average - 2x is a
conservative buffer on top of that), total requested CPU would be approximately:

```
right_sized_requests ~= 2 x peak_used = 2 x 120 = ~240 cores
```

That's roughly half of the original 465 requested cores. Since node-pool sizing follows requests,
the same workloads would fit in roughly half the node capacity currently reserved for them,
freeing:

```
cores_freed = current_requests - right_sized_requests = 465 - 240 = ~225 cores
```

At a representative cloud rate of ~$35-50/core-month (varies heavily by VM SKU, region, and
reservation/savings-plan discount), 225 freed cores is on the order of **$8-11k/month, ~$95-135k a
year** - for one fleet segment. Treat any such headline number as "the size of the opportunity
worth investigating," derived with your own real per-VM-SKU pricing, not a number to put in a
budget line without redoing the math locally.

## This is an upper bound, not a forecast

This model assumes every service can be right-sized uniformly to 2x its share of the aggregate P95
peak. Real usage is not evenly distributed - some services are far hotter than others - and some
need headroom above 2x for legitimate burst patterns. Turning this into an actual savings plan
requires per-service 30-day P95 usage analysis (see [06-rollout.md](06-rollout.md) step 5), not a
single fleet-wide ratio.

## The memory floor: not every freed CPU core removes a VM

A VM leaves only when *both* its CPU and its memory are free. If a node pool is memory-bound
(stateful workloads with large, hand-sized memory reservations - a search/index cluster is a
typical example), right-sizing CPU alone won't shrink it: the memory reservation is what's pinning
those nodes, and often those same memory-heavy pods are also the fleet's heaviest real CPU
consumers, so their freed CPU requests yield no savings at all. General-purpose, cluster-autoscaled
pools see the fullest benefit; hand-sized, memory-full pools see little to none. Measure memory
request-vs-allocatable per node pool before promising a CPU-only number turns into a specific VM
count.

## Mechanics of realizing savings

Removing CPU limits frees nothing by itself. After request right-sizing:

- General-purpose pools under a cluster autoscaler (e.g. Karpenter) consolidate automatically as
  requests shrink.
- Hand-sized pools (search indexes, monitoring, system components) need a one-time, deliberate size
  change - they won't shrink on their own, and some (a primary search/index cluster, for example)
  shouldn't shrink at all.
- Consolidation can be blocked per node by strict PodDisruptionBudgets, pods with local storage, or
  do-not-disrupt annotations. Check these when a node that should drain doesn't.
- On the billing side, savings land when reserved capacity rolls off or is reused - a removed VM
  lowers *usage*, not necessarily the invoice, until that happens.

Next: [06-rollout.md](06-rollout.md) - the staged plan that gets you from today's numbers to these.
