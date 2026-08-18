# Rollout: a staged, reversible plan

Every step below is gitops-only and reversible with a one-line revert. No direct cluster edits, no big-bang cutover.

## Step 1: pin the runtime's processor-count knob, first

Before touching any limit, set an org-wide runtime default (e.g. `DOTNET_PROCESSOR_COUNT=4` for
.NET services) in the shared chart: one PR, no per-service bookkeeping, per-service override only
where needed. Do **not** derive it from `requests.cpu` via the downward API yet - with typical
10m-250m requests that rounds up to 1 and recreates the small-ThreadPool problem (see
[02-runtimes.md](02-runtimes.md)); the downward-API form only becomes attractive after step 5
right-sizes requests.

Non-.NET runtimes have the same problem with different knobs, and some get *worse* without a limit:
Go defaults `GOMAXPROCS` to all node cores, the JVM sizes thread pools from `ActiveProcessorCount`
(cgroup-aware), Python/worker counts are usually explicit config already. **Rule: no service's CPU
limit is dropped until its runtime's processor-count knob is pinned.** Wave 1 covers the dominant
runtime via the shared chart; other runtimes get their env var in the same PR that drops their
limit.

## Step 2: observability first

Add dashboard panels and alerts for: 24h throttle ratio per container (the basis of
[04-measuring.md](04-measuring.md)), and node-level CPU pressure (allocatable vs. actual usage, per
node pool). These need to exist and be trusted *before* removing limits, so the rollout has a clear
"did this help" signal and a clear "is a node actually under pressure" signal, independent of any
one team's opinion.

The node-pressure alert is a **capacity signal, not a fire alarm**: a hot node still gives every pod
its requested share, it just stops handing out free headroom. The alert means some request is set
too low (one gitops fix) or the cluster genuinely needs another node. A short runbook and a clear
owner close that loop; without it, right-sized requests silently rot.

## Step 3: guardrails (cheap backstops, not blockers)

None of these need to gate limit removal. The real safeguard is the removal PR itself: a gitops
convention that mandates an explicit `requests.cpu` on every service means each removal PR touches
the exact file where a missing request would be visible. One checklist line covers it: confirm
`requests.cpu` is explicitly present (a file that sets only a limit may have been getting an
implicit request from the API server; deleting the limit would delete that too).

- `LimitRange` per namespace: default CPU/memory *requests* for strays that bypass the gitops
  convention (third-party charts, hand-written jobs). One manifest, do it early, don't wait on it.
- `ResourceQuota` per namespace on `requests.cpu` (and `requests.memory`). Not a blocker: the
  scheduler already refuses pods whose requests don't fit, so a missing quota risks node cost, not
  stability. It can trail limit removal; per-team quotas need a namespace split anyway.
- One-time check: any policy engine (Gatekeeper, Kyverno, or your cloud's native policy service)
  enforcing "containers must set limits," before the first higher-environment PR, so a compliance
  dashboard doesn't go red as a surprise.
- One-time check: inventory the few services running `requests == limits` (Guaranteed QoS). Each is
  either intentional (keep as-is, e.g. a database or search cluster running Guaranteed on purpose)
  or a values file that only set a limit (fix in its removal PR). Any other deviations that surface
  during rollout are the same shape: a one-line values fix, not a rollback.

## Step 4: drop CPU limits, namespace by namespace, env by env

Order: dev -> staging -> prod (or whatever your environment chain is). Within an env, roll out namespace by namespace (or service
by service for high-risk services), not fleet-wide in one PR. Each PR removes the `cpu` key under
`resources.limits`; `resources.limits.memory` stays untouched. Where a request is obviously
dishonest (e.g. 10m against 100m+ real usage), raise it toward measured P95 *in the same PR*: the
request is the neighbor protection, so it must be roughly honest the moment the limit disappears.
Fine-tuning still happens in step 5.

```diff
 resources:
   requests:
-    cpu: 40m
+    cpu: 40m        # keep honest; revisit in step 5 against P95 usage
     memory: 160Mi
   limits:
-    cpu: 300m
     memory: 512Mi
```

Only `limits.cpu` is removed. `requests.cpu`, `requests.memory`, and `limits.memory` are untouched.

Watch the step-2 panels for a burn-in period (a few days is reasonable for dev/qa; longer for
acc/prod) before moving to the next namespace. During a higher-environment burn-in, run one
resilience test at post-rollout density: drain a node under load and mass-restart a namespace,
confirming readiness/liveness probes don't flap under the simultaneous startup burst. Early safety
evidence is often gathered at low node utilization; the cost plan intentionally raises that, so
failure behavior at higher density needs one deliberate check, not an assumption.

## Step 5: right-size requests from real usage

Once limits are gone and step-2 panels are live, pull 30-day P95 CPU usage per service and compare
it to the current request. This is the point at which the cost model in
[05-cost.md](05-cost.md) becomes a real number instead of an illustration: adjust requests toward
P95 (with reasonable headroom), service by service, again via gitops PRs.

Memory limits stay everywhere, always. This rollout never touches `resources.limits.memory`.

## Step 6: rollback

Rollback is a one-line gitops revert: restore the `cpu` key under `resources.limits` in the
affected values file and merge. Your GitOps controller (e.g. ArgoCD) picks it up on the next sync,
same as any other config change. No cluster access, no manual intervention, no downtime beyond a
normal rolling update.

Next: [07-objections.md](07-objections.md) - the deeper FAQ, for the questions this plan raises.
