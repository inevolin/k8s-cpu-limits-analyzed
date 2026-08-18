# oom run

2026-08-18 11:42 GMTDT. context `rancher-desktop`, namespace `cpu-lab`.
Same app, same 1Gi memory limit, same 20 rps of jobs
(40ms CPU each, 2097152 bytes of native memory held
until processed). Demand ~800m. Only delta: `limits.cpu: 500m`.

| | restarts | last termination | throttle before death |
|---|---|---|---|
| 500m limit | 1 | OOMKilled (exit 137) | 85.37% of CFS periods |
| no limit | 0 | none | - |

OOMKilled after: 23s of load.

Last sample, 500m limit pod: `{"queueDepth":306,"queuedBytes":641728512,"processed":276,"gcHeapBytes":3786536,"workingSetBytes":809771008,"memoryCurrent":"1073307648","memoryMax":"1073741824"}`
Last sample, no-limit pod:   `{"queueDepth":1,"queuedBytes":2097152,"processed":555,"gcHeapBytes":3515416,"workingSetBytes":99704832,"memoryCurrent":"805658624","memoryMax":"1073741824"}`

Drain rates (the capped worker kept processing until the kill, just
slower than the 20/s arrival rate):

```
oom-limit: drained 10.0 jobs/s over the sampled 23s
oom-open: drained 20.3 jobs/s over the sampled 23s
```

```
oom-limit-75cc47b647-9tt2v   1     OOMKilled   137
oom-open-689c68ff7d-z2z65    0     <none>      <none>
```

Raw samples: `results/oom.jsonl`.
