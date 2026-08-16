#!/usr/bin/env python3
"""Open-loop HTTP loadgen, stdlib only. Schedule is wall clock, not
'after the last response'."""
from __future__ import annotations

import argparse
import json
import math
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass


@dataclass
class Sample:
    ok: bool
    timeout: bool
    ms: float
    warmup: bool


def percentile(sorted_vals: list[float], q: float) -> float:
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    idx = min(n - 1, math.ceil(q * n) - 1)
    return sorted_vals[max(0, idx)]


def fire(url: str, timeout: float, warmup: bool, out: list[Sample], lock: threading.Lock):
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            resp.read()
            ok = 200 <= resp.status < 300
            ms = (time.perf_counter() - t0) * 1000
            with lock:
                out.append(Sample(ok, False, ms, warmup))
    except TimeoutError:
        ms = (time.perf_counter() - t0) * 1000
        with lock:
            out.append(Sample(False, True, ms, warmup))
    except urllib.error.URLError as e:
        ms = (time.perf_counter() - t0) * 1000
        timed_out = isinstance(getattr(e, "reason", None), TimeoutError) or "timed out" in str(e).lower()
        with lock:
            out.append(Sample(False, timed_out, ms, warmup))
    except Exception:
        ms = (time.perf_counter() - t0) * 1000
        with lock:
            out.append(Sample(False, False, ms, warmup))


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--rps", type=float, required=True)
    p.add_argument("--duration", type=float, required=True)
    p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--warmup", type=float, default=5.0)
    args = p.parse_args()
    if args.rps <= 0 or args.duration <= 0:
        print("rps and duration must be > 0", file=sys.stderr)
        return 1

    interval = 1.0 / args.rps
    total = args.warmup + args.duration
    samples: list[Sample] = []
    lock = threading.Lock()
    threads: list[threading.Thread] = []
    sent = 0

    print(
        f"load: url={args.url} rps={args.rps} duration={args.duration}s "
        f"warmup={args.warmup}s timeout={args.timeout}s",
        flush=True,
    )

    t0 = time.perf_counter()
    next_tick = 0.0
    while True:
        now = time.perf_counter() - t0
        if now >= total:
            break
        wait = next_tick - now
        if wait > 0:
            time.sleep(wait)
        now = time.perf_counter() - t0
        is_warmup = now < args.warmup
        if not is_warmup:
            sent += 1
        th = threading.Thread(
            target=fire,
            args=(args.url, args.timeout, is_warmup, samples, lock),
            daemon=True,
        )
        th.start()
        threads.append(th)
        next_tick += interval

    deadline = time.time() + args.timeout
    for th in threads:
        remaining = deadline - time.time()
        th.join(timeout=max(0.0, remaining))

    measured = [s for s in samples if not s.warmup]
    oks = [s.ms for s in measured if s.ok]
    errors = sum(1 for s in measured if not s.ok and not s.timeout)
    timeouts = sum(1 for s in measured if s.timeout)
    oks.sort()

    def f1(v: float) -> float:
        return round(v, 1)

    p50 = f1(percentile(oks, 0.50))
    p95 = f1(percentile(oks, 0.95))
    p99 = f1(percentile(oks, 0.99))
    mx = f1(oks[-1] if oks else 0.0)

    print(f"sent={sent} ok={len(oks)} errors={errors} timeouts={timeouts}")
    print(f"latency ms: p50={p50} p95={p95} p99={p99} max={mx}")
    result = {
        "url": args.url,
        "rps": args.rps,
        "durationSec": args.duration,
        "sent": sent,
        "ok": len(oks),
        "errors": errors,
        "timeouts": timeouts,
        "p50": p50,
        "p95": p95,
        "p99": p99,
        "max": mx,
    }
    print("RESULT_JSON: " + json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
