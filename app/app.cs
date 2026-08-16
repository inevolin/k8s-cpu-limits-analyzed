#:sdk Microsoft.NET.Sdk.Web
// File-based .NET 10 app. Minimal APIs here return raw JSON strings
// because the default AOT-ish serializer rejects anonymous objects.
using System.Diagnostics;
using System.Globalization;
using System.Runtime;
using System.Text;

var app = WebApplication.CreateBuilder(args).Build();

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

app.Run();

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
