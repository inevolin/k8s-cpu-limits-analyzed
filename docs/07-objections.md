# Objections: the deeper FAQ

The README's FAQ covers the quick version of these. This goes further into the ones that come up once a team is actually planning a rollout.

## Won't a noisy neighbor eat all the CPU without a limit?

No. CPU requests set cgroup `cpu.weight`, which governs proportional access to CPU *only when the
node is contended*. A pod with no limit and a normal request still only gets a share of contended
CPU proportional to its request, same as every other pod. Worst case, an unlimited pod uses CPU
nobody else wants (idle capacity); it cannot take CPU another pod's weight entitles it to under
contention.

This repo's lab measures exactly this (`scripts/run.sh`, the hog and saturate legs): a CPU-burning
hog with no limit of its own lands on the node, and the unlimited victim's p99 barely moves, with
no throttling - even when the hog is scaled up until the node is actually full. See
`results/run.md`. A separate four-way run of the same shape (limited and unlimited victims, hog on
and off) added one more data point: the limited victim under hog pressure was still slower than the
unlimited victim under identical pressure. **The limit provides no benefit to its own pod.**

## What if a pod runs away and tries to use everything?

`cpu.weight` proportionality still applies: a runaway pod competes for contended CPU on the same
terms as everyone else, weighted by requests. The kubelet and system also reserve CPU
(`--system-reserved`, `--kube-reserved`) so node-critical processes are never starved by workload
pods. The node stays healthy; the runaway pod's own containers get throttled by contention, not by
a hard quota wall, and other pods keep their requested share.

## Doesn't a limit make performance more predictable?

The opposite, in practice. A fleet with limits everywhere and hundreds of containers in the severe
throttle band (see [04-measuring.md](04-measuring.md)) shows limits actively causing unpredictable
stalls, not preventing them. Limits make usage predictable *in aggregate*; they make *latency* less
predictable, because throttling is a discontinuous stall, not a gradual slowdown (see
[01-theory.md](01-theory.md)).

## Does this break HorizontalPodAutoscaler or KEDA?

No to both. HPA scales on measured usage against requests (for `cpu` metric type `Utilization`) or
on raw/external metrics - dropping the CPU limit changes neither. KEDA scales on external event
metrics (queue depth, consumer lag, etc.), not on CPU limits at all. Nothing currently scales on CPU
limits, so there's nothing to break.

## We have no ResourceQuota or LimitRange yet - isn't a CPU limit a needed circuit breaker?

This is a common platform-team position: without governance, set the limit high (well above real
usage) "as a circuit breaker rather than a ceiling." The governance gap is real and worth closing.
The remedy doesn't do what it appears to:

- **A pod's own CPU limit never protects its neighbors, only itself.** Neighbor A is protected from
  greedy pod B by *A's own request* (A's `cpu.weight`). A limit on B contributes nothing to A.
- **A missing or tiny request makes a pod the victim, not the aggressor.** It receives the smallest
  weight and is squeezed first under contention. Blanket CPU limits don't give it protection.
- **The scheduler is the real circuit breaker.** A pod is only placed if its *request* fits, so
  total requests never exceed node capacity. Limits play no role in that guarantee.
- **The dilemma:** a limit set high enough never to trip (e.g. 30x real usage) protects nobody
  because it never acts; a limit low enough to trip only harms the pod it's attached to. It cannot
  be both a safety mechanism and harmless.
- **Sizing warning:** don't size a limit from usage measured under a limit. A pod throttled in
  98.9% of CFS periods (see [02-runtimes.md](02-runtimes.md)) has recorded usage that reflects what
  the limit permitted, not what the workload demanded. Sizing from suppressed usage produces the
  next too-small limit.

What's actually needed is exactly what the concern names, and it's rollout step 3 (deliberately
*before* limit removal): a `LimitRange` supplying default requests, plus a `ResourceQuota` on
`requests.cpu` per namespace. Both act on requests, both are roughly one PR per namespace, and
neither is blocked by removing CPU limits. See [06-rollout.md](06-rollout.md).

## What about multi-tenant namespaces? Don't limits protect the cluster?

Cluster-level protection against runaway *requests*, not runaway usage, is what actually needs
guarding: a `ResourceQuota` on `requests.cpu` per namespace caps how much a team can request in
total, and a `LimitRange` can set default requests for containers that omit them. Both operate on
requests, independent of whether CPU limits exist. If everything still runs in one shared namespace,
a namespace-wide quota there is a fat-finger backstop, not per-team isolation - and that's fine: the
scheduler already refuses pods whose requests don't fit, so a missing quota risks extra node cost,
not an outage.

## But today's requests are tiny. Isn't the fair-share protection theoretical?

Partly, and the fix rides along for free. `cpu.weight` protection is only as good as the requests,
and a low org-wide default can sit below real usage in many places. But every limit removal is
itself a values-file PR, and a gitops convention that mandates an explicit `requests.cpu` means the
same PR that drops the limit confirms the request exists and raises an obviously-too-low one (see
[06-rollout.md](06-rollout.md) step 4). No fleet-wide re-sizing has to finish before starting -
requests become honest service by service, at the same pace limits disappear.

## Couldn't we right-size requests and keep the limits? Isn't that where the savings are?

The savings do come from right-sizing, not from limit removal itself - removing limits frees zero
nodes on its own ([05-cost.md](05-cost.md)). But right-sizing *under* limits fails twice: usage
measured under throttling is suppressed, not real demand, so you size from wrong data; and the
throttling that motivates request inflation stays, so requests creep back up. Limit removal is the
enabler that makes measured usage honest; right-sizing is the saving. Present them as two linked
steps, not one number.

## What happens when a node runs hot without limits?

Nothing breaks: every pod keeps its requested share (CFS), and the OS and kubelet have reserved
CPU. What shrinks is the idle headroom pods borrow above their requests. The node-pressure alert is
therefore a capacity signal, not a fire alarm: it means some request is set too low (one gitops fix)
or the cluster genuinely needs another node.

## Does removing the limit change QoS class or eviction behavior?

Only for pods where `requests == limits` (Guaranteed QoS): removing the CPU limit demotes them to
Burstable, which lowers their protection under node *memory* pressure. Most fleets' default shape
(small request / small limit) is already Burstable, so this affects few pods - an inventory pass
(rollout step 3) finds them, and each is a one-line decision in its own removal PR (intentional
Guaranteed keeps its limit; the rest just keep an explicit request). Note also: the kubelet ranks
pods for eviction by how far usage exceeds the *request*, not purely by QoS class, so an honest
request matters here too.

## When do CPU limits actually make sense?

- **Untrusted or third-party workloads**, where you can't trust the requester to set honest
  requests and want a hard backstop regardless of node contention.
- **Benchmarking or reproducibility**, where you deliberately want a fixed, repeatable CPU ceiling
  for comparison runs, independent of what else is on the node.
- **Guaranteed QoS with static CPU manager**, where request == limit is required to get exclusive
  core pinning, and the "limit" is doing core assignment, not CFS quota throttling (see
  [01-theory.md](01-theory.md)).
- **Multi-tenant platforms where the cap is the product** - you sell or bill a fixed amount of CPU
  per customer, so the limit is a commercial boundary, not a technical safety net.

None of these describe the bulk of a typical internal-services fleet.

## Why keep memory limits, then?

CPU is compressible: a throttled process just runs slower (or stalls) and can catch up later.
Memory is not: a process that needs more memory than is available cannot "wait" for memory to free
up the way it waits for CPU time. Without a memory limit, a leaking or oversized pod can exhaust
node memory and take other pods down with it (OOM at the node level, not just the pod level). A
memory limit turns that into a contained, single-pod OOM kill. That protection has no CPU
equivalent worth keeping the downside for.
