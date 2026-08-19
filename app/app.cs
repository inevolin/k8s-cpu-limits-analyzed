#:sdk Microsoft.NET.Sdk.Web
// File-based .NET 10 app. Minimal APIs here return raw JSON strings
// because the default AOT-ish serializer rejects anonymous objects.
using System.Diagnostics;
using System.Globalization;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;

var app = WebApplication.CreateBuilder(args).Build();

// --- gc lab state ------------------------------------------------------
// A fixed-size ring of managed buffers. Every /churn request allocates one
// buffer and overwrites the oldest slot, so the *live* set is constant
// (slots x size) and identical on both pods no matter how fast either one
// is served. The evicted buffer is unreachable but has been alive long
// enough to be promoted, so reclaiming it costs a gen2 collection. Any
// heap growth past the live set is therefore garbage the collector has
// not caught up with, not retention: this isolates GC lag from backlog.
var gcRing = new byte[4096][];
long gcSlot = -1, gcChurned = 0;
var gcRingLock = new object();
long gcInflight = 0, gcWorked = 0;

// --- oom lab state -----------------------------------------------------
// Work queue whose payloads live in *native* memory (malloc), so the .NET
// GC heap hard limit never intervenes and the kernel OOM killer is the
// only backstop, same as a queue in Node/Python/Go/C++ or any native
// buffer pool. One worker drains it; each job costs cpuMs of CPU-time.
var oomQueue = Channel.CreateUnbounded<(IntPtr Ptr, int Bytes, int CpuMs)>(
    new UnboundedChannelOptions { SingleReader = true });
long oomQueuedBytes = 0, oomDepth = 0, oomProcessed = 0;
var oomTemplate = new byte[1 << 20];
new Random(1).NextBytes(oomTemplate);

// --- web lab state -----------------------------------------------------
// Nothing here is a queue, a buffer, or a background worker. The /render
// handler below allocates its working memory, uses it, and frees it before
// it returns; no request's memory outlives the request. What holds memory
// is only the *number of requests running at once*, which is Little's Law
// (in flight = arrival rate x service time) and which a CPU limit sets by
// stretching service time. Nothing in ASP.NET Core bounds it by default:
// Kestrel's MaxConcurrentConnections is null (unlimited) and there is no
// request-concurrency cap unless the app adds rate limiting itself.
// webCompleted counts handlers that ran to completion, faulted ones
// included: the increment is in the finally. It is not a count of
// responses delivered - a client that timed out long ago still has its
// handler running here, which is the point of the shape.
long webInflight = 0, webPeakInflight = 0, webCompleted = 0, webHeldBytes = 0;

app.MapGet("/healthz", () => "ok");

app.MapGet("/info", () =>
{
    ThreadPool.GetMinThreads(out var minW, out _);
    ThreadPool.GetMaxThreads(out var maxW, out _);

    var heapCount = "n/a";
    try
    {
        foreach (var kv in GC.GetConfigurationVariables())
        {
            if (kv.Key.Contains("HeapCount", StringComparison.OrdinalIgnoreCase))
            {
                heapCount = Convert.ToString(kv.Value, CultureInfo.InvariantCulture) ?? "n/a";
                break;
            }
        }
    }
    catch { }

    var host = Environment.GetEnvironmentVariable("HOSTNAME") ?? Environment.MachineName;
    var json = "{"
        + $"\"processorCount\":{Environment.ProcessorCount},"
        + $"\"threadPoolThreads\":{ThreadPool.ThreadCount},"
        + $"\"minWorkerThreads\":{minW},"
        + $"\"maxWorkerThreads\":{maxW},"
        + $"\"serverGC\":{(GCSettings.IsServerGC ? "true" : "false")},"
        + $"\"gcHeapCount\":{J(heapCount)},"
        + $"\"cpuMax\":{J(ReadOrNa("/sys/fs/cgroup/cpu.max"))},"
        + $"\"hostname\":{J(host)}"
        + "}";
    return Results.Text(json, "application/json");
});

app.MapGet("/work", (int? ms) =>
{
    var want = ms ?? 30;
    var got = Spin(want);
    return Results.Text($"{{\"requestedMs\":{want},\"elapsedMs\":{F(got)}}}", "application/json");
});

app.MapGet("/mixed", async (int? cpuMs, int? ioMs) =>
{
    var cpu = cpuMs ?? 15;
    var io = ioMs ?? 30;
    var sw = Stopwatch.StartNew();
    Spin(cpu);
    await Task.Delay(io);
    return Results.Text(
        $"{{\"cpuMs\":{cpu},\"ioMs\":{io},\"elapsedMs\":{F(sw.Elapsed.TotalMilliseconds)}}}",
        "application/json");
});

app.MapGet("/burst", async (int? threads, int? ms) =>
{
    var n = threads ?? 8;
    var each = ms ?? 5;
    var sw = Stopwatch.StartNew();
    var tasks = new Task[n];
    for (var i = 0; i < n; i++)
        tasks[i] = Task.Run(() => Spin(each));
    await Task.WhenAll(tasks);
    return Results.Text(
        $"{{\"threads\":{n},\"msEach\":{each},\"elapsedMs\":{F(sw.Elapsed.TotalMilliseconds)}}}",
        "application/json");
});

app.MapGet("/churn", (int? kb, int? slots, int? count) =>
{
    // 64 KiB default: comfortably under the 85,000-byte LOH threshold, so
    // these are ordinary heap allocations that must survive gen0 and be
    // promoted, which is the expensive path. LOH objects would skip
    // straight to gen2 and tell a different story.
    var size = Math.Clamp(kb ?? 64, 1, 4096) * 1024;
    var ring = Math.Clamp(slots ?? 2048, 1, gcRing.Length);
    // buffers per request: lets one modest request rate produce a real
    // allocation rate, instead of needing thousands of HTTP requests/s
    var n = Math.Clamp(count ?? 32, 1, 4096);

    long slot = 0;
    for (var k = 0; k < n; k++)
    {
        var buf = new byte[size];
        // touch every page: an untouched array may never be committed
        for (var i = 0; i < buf.Length; i += 4096) buf[i] = 1;
        lock (gcRingLock)
        {
            slot = (gcSlot + 1) % ring;
            gcSlot = slot;
            gcRing[slot] = buf;   // evicts the previous occupant -> promoted garbage
        }
    }
    var total = Interlocked.Add(ref gcChurned, n);
    return Results.Text(
        $"{{\"churned\":{total},\"perRequestBytes\":{(long)n * size},\"liveSetBytes\":{(long)ring * size}}}",
        "application/json");
});

app.MapGet("/gcwork", async (int? nodes, int? cpuMs) =>
{
    // The churn ring above shows GC *lag*; this shows the GC *spiral*.
    // Each request builds a reference-dense graph of small objects (mark
    // cost scales with object count, not bytes - a byte[] is the cheapest
    // thing a collector can trace) and holds it while doing real CPU
    // work. Work arrives open-loop from outside, so on a capped pod the
    // in-flight count grows, the live object count grows with it, every
    // GC cycle gets more expensive, and the collector and the workload
    // fight over the same shrinking quota. An uncapped pod holds a
    // handful of requests in flight and never notices.
    var n = Math.Clamp(nodes ?? 10_000, 1, 1_000_000);
    var cost = Math.Clamp(cpuMs ?? 40, 0, 10_000);

    var graph = new object[n][];
    object[]? prev = null;
    for (var i = 0; i < n; i++)
    {
        var node = new object[3];
        node[0] = new string('x', 8 + (i & 31)); // distinct string per node
        node[1] = prev;                          // reference chain: real mark work
        node[2] = i;
        prev = node;
        graph[i] = node;
    }

    var inflight = Interlocked.Increment(ref gcInflight);
    try
    {
        await Task.Run(() => SpinCpu(cost));     // hold the graph during the work
    }
    finally
    {
        Interlocked.Decrement(ref gcInflight);
    }
    // touch the graph after the work so the runtime cannot collect it early
    var checksum = ((string)graph[n - 1][0]!).Length;
    var total = Interlocked.Increment(ref gcWorked);
    return Results.Text(
        $"{{\"worked\":{total},\"nodes\":{n},\"cpuMs\":{cost},\"inflight\":{inflight},\"check\":{checksum}}}",
        "application/json");
});

app.MapGet("/gcstats", () =>
{
    var info = GC.GetGCMemoryInfo();
    var json = "{"
        + $"\"churned\":{Interlocked.Read(ref gcChurned)},"
        + $"\"worked\":{Interlocked.Read(ref gcWorked)},"
        + $"\"inflight\":{Interlocked.Read(ref gcInflight)},"
        + $"\"heapSizeBytes\":{info.HeapSizeBytes},"
        + $"\"fragmentedBytes\":{info.FragmentedBytes},"
        + $"\"committedBytes\":{info.TotalCommittedBytes},"
        + $"\"heapHardLimitBytes\":{info.TotalAvailableMemoryBytes},"
        + $"\"pauseTimePercentage\":{info.PauseTimePercentage.ToString("F2", CultureInfo.InvariantCulture)},"
        + $"\"gen0\":{GC.CollectionCount(0)},"
        + $"\"gen1\":{GC.CollectionCount(1)},"
        + $"\"gen2\":{GC.CollectionCount(2)},"
        + $"\"totalAllocatedBytes\":{GC.GetTotalAllocatedBytes(false)},"
        + $"\"managedHeapBytes\":{GC.GetTotalMemory(false)},"
        + $"\"workingSetBytes\":{Environment.WorkingSet},"
        + $"\"memoryCurrent\":{J(ReadOrNa("/sys/fs/cgroup/memory.current"))},"
        + $"\"memoryMax\":{J(ReadOrNa("/sys/fs/cgroup/memory.max"))}"
        + "}";
    return Results.Text(json, "application/json");
});

app.MapGet("/enqueue", (int? bytes, int? cpuMs) =>
{
    var size = Math.Clamp(bytes ?? (2 << 20), 1, 64 << 20);
    var cost = Math.Clamp(cpuMs ?? 40, 0, 10_000);
    var ptr = Marshal.AllocHGlobal(size);
    // touch every page so the memory is actually committed, not just reserved
    for (var off = 0; off < size; off += oomTemplate.Length)
    {
        var n = Math.Min(oomTemplate.Length, size - off);
        Marshal.Copy(oomTemplate, 0, IntPtr.Add(ptr, off), n);
    }
    Interlocked.Add(ref oomQueuedBytes, size);
    var depth = Interlocked.Increment(ref oomDepth);
    if (!oomQueue.Writer.TryWrite((ptr, size, cost)))
    {
        Marshal.FreeHGlobal(ptr);
        Interlocked.Add(ref oomQueuedBytes, -size);
        Interlocked.Decrement(ref oomDepth);
        return Results.Text("{\"error\":\"queue closed\"}", "application/json", statusCode: 503);
    }
    return Results.Text($"{{\"queued\":{depth},\"bytes\":{size},\"cpuMs\":{cost}}}", "application/json");
});

app.MapGet("/memstats", () =>
{
    var json = "{"
        + $"\"queueDepth\":{Interlocked.Read(ref oomDepth)},"
        + $"\"queuedBytes\":{Interlocked.Read(ref oomQueuedBytes)},"
        + $"\"processed\":{Interlocked.Read(ref oomProcessed)},"
        + $"\"gcHeapBytes\":{GC.GetTotalMemory(false)},"
        + $"\"workingSetBytes\":{Environment.WorkingSet},"
        + $"\"memoryCurrent\":{J(ReadOrNa("/sys/fs/cgroup/memory.current"))},"
        + $"\"memoryMax\":{J(ReadOrNa("/sys/fs/cgroup/memory.max"))}"
        + "}";
    return Results.Text(json, "application/json");
});

app.MapGet("/cgstats", () =>
{
    long periods = 0, throttled = 0, usec = 0;
    try
    {
        foreach (var line in File.ReadAllLines("/sys/fs/cgroup/cpu.stat"))
        {
            var p = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (p.Length != 2) continue;
            switch (p[0])
            {
                case "nr_periods": periods = long.Parse(p[1]); break;
                case "nr_throttled": throttled = long.Parse(p[1]); break;
                case "throttled_usec": usec = long.Parse(p[1]); break;
            }
        }
    }
    catch { }

    var json = "{"
        + $"\"nrPeriods\":{periods},"
        + $"\"nrThrottled\":{throttled},"
        + $"\"throttledUsec\":{usec},"
        + $"\"cpuMax\":{J(ReadOrNa("/sys/fs/cgroup/cpu.max"))}"
        + "}";
    return Results.Text(json, "application/json");
});

app.MapGet("/render", async (int? bytes, int? cpuMs, int? ioMs, bool? native) =>
{
    // One ordinary async request handler, shaped like a real one: build the
    // working set (a decoded image, a deserialized result set, a report
    // being assembled), await a downstream dependency, then do the CPU work
    // on it and free it. Both pods run byte-identical code with an
    // identical per-request footprint. A CPU limit cannot change the
    // footprint (that is the code) or the arrival rate (that is the
    // client), so it changes service time - and in-flight count rises to
    // match, because in flight = arrival rate x service time.
    //
    // The await is what makes this shape: it releases the thread while the buffer
    // stays allocated, so the pile-up is *not* bounded by ThreadPool size:
    // the continuation waits in the ThreadPool queue still holding its
    // memory. Allocating after the await instead would put the backlog in
    // the queue as a few hundred bytes per entry and nothing would grow -
    // which is exactly what an app that streams instead of buffering gets.
    var size = Math.Clamp(bytes ?? (2 << 20), 1, 64 << 20);
    var cost = Math.Clamp(cpuMs ?? 40, 0, 10_000);
    var io = Math.Clamp(ioMs ?? 200, 0, 60_000);
    // Native by default, for the same reason the backlog lab uses malloc:
    // .NET caps its own managed heap at 75% of memory.max, so a managed
    // buffer runs into GC pressure (that is shape 2, scripts/gc.sh) before
    // the kernel OOM killer is ever reached. Native memory has no such
    // backstop, and it is what a handler holding an image, a decompressed
    // payload, a pooled pinned buffer or a native driver's result set
    // actually looks like. Pass native=false to see the managed variant
    // hit the GC wall instead of the kernel: same cause, different symptom.
    var useNative = native ?? true;

    var inflight = Interlocked.Increment(ref webInflight);
    long peak;
    while ((peak = Interlocked.Read(ref webPeakInflight)) < inflight
        && Interlocked.CompareExchange(ref webPeakInflight, inflight, peak) != peak) { }
    Interlocked.Add(ref webHeldBytes, size);

    var ptr = IntPtr.Zero;
    byte[]? managed = null;
    try
    {
        if (useNative)
        {
            ptr = Marshal.AllocHGlobal(size);
            // touch every page so the memory is actually committed
            for (var off = 0; off < size; off += oomTemplate.Length)
                Marshal.Copy(oomTemplate, 0, IntPtr.Add(ptr, off),
                    Math.Min(oomTemplate.Length, size - off));
        }
        else
        {
            managed = GC.AllocateUninitializedArray<byte>(size);
            for (var i = 0; i < managed.Length; i += 4096) managed[i] = 1;
        }

        // downstream dependency: releases the thread, keeps the buffer
        await Task.Delay(io);

        // CPU work on the buffer. No cancellation check on purpose: a
        // client timing out does not stop a handler that already started,
        // which is how most real handlers behave and is why client-side
        // timeouts do not bound server memory.
        SpinCpu(cost);

        return Results.Text(
            $"{{\"bytes\":{size},\"cpuMs\":{cost},\"ioMs\":{io},\"native\":{(useNative ? "true" : "false")},\"inflight\":{inflight}}}",
            "application/json");
    }
    finally
    {
        if (ptr != IntPtr.Zero) Marshal.FreeHGlobal(ptr);
        GC.KeepAlive(managed);
        Interlocked.Add(ref webHeldBytes, -size);
        Interlocked.Decrement(ref webInflight);
        Interlocked.Increment(ref webCompleted);
    }
});

app.MapGet("/webstats", () =>
{
    var json = "{"
        + $"\"inflight\":{Interlocked.Read(ref webInflight)},"
        + $"\"peakInflight\":{Interlocked.Read(ref webPeakInflight)},"
        + $"\"completed\":{Interlocked.Read(ref webCompleted)},"
        + $"\"heldBytes\":{Interlocked.Read(ref webHeldBytes)},"
        + $"\"threadPoolThreads\":{ThreadPool.ThreadCount},"
        + $"\"pendingWorkItems\":{ThreadPool.PendingWorkItemCount},"
        + $"\"gcHeapBytes\":{GC.GetTotalMemory(false)},"
        + $"\"workingSetBytes\":{Environment.WorkingSet},"
        + $"\"memoryCurrent\":{J(ReadOrNa("/sys/fs/cgroup/memory.current"))},"
        + $"\"memoryAnon\":{J(CgStatField("anon"))},"
        + $"\"memoryFile\":{J(CgStatField("file"))},"
        + $"\"memoryMax\":{J(ReadOrNa("/sys/fs/cgroup/memory.max"))}"
        + "}";
    return Results.Text(json, "application/json");
});

// oom lab worker: drain the queue at whatever speed the CPU quota allows.
_ = Task.Run(async () =>
{
    await foreach (var job in oomQueue.Reader.ReadAllAsync())
    {
        try
        {
            SpinCpu(job.CpuMs);
        }
        catch (Exception ex)
        {
            // a dead worker would fake the backlog; keep draining, loudly
            Console.Error.WriteLine($"oom worker: {ex}");
        }
        Marshal.FreeHGlobal(job.Ptr);
        Interlocked.Add(ref oomQueuedBytes, -job.Bytes);
        Interlocked.Decrement(ref oomDepth);
        Interlocked.Increment(ref oomProcessed);
    }
});

app.Run();

// Burn `ms` of thread CPU-time, measured with CLOCK_THREAD_CPUTIME_ID.
// Spin() below measures wall-clock, so under CFS throttling the throttled
// gaps count toward the spin and the job's real CPU cost shrinks to fit
// the quota. For the oom lab each job must cost a fixed amount of CPU
// regardless of throttling, like real work would.
static void SpinCpu(double ms)
{
    var start = ThreadCpuMs();
    double x = 1.0;
    while (ThreadCpuMs() - start < ms)
    {
        for (var i = 0; i < 10_000; i++)
            x = Math.Sqrt(x + 1.0);
    }
    if (double.IsNaN(x)) throw new InvalidOperationException("unreachable");
}

static double ThreadCpuMs()
{
    if (ClockGetTime(3 /* CLOCK_THREAD_CPUTIME_ID */, out var ts) != 0)
        throw new InvalidOperationException("clock_gettime failed");
    return ts.Sec * 1000.0 + ts.Nsec / 1_000_000.0;
}

// versioned soname: the unversioned libc.so symlink is a -dev package
// nicety and not present on every base image
[DllImport("libc.so.6", EntryPoint = "clock_gettime", SetLastError = true)]
static extern int ClockGetTime(int clockId, out Timespec ts);

static double Spin(double ms)
{
    var sw = Stopwatch.StartNew();
    double x = 1.0;
    while (sw.Elapsed.TotalMilliseconds < ms)
    {
        for (var i = 0; i < 1000; i++)
            x = Math.Sqrt(x + 1.0);
    }
    if (double.IsNaN(x)) throw new InvalidOperationException("unreachable");
    return sw.Elapsed.TotalMilliseconds;
}

// memory.current includes reclaimable page cache; `anon` is the part the
// kernel cannot reclaim. The SDK image's in-pod compile leaves
// several hundred MiB of file cache behind, so reporting only
// memory.current would bury the in-flight set under startup noise.
static string CgStatField(string key)
{
    try
    {
        foreach (var line in File.ReadAllLines("/sys/fs/cgroup/memory.stat"))
        {
            var p = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (p.Length == 2 && p[0] == key) return p[1];
        }
    }
    catch { }
    return "n/a";
}

static string ReadOrNa(string path)
{
    try { return File.ReadAllText(path).Trim(); }
    catch { return "n/a"; }
}

static string J(string s)
{
    var sb = new StringBuilder(s.Length + 2);
    sb.Append('"');
    foreach (var c in s)
    {
        switch (c)
        {
            case '"': sb.Append("\\\""); break;
            case '\\': sb.Append("\\\\"); break;
            case '\n': sb.Append("\\n"); break;
            case '\r': sb.Append("\\r"); break;
            case '\t': sb.Append("\\t"); break;
            default:
                if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
                break;
        }
    }
    sb.Append('"');
    return sb.ToString();
}

static string F(double v) => v.ToString("F1", CultureInfo.InvariantCulture);

[StructLayout(LayoutKind.Sequential)]
struct Timespec
{
    public long Sec;
    public long Nsec;
}
