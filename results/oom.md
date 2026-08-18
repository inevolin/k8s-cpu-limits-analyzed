# oom run

2026-08-18 11:33 GMTDT. context `rancher-desktop`, namespace `cpu-lab`.
Same app, same 1Gi memory limit, same 20 rps of jobs
(40ms CPU each, 2097152 bytes of native memory held
until processed). Demand ~800m. Only delta: `limits.cpu: 500m`.

| | restarts | last termination | throttle before death |
|---|---|---|---|
| 500m limit | 1 | OOMKilled (exit 137) | 83.33% of CFS periods |
| no limit | 0 | none | - |

OOMKilled after: 25s of load.

Last sample, 500m limit pod: `{"queueDepth":210,"queuedBytes":440401920,"processed":163,"gcHeapBytes":3272544,"workingSetBytes":539365376,"memoryCurrent":"1072078848","memoryMax":"1073741824"}`
Last sample, no-limit pod:   `{"queueDepth":0,"queuedBytes":0,"processed":600,"gcHeapBytes":4233632,"workingSetBytes":97042432,"memoryCurrent":"786321408","memoryMax":"1073741824"}`

```
oom-limit-75cc47b647-pr2lq   1     OOMKilled   137
oom-open-689c68ff7d-n8s7k    0     <none>      <none>
```

Raw samples: `results/oom.jsonl`.
