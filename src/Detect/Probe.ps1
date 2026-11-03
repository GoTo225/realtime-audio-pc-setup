# Real-time audio probe: simulates an audio callback thread and measures how late it finishes.
#
# An MMCSS "Pro Audio" thread (the same scheduling class DAWs and ASIO drivers use) wakes on a
# high-resolution timer every 64 samples at 48 kHz (1.33 ms) and does a fixed, calibrated amount of
# work. For each callback the extra delay is
#     (finish time - scheduled time) - undisturbed work time
# which captures everything that steals time from an audio thread: DPC/ISR load, scheduling
# latency, CPU frequency drops, SMIs. A buffer of B samples drops out when such a stall exceeds the
# time left in the buffer after the DSP work, so one run predicts all buffer sizes at once.

if (-not ('RTAudio.RealtimeProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace RTAudio {
    public class ProbeResult {
        public double PeriodMs, WorkMs, Seconds;
        public bool HighResTimer, Mmcss;
        public int Callbacks;
        public float[] DelaysMs;
        public string Error;
    }

    public static class RealtimeProbe {
        [DllImport("avrt.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr AvSetMmThreadCharacteristicsW(string task, ref uint index);
        [DllImport("avrt.dll")] static extern bool AvSetMmThreadPriority(IntPtr h, int priority);
        [DllImport("avrt.dll")] static extern bool AvRevertMmThreadCharacteristics(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr attributes, string name, uint flags, uint access);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetWaitableTimer(IntPtr h, ref long dueTime, int period, IntPtr cb, IntPtr arg, bool resume);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
        [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetSystemCpuSetInformation(byte[] info, int length, out int returned, IntPtr process, uint flags);

        // Number of distinct core efficiency classes: more than one = hybrid CPU (P- and E-cores).
        public static int EfficiencyClasses() {
            int len;
            GetSystemCpuSetInformation(null, 0, out len, IntPtr.Zero, 0);
            if (len <= 0) return 0;
            var buf = new byte[len];
            if (!GetSystemCpuSetInformation(buf, len, out len, IntPtr.Zero, 0)) return 0;
            var classes = new HashSet<byte>();
            // SYSTEM_CPU_SET_INFORMATION: Size(4) Type(4) Id(4) Group(2) LP(1) Core(1) LLC(1) Numa(1) EfficiencyClass(1)
            for (int off = 0; off + 19 <= len; ) {
                int size = BitConverter.ToInt32(buf, off);
                if (size <= 0) break;
                classes.Add(buf[off + 18]);
                off += size;
            }
            return classes.Count;
        }

        const uint HighResolution = 0x2, TimerAllAccess = 0x1F0003;
        const int AvrtPriorityHigh = 1;
        static volatile float sink;

        static void Work(int iterations) {
            float x = 1.0001f;
            for (int i = 0; i < iterations; i++) { x = x * 1.0000001f + 0.0000001f; if (x > 2f) x = 1.0001f; }
            sink = x;
        }

        public static ProbeResult Run(double seconds, double periodMs, double workMs) {
            var r = new ProbeResult { PeriodMs = periodMs, WorkMs = workMs, Seconds = seconds };
            var t = new Thread(() => { try { Body(r); } catch (Exception e) { r.Error = e.Message; } });
            t.IsBackground = true;
            t.Start();
            t.Join();
            return r;
        }

        static void Body(ProbeResult r) {
            uint task = 0;
            IntPtr av = AvSetMmThreadCharacteristicsW("Pro Audio", ref task);
            r.Mmcss = av != IntPtr.Zero;
            if (r.Mmcss) AvSetMmThreadPriority(av, AvrtPriorityHigh);
            else Thread.CurrentThread.Priority = ThreadPriority.Highest;

            IntPtr timer = CreateWaitableTimerExW(IntPtr.Zero, null, HighResolution, TimerAllAccess);
            r.HighResTimer = timer != IntPtr.Zero;
            if (!r.HighResTimer) { timeBeginPeriod(1); timer = CreateWaitableTimerExW(IntPtr.Zero, null, 0, TimerAllAccess); }
            try {
                double tick = 1000.0 / Stopwatch.Frequency;
                // Calibrate the work loop: fastest of several runs, so interruptions do not inflate it.
                int probeIter = 20000; double best = double.MaxValue;
                for (int i = 0; i < 40; i++) {
                    long a = Stopwatch.GetTimestamp(); Work(probeIter);
                    best = Math.Min(best, (Stopwatch.GetTimestamp() - a) * tick);
                }
                int iterations = Math.Max(1, (int)(probeIter * r.WorkMs / Math.Max(best, 1e-6)));

                long period = (long)(r.PeriodMs / tick);
                long spinMargin = (long)(0.5 / tick);
                int warmup = (int)(1000.0 / r.PeriodMs);           // first second is discarded
                int total = warmup + (int)(r.Seconds * 1000.0 / r.PeriodMs);
                var raw = new float[total];
                var work = new float[total];
                long start = Stopwatch.GetTimestamp() + period;
                for (int k = 0; k < total; k++) {
                    long due = start + k * period;
                    long now = Stopwatch.GetTimestamp();
                    // Sleep until shortly before the deadline, then spin to it: the timer's own wake-up
                    // inaccuracy (typically 0.1-0.5 ms) would otherwise be counted as a stall. Lateness
                    // beyond the margin (a timer DPC held up by other drivers) still counts.
                    long wakeAt = due - spinMargin;
                    if (wakeAt > now) {
                        long rel = -(long)((wakeAt - now) * tick * 10000.0);   // relative, 100 ns units
                        if (rel < 0 && SetWaitableTimer(timer, ref rel, 0, IntPtr.Zero, IntPtr.Zero, false)) WaitForSingleObject(timer, 1000);
                    }
                    while (Stopwatch.GetTimestamp() < due) { }
                    long w = Stopwatch.GetTimestamp();
                    Work(iterations);
                    long end = Stopwatch.GetTimestamp();
                    raw[k] = (float)((end - due) * tick);
                    work[k] = (float)((end - w) * tick);
                }
                // Undisturbed work time: a low percentile of the measured work durations.
                var sorted = new List<float>(work); sorted.Sort();
                float baseline = sorted[sorted.Count / 20];
                r.Callbacks = total - warmup;
                r.DelaysMs = new float[r.Callbacks];
                for (int k = 0; k < r.Callbacks; k++) r.DelaysMs[k] = Math.Max(0f, raw[k + warmup] - baseline);
                r.WorkMs = baseline;
            } finally {
                if (timer != IntPtr.Zero) CloseHandle(timer);
                if (!r.HighResTimer) timeEndPeriod(1);
                if (r.Mmcss) AvRevertMmThreadCharacteristics(av);
            }
        }
    }
}
'@
}

$script:ProbeBuffers = @(64, 128, 256, 512, 1024)
$script:ProbeSampleRate = 48000
$script:ProbeDspLoad = 0.5     # assume the DAW's DSP uses half of each buffer period

function Measure-RTBufferStalls {
    <#
      Pure analysis of a delay series (ms per callback). For each buffer size: the number of distinct
      stall events whose delay exceeds the headroom (1 - DspLoad) * buffer duration. Consecutive
      callbacks above the threshold belong to one stall (the thread is catching up), as in a real driver.
    #>
    param([float[]]$DelaysMs, [double]$Seconds, [int[]]$Buffers = $script:ProbeBuffers,
          [int]$SampleRate = $script:ProbeSampleRate, [double]$DspLoad = $script:ProbeDspLoad)
    foreach ($b in $Buffers) {
        $bufferMs = 1000.0 * $b / $SampleRate
        $threshold = (1 - $DspLoad) * $bufferMs
        $events = 0; $above = $false
        foreach ($d in $DelaysMs) {
            if ($d -gt $threshold) { if (-not $above) { $events++ }; $above = $true } else { $above = $false }
        }
        [pscustomobject]@{
            Buffer = $b; BufferMs = [math]::Round($bufferMs, 2); ThresholdMs = [math]::Round($threshold, 2)
            Stalls = $events; PerMinute = $(if ($Seconds -gt 0) { [math]::Round($events * 60 / $Seconds, 1) } else { 0 })
        }
    }
}

function Invoke-RTRealtimeProbe {
    <# Runs the probe for -Seconds and returns delay statistics plus the per-buffer verdict. #>
    param([int]$Seconds = 10)
    $r = [RTAudio.RealtimeProbe]::Run([double]$Seconds, 1000.0 * 64 / $script:ProbeSampleRate, 0.25)
    if ($r.Error -or -not $r.DelaysMs) { return [pscustomobject]@{ Ok = $false; Error = "$($r.Error)" } }
    $sorted = [float[]]$r.DelaysMs.Clone(); [Array]::Sort($sorted)
    $pct = { param($p) [math]::Round($sorted[[math]::Min($sorted.Length - 1, [int]($sorted.Length * $p))], 3) }
    $buffers = @(Measure-RTBufferStalls -DelaysMs $r.DelaysMs -Seconds $Seconds)
    $stable = $buffers | Where-Object { $_.Stalls -eq 0 } | Select-Object -First 1
    [pscustomobject]@{
        Ok           = $true
        Seconds      = $Seconds
        Callbacks    = $r.Callbacks
        HighResTimer = $r.HighResTimer
        Mmcss        = $r.Mmcss
        MedianMs     = & $pct 0.5
        P99Ms        = & $pct 0.99
        P999Ms       = & $pct 0.999
        MaxMs        = [math]::Round($sorted[-1], 3)
        Buffers      = $buffers
        StableBuffer = $(if ($stable) { $stable.Buffer } else { $null })
    }
}
