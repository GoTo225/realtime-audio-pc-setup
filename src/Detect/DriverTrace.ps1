# Driver trace: names the driver behind DPC/ISR latency spikes, like LatencyMon, without external tools.
#
# A real-time kernel ETW session with the DPC and INTERRUPT flags reports every deferred procedure call and interrupt service routine: the routine address, when it
# started (InitialTime) and, via the event timestamp, when it ended. Both are QPC ticks (ClientContext 1
# + raw timestamps), so the difference is the execution time. Routine addresses are mapped to driver
# files with EnumDeviceDrivers (kernel addresses are only visible to administrators).
# The session is a private SystemTraceProvider session ("RTAudio DPC Trace", Windows 8+) so it does not
# collide with tools or security software that hold "NT Kernel Logger"; that one is only the fallback.
#
# Usage (needs administrator rights; runs alongside Invoke-RTRealtimeProbe):
#     $t = Start-RTDriverTrace
#     try { $probe = Invoke-RTRealtimeProbe -Seconds 10 } finally { $drv = Stop-RTDriverTrace -Trace $t }
#     Get-RTDriverTraceFindings -Result $drv

if (-not ('RTAudio.DriverTrace' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace RTAudio {
    public class DriverTraceStat {
        public string Driver;
        public long Count, TotalTicks, MaxTicks;
        public bool Dpc, Isr;
    }

    public class DriverTraceResult {
        public bool Ok;
        public string Error;
        public double Seconds;
        public long Events, EventsLost, BuffersLost, Frequency;
        public int KnownDrivers;
        public DriverTraceStat[] Drivers = new DriverTraceStat[0];
    }

    public sealed class DriverTrace {
        public const string LoggerName = "NT Kernel Logger";
        public const int ErrorAlreadyRunningHere = -1;
        public const int ErrorBadLayout = -2;

        static readonly Guid SystemTraceControlGuid = new Guid("9e814aad-3204-11d2-9a82-006008a86939");
        static readonly Guid PerfInfoGuid = new Guid("ce1dbfb4-137e-4da6-87b0-3f59aa102cbc");

        const uint WNODE_FLAG_TRACED_GUID = 0x00020000;
        const uint EVENT_TRACE_REAL_TIME_MODE = 0x00000100;
        const uint EVENT_TRACE_FLAG_DPC = 0x00000020;
        const uint EVENT_TRACE_FLAG_INTERRUPT = 0x00000040;
        const uint EVENT_TRACE_CONTROL_STOP = 1;
        const uint PROCESS_TRACE_MODE_REAL_TIME = 0x00000100;
        const uint PROCESS_TRACE_MODE_RAW_TIMESTAMP = 0x00001000;
        const uint PROCESS_TRACE_MODE_EVENT_RECORD = 0x10000000;
        const ushort EVENT_HEADER_FLAG_32_BIT_HEADER = 0x0020;
        const ushort EVENT_HEADER_FLAG_64_BIT_HEADER = 0x0040;
        const int ERROR_WMI_INSTANCE_NOT_FOUND = 4201;

        // ---- native layouts (sequential; sizes/offsets are checked in CheckLayout) ----
        [StructLayout(LayoutKind.Sequential)]
        struct WNODE_HEADER {
            public uint BufferSize, ProviderId;
            public ulong HistoricalContext;
            public long TimeStamp;
            public Guid Guid;
            public uint ClientContext, Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_TRACE_PROPERTIES {
            public WNODE_HEADER Wnode;
            public uint BufferSize, MinimumBuffers, MaximumBuffers, MaximumFileSize, LogFileMode, FlushTimer, EnableFlags;
            public int AgeLimit;
            public uint NumberOfBuffers, FreeBuffers, EventsLost, BuffersWritten, LogBuffersLost, RealTimeBuffersLost;
            public IntPtr LoggerThreadId;
            public uint LogFileNameOffset, LoggerNameOffset;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_TRACE_HEADER {
            public ushort Size, FieldTypeFlags;
            public uint Version, ThreadId, ProcessId;
            public long TimeStamp;
            public Guid Guid;
            public ulong ProcessorTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_TRACE {
            public EVENT_TRACE_HEADER Header;
            public uint InstanceId, ParentInstanceId;
            public Guid ParentGuid;
            public IntPtr MofData;
            public uint MofLength, ClientContext;
        }

        [StructLayout(LayoutKind.Sequential, Size = 172)]
        struct TIME_ZONE_INFORMATION { public int Bias; }

        [StructLayout(LayoutKind.Sequential)]
        struct TRACE_LOGFILE_HEADER {
            public uint BufferSize, Version, ProviderVersion, NumberOfProcessors;
            public long EndTime;
            public uint TimerResolution, MaximumFileSize, LogFileMode, BuffersWritten;
            public Guid LogInstanceGuid;   // union with StartBuffers/PointerSize/EventsLost/CpuSpeedInMHz
            public IntPtr LoggerName, LogFileName;
            public TIME_ZONE_INFORMATION TimeZone;
            public long BootTime, PerfFreq, StartTime;
            public uint ReservedFlags, BuffersLost;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_TRACE_LOGFILEW {
            public IntPtr LogFileName, LoggerName;
            public long CurrentTime;
            public uint BuffersRead, ProcessTraceMode;
            public EVENT_TRACE CurrentEvent;
            public TRACE_LOGFILE_HEADER LogfileHeader;
            public IntPtr BufferCallback;
            public uint BufferSize, Filled, EventsLost;
            public IntPtr EventRecordCallback;
            public uint IsKernelTrace;
            public IntPtr Context;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_DESCRIPTOR {
            public ushort Id;
            public byte Version, Channel, Level, Opcode;
            public ushort Task;
            public ulong Keyword;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_HEADER {
            public ushort Size, HeaderType, Flags, EventProperty;
            public uint ThreadId, ProcessId;
            public long TimeStamp;
            public Guid ProviderId;
            public EVENT_DESCRIPTOR EventDescriptor;
            public ulong ProcessorTime;
            public Guid ActivityId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_RECORD {
            public EVENT_HEADER EventHeader;
            public uint BufferContext;
            public ushort ExtendedDataCount, UserDataLength;
            public IntPtr ExtendedData, UserData, UserContext;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate void EventRecordCallback(IntPtr record);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern int StartTraceW(out ulong handle, string name, IntPtr properties);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern int ControlTraceW(ulong handle, string name, IntPtr properties, uint code);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern ulong OpenTraceW(ref EVENT_TRACE_LOGFILEW logfile);
        [DllImport("advapi32.dll")]
        static extern int ProcessTrace([In] ulong[] handles, uint count, IntPtr start, IntPtr end);
        [DllImport("advapi32.dll")]
        static extern int CloseTrace(ulong handle);
        [DllImport("psapi.dll", SetLastError = true)]
        static extern bool EnumDeviceDrivers([Out] IntPtr[] bases, uint cb, out uint needed);
        [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetDeviceDriverBaseNameW(IntPtr imageBase, StringBuilder name, uint size);

        static readonly int OffFlags = (int)Marshal.OffsetOf(typeof(EVENT_HEADER), "Flags");
        static readonly int OffTimeStamp = (int)Marshal.OffsetOf(typeof(EVENT_HEADER), "TimeStamp");
        static readonly int OffProvider = (int)Marshal.OffsetOf(typeof(EVENT_HEADER), "ProviderId");
        static readonly int OffOpcode = (int)Marshal.OffsetOf(typeof(EVENT_HEADER), "EventDescriptor") + (int)Marshal.OffsetOf(typeof(EVENT_DESCRIPTOR), "Opcode");
        static readonly int OffUserDataLength = (int)Marshal.OffsetOf(typeof(EVENT_RECORD), "UserDataLength");
        static readonly int OffUserData = (int)Marshal.OffsetOf(typeof(EVENT_RECORD), "UserData");
        static readonly long PerfInfoA, PerfInfoB;
        static readonly ulong InvalidTraceHandle = IntPtr.Size == 8 ? 0xFFFFFFFFFFFFFFFFUL : 0x00000000FFFFFFFFUL;

        static volatile DriverTrace active;
        static readonly object gate = new object();
        static readonly EventRecordCallback callback = OnEvent;   // must stay referenced while ProcessTrace runs

        static DriverTrace() {
            byte[] g = PerfInfoGuid.ToByteArray();
            PerfInfoA = BitConverter.ToInt64(g, 0);
            PerfInfoB = BitConverter.ToInt64(g, 8);
            // Never leave the kernel logger running when the host process exits.
            AppDomain.CurrentDomain.ProcessExit += delegate { StopActive(); };
            AppDomain.CurrentDomain.DomainUnload += delegate { StopActive(); };
        }

        static void StopActive() {
            DriverTrace a = active;
            if (a != null) { try { a.Stop(); } catch { } }
        }

        // Expected layouts (Windows SDK): x64 / x86. Returns "" when the managed definitions match.
        public static string CheckLayout() {
            bool x64 = IntPtr.Size == 8;
            var errors = new List<string>();
            Action<string, int, int> check = delegate(string what, int actual, int expected) {
                if (actual != expected) errors.Add(what + "=" + actual + " (expected " + expected + ")");
            };
            check("WNODE_HEADER", Marshal.SizeOf(typeof(WNODE_HEADER)), 48);
            check("EVENT_TRACE_PROPERTIES", Marshal.SizeOf(typeof(EVENT_TRACE_PROPERTIES)), 120);
            check("EVENT_TRACE_PROPERTIES.EnableFlags", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_PROPERTIES), "EnableFlags"), 72);
            check("EVENT_TRACE_PROPERTIES.EventsLost", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_PROPERTIES), "EventsLost"), 88);
            check("EVENT_TRACE_PROPERTIES.LoggerNameOffset", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_PROPERTIES), "LoggerNameOffset"), x64 ? 116 : 112);
            check("EVENT_TRACE_HEADER", Marshal.SizeOf(typeof(EVENT_TRACE_HEADER)), 48);
            check("EVENT_TRACE", Marshal.SizeOf(typeof(EVENT_TRACE)), x64 ? 88 : 88);
            check("TRACE_LOGFILE_HEADER", Marshal.SizeOf(typeof(TRACE_LOGFILE_HEADER)), x64 ? 280 : 272);
            check("EVENT_TRACE_LOGFILEW", Marshal.SizeOf(typeof(EVENT_TRACE_LOGFILEW)), x64 ? 448 : 416);
            check("EVENT_TRACE_LOGFILEW.ProcessTraceMode", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_LOGFILEW), "ProcessTraceMode"), x64 ? 28 : 20);
            check("EVENT_TRACE_LOGFILEW.LogfileHeader", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_LOGFILEW), "LogfileHeader"), x64 ? 120 : 112);
            check("EVENT_TRACE_LOGFILEW.EventRecordCallback", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_LOGFILEW), "EventRecordCallback"), x64 ? 424 : 400);
            check("EVENT_TRACE_LOGFILEW.Context", (int)Marshal.OffsetOf(typeof(EVENT_TRACE_LOGFILEW), "Context"), x64 ? 440 : 408);
            check("EVENT_HEADER", Marshal.SizeOf(typeof(EVENT_HEADER)), 80);
            check("EVENT_HEADER.Opcode", OffOpcode, 45);
            check("EVENT_RECORD", Marshal.SizeOf(typeof(EVENT_RECORD)), x64 ? 112 : 104);
            check("EVENT_RECORD.UserDataLength", OffUserDataLength, 86);
            check("EVENT_RECORD.UserData", OffUserData, x64 ? 96 : 92);
            return string.Join("; ", errors.ToArray());
        }

        // ---- per-routine aggregation (written only by the ProcessTrace thread) ----
        sealed class RoutineStat { public long Count, Total, Max; public bool Dpc, Isr; }
        readonly Dictionary<ulong, RoutineStat> stats = new Dictionary<ulong, RoutineStat>();
        long events, callbackErrors;
        readonly long maxTicks = Stopwatch.Frequency;   // > 1 s is not a real DPC/ISR: bad timestamp

        ulong session;
        ulong traceHandle;
        bool sessionRunning, stopped;
        IntPtr loggerNamePtr = IntPtr.Zero;
        Thread consumer;
        int processResult = -1;
        string consumerError;
        string loggerName = LoggerName;
        readonly Stopwatch clock = new Stopwatch();
        DriverTraceResult result;

        public DriverTrace() { traceHandle = InvalidTraceHandle; }

        public bool IsRunning { get { return sessionRunning && !stopped; } }

        static void OnEvent(IntPtr record) {
            DriverTrace t = active;
            if (t == null || record == IntPtr.Zero) return;
            try { t.Handle(record); } catch { t.callbackErrors++; }
        }

        void Handle(IntPtr rec) {
            if (Marshal.ReadInt64(rec, OffProvider) != PerfInfoA || Marshal.ReadInt64(rec, OffProvider + 8) != PerfInfoB) return;
            byte op = Marshal.ReadByte(rec, OffOpcode);
            bool isr;
            if (op == 67) isr = true;                                   // ISR
            else if (op == 66 || op == 68 || op == 69) isr = false;     // ThreadedDPC, DPC, TimerDPC
            else return;
            int flags = (ushort)Marshal.ReadInt16(rec, OffFlags);
            int ptr = (flags & EVENT_HEADER_FLAG_32_BIT_HEADER) != 0 ? 4 : (flags & EVENT_HEADER_FLAG_64_BIT_HEADER) != 0 ? 8 : IntPtr.Size;
            int len = (ushort)Marshal.ReadInt16(rec, OffUserDataLength);
            IntPtr data = Marshal.ReadIntPtr(rec, OffUserData);
            if (data == IntPtr.Zero || len < 8 + ptr) return;
            long end = Marshal.ReadInt64(rec, OffTimeStamp);
            long initial = Marshal.ReadInt64(data, 0);
            ulong routine = ptr == 8 ? (ulong)Marshal.ReadInt64(data, 8) : (ulong)(uint)Marshal.ReadInt32(data, 8);
            Record(routine, end - initial, isr);
        }

        public void Record(ulong routine, long ticks, bool isr) {
            if (ticks < 0 || ticks > maxTicks) return;
            events++;
            RoutineStat s;
            if (!stats.TryGetValue(routine, out s)) { s = new RoutineStat(); stats[routine] = s; }
            s.Count++;
            s.Total += ticks;
            if (ticks > s.Max) s.Max = ticks;
            if (isr) s.Isr = true; else s.Dpc = true;
        }

        // ---- driver address map ----
        public static int GetDrivers(out ulong[] bases, out string[] names) {
            bases = new ulong[0]; names = new string[0];
            uint needed;
            if (!EnumDeviceDrivers(new IntPtr[1], (uint)IntPtr.Size, out needed) || needed == 0) return 0;
            var arr = new IntPtr[needed / IntPtr.Size + 64];
            if (!EnumDeviceDrivers(arr, (uint)(arr.Length * IntPtr.Size), out needed)) return 0;
            int n = Math.Min(arr.Length, (int)(needed / IntPtr.Size));
            var b = new List<ulong>(); var nm = new List<string>();
            var sb = new StringBuilder(260);
            for (int i = 0; i < n; i++) {
                ulong a = unchecked((ulong)arr[i].ToInt64());
                if (IntPtr.Size == 4) a &= 0xFFFFFFFFUL;
                if (a == 0) continue;                       // not elevated: addresses are hidden
                sb.Length = 0;
                if (GetDeviceDriverBaseNameW(arr[i], sb, (uint)sb.Capacity) == 0) continue;
                b.Add(a); nm.Add(sb.ToString());
            }
            bases = b.ToArray(); names = nm.ToArray();
            Array.Sort(bases, names);
            return bases.Length;
        }

        // Greatest base <= address. bases must be sorted ascending. null when below every base.
        public static string Resolve(ulong address, ulong[] bases, string[] names) {
            if (bases == null || bases.Length == 0 || address == 0) return null;
            int lo = 0, hi = bases.Length - 1, found = -1;
            while (lo <= hi) {
                int mid = (lo + hi) >> 1;
                if (bases[mid] <= address) { found = mid; lo = mid + 1; } else hi = mid - 1;
            }
            return found < 0 ? null : names[found];
        }

        public DriverTraceStat[] Summarize(ulong[] bases, string[] names) {
            var byName = new Dictionary<string, DriverTraceStat>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<ulong, RoutineStat> kv in stats) {
                string n = Resolve(kv.Key, bases, names) ?? "unknown";
                DriverTraceStat d;
                if (!byName.TryGetValue(n, out d)) { d = new DriverTraceStat(); d.Driver = n; byName[n] = d; }
                d.Count += kv.Value.Count;
                d.TotalTicks += kv.Value.Total;
                if (kv.Value.Max > d.MaxTicks) d.MaxTicks = kv.Value.Max;
                d.Dpc |= kv.Value.Dpc; d.Isr |= kv.Value.Isr;
            }
            var list = new List<DriverTraceStat>(byName.Values);
            list.Sort(delegate(DriverTraceStat x, DriverTraceStat y) { return y.MaxTicks.CompareTo(x.MaxTicks); });
            return list.ToArray();
        }

        // ---- session control ----
        // Preferred: a private SystemTraceProvider session (Windows 8+), which coexists with whatever
        // already holds "NT Kernel Logger" (security agents, LatencyMon, Process Monitor, xperf).
        // Fallback: the classic NT Kernel Logger.
        public const string PrivateLoggerName = "RTAudio DPC Trace";
        static readonly Guid PrivateSessionGuid = new Guid("5b0c3b7e-6f2a-4d6e-9a51-7d2f0e1c8a43");
        const uint EVENT_TRACE_SYSTEM_LOGGER_MODE = 0x02000000;
        const int ERROR_ACCESS_DENIED = 5;
        const int ERROR_ALREADY_EXISTS = 183;

        static IntPtr NewProperties(bool forStart, bool systemLogger) {
            int baseSize = Marshal.SizeOf(typeof(EVENT_TRACE_PROPERTIES));
            int size = baseSize + 2048;   // room for logger and log file name written back by ETW
            IntPtr p = Marshal.AllocHGlobal(size);
            Marshal.Copy(new byte[size], 0, p, size);
            var pr = new EVENT_TRACE_PROPERTIES();
            pr.Wnode.BufferSize = (uint)size;
            pr.LoggerNameOffset = (uint)baseSize;
            if (forStart) {
                int cpus = Environment.ProcessorCount;
                pr.Wnode.Guid = systemLogger ? PrivateSessionGuid : SystemTraceControlGuid;
                pr.Wnode.ClientContext = 1;                  // QPC timestamps, same clock as InitialTime
                pr.Wnode.Flags = WNODE_FLAG_TRACED_GUID;
                pr.BufferSize = 64;                          // KB
                pr.MinimumBuffers = (uint)Math.Max(16, 2 * cpus);
                pr.MaximumBuffers = pr.MinimumBuffers + 64;
                pr.LogFileMode = EVENT_TRACE_REAL_TIME_MODE | (systemLogger ? EVENT_TRACE_SYSTEM_LOGGER_MODE : 0);
                pr.FlushTimer = 1;
                pr.EnableFlags = EVENT_TRACE_FLAG_DPC | EVENT_TRACE_FLAG_INTERRUPT;
            } else {
                pr.LogFileNameOffset = (uint)(baseSize + 1024);
            }
            Marshal.StructureToPtr(pr, p, false);
            return p;
        }

        static int StartSession(string name, bool systemLogger, out ulong handle) {
            IntPtr props = NewProperties(true, systemLogger);
            try { return StartTraceW(out handle, name, props); }
            finally { Marshal.FreeHGlobal(props); }
        }

        static int StopByName(string name) {
            IntPtr props = NewProperties(false, false);
            try { return ControlTraceW(0, name, props, EVENT_TRACE_CONTROL_STOP); }
            finally { Marshal.FreeHGlobal(props); }
        }

        // Name of the ETW session in use (private session or NT Kernel Logger).
        public string SessionName { get { return loggerName; } }

        // Starts the kernel session and its consumer thread. Returns null and a Win32 error on failure
        // (183 = the kernel logger is already used by another tool; that session is never stopped here).
        public static DriverTrace Start(out int error) {
            error = 0;
            if (CheckLayout().Length > 0) { error = ErrorBadLayout; return null; }
            lock (gate) {
                if (active != null) { error = ErrorAlreadyRunningHere; return null; }
                var t = new DriverTrace();
                int rc = -3;
                if (Environment.OSVersion.Version >= new Version(6, 2)) {
                    t.loggerName = PrivateLoggerName;
                    rc = StartSession(PrivateLoggerName, true, out t.session);
                    if (rc == ERROR_ALREADY_EXISTS) {
                        // Our own session left over from a crashed run (the name is ours): replace it.
                        StopByName(PrivateLoggerName);
                        rc = StartSession(PrivateLoggerName, true, out t.session);
                    }
                    if (rc == ERROR_ACCESS_DENIED) { error = rc; return null; }
                }
                if (rc != 0) {
                    t.loggerName = LoggerName;
                    int rc2 = StartSession(LoggerName, false, out t.session);
                    if (rc2 != 0) { error = (rc2 == ERROR_ALREADY_EXISTS || rc == -3) ? rc2 : rc; return null; }
                }
                t.sessionRunning = true;
                try {
                    t.loggerNamePtr = Marshal.StringToHGlobalUni(t.loggerName);
                    var lf = new EVENT_TRACE_LOGFILEW();
                    lf.LoggerName = t.loggerNamePtr;
                    lf.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD | PROCESS_TRACE_MODE_RAW_TIMESTAMP;
                    lf.EventRecordCallback = Marshal.GetFunctionPointerForDelegate(callback);
                    t.traceHandle = OpenTraceW(ref lf);
                    if (t.traceHandle == InvalidTraceHandle) {
                        error = Marshal.GetLastWin32Error();
                        if (error == 0) error = 1;
                        t.Cleanup();
                        return null;
                    }
                    active = t;
                    t.consumer = new Thread(t.Consume);
                    t.consumer.IsBackground = true;
                    t.consumer.Priority = ThreadPriority.AboveNormal;
                    t.consumer.Name = "RTAudio driver trace";
                    t.clock.Start();
                    t.consumer.Start();
                    return t;
                } catch {
                    t.Cleanup();
                    throw;
                }
            }
        }

        void Consume() {
            try { processResult = ProcessTrace(new ulong[] { traceHandle }, 1, IntPtr.Zero, IntPtr.Zero); }
            catch (Exception e) { consumerError = e.Message; }
        }

        // Stops the session (always), waits for the consumer and returns the per-driver statistics.
        public DriverTraceResult Stop() {
            lock (gate) {
                if (stopped) return result;
                stopped = true;
                clock.Stop();
                var r = new DriverTraceResult();
                r.Frequency = Stopwatch.Frequency;
                r.Seconds = clock.Elapsed.TotalSeconds;
                bool drained = false;
                try {
                    int rc = StopSession(r);
                    if (rc != 0 && rc != ERROR_WMI_INSTANCE_NOT_FOUND) r.Error = "Stopping the kernel trace failed (error " + rc + ").";
                    // ProcessTrace returns once the stopped session's last buffers are delivered.
                    drained = consumer == null || consumer.Join(5000);
                } finally {
                    Cleanup();
                }
                if (!drained) {
                    if (consumer != null) consumer.Join(2000);
                    if (r.Error == null) r.Error = "The trace consumer did not finish in time.";
                }
                if (consumerError != null && r.Error == null) r.Error = "Trace consumer failed: " + consumerError;
                ulong[] bases; string[] names;
                r.KnownDrivers = GetDrivers(out bases, out names);
                r.Events = events;
                r.Drivers = Summarize(bases, names);
                r.Ok = r.Error == null;
                result = r;
                return r;
            }
        }

        int StopSession(DriverTraceResult r) {
            if (!sessionRunning) return 0;
            IntPtr props = NewProperties(false, false);
            try {
                int rc = ControlTraceW(session, null, props, EVENT_TRACE_CONTROL_STOP);
                if (rc == 0 && r != null) {
                    var pr = (EVENT_TRACE_PROPERTIES)Marshal.PtrToStructure(props, typeof(EVENT_TRACE_PROPERTIES));
                    r.EventsLost = pr.EventsLost;
                    r.BuffersLost = (long)pr.RealTimeBuffersLost + pr.LogBuffersLost;
                }
                if (rc == 0 || rc == ERROR_WMI_INSTANCE_NOT_FOUND) sessionRunning = false;
                return rc;
            } finally { Marshal.FreeHGlobal(props); }
        }

        void Cleanup() {
            try { if (sessionRunning) StopSession(null); } catch { }
            if (traceHandle != InvalidTraceHandle) {
                try { CloseTrace(traceHandle); } catch { }
                traceHandle = InvalidTraceHandle;
            }
            if (consumer != null && consumer.IsAlive) consumer.Join(2000);
            if (loggerNamePtr != IntPtr.Zero) { Marshal.FreeHGlobal(loggerNamePtr); loggerNamePtr = IntPtr.Zero; }
            if (active == this) active = null;
        }
    }
}
'@
}

function Get-RTDriverTraceStartError {
    # Plain-English message for a Win32 error returned by [RTAudio.DriverTrace]::Start.
    param([int]$Code)
    switch ($Code) {
        5      { 'Run as administrator to name the driver behind DPC/ISR latency (the kernel trace needs administrator rights).' }
        183    { 'The Windows kernel trace is already in use by another tool (LatencyMon, Process Monitor, xperf/WPR or a similar tool may be running). Close it and try again.' }
        -1     { 'A driver trace is already running in this tool.' }
        -2     { 'The driver trace is not supported on this system (unexpected ETW structure layout).' }
        default { "Could not start the kernel trace (Windows error $Code)." }
    }
}

function Start-RTDriverTrace {
    <#
      Starts a real-time kernel trace of DPC and ISR execution. Returns a handle for Stop-RTDriverTrace.
      Throws when not elevated, when the kernel logger is used by another tool, or on other errors.
      Always pair with Stop-RTDriverTrace in a finally block.
    #>
    if (-not (Test-RTAdmin)) { throw (Get-RTDriverTraceStartError -Code 5) }
    $err = 0
    $trace = [RTAudio.DriverTrace]::Start([ref]$err)
    if ($null -eq $trace) { throw (Get-RTDriverTraceStartError -Code $err) }
    $trace
}

function ConvertTo-RTDriverTraceResult {
    # Pure: turns the raw C# result (ticks) into the public shape (microseconds, kinds, explanations).
    param([Parameter(Mandatory)]$Raw)
    $freq = [double]$Raw.Frequency
    if ($freq -le 0) { $freq = [double][Diagnostics.Stopwatch]::Frequency }
    $stats = @($Raw.Drivers | Where-Object { $null -ne $_ })
    $allTicks = [double]0
    foreach ($d in $stats) { $allTicks += [double]$d.TotalTicks }
    $drivers = @(foreach ($d in $stats) {
        $kind = if ($d.Dpc -and $d.Isr) { 'DPC+ISR' } elseif ($d.Isr) { 'ISR' } else { 'DPC' }
        [pscustomobject]@{
            Driver      = [string]$d.Driver
            Kind        = $kind
            Count       = [long]$d.Count
            MaxUs       = [math]::Round([double]$d.MaxTicks * 1e6 / $freq, 1)
            TotalMs     = [math]::Round([double]$d.TotalTicks * 1e3 / $freq, 3)
            PercentTime = $(if ($allTicks -gt 0) { [math]::Round(100.0 * [double]$d.TotalTicks / $allTicks, 1) } else { 0 })
            Explanation = (Get-RTDriverExplanation -Driver ([string]$d.Driver))
        }
    })
    $ok = [bool]$Raw.Ok
    $errorText = [string]$Raw.Error
    if ($ok -and [long]$Raw.Events -eq 0) { $ok = $false; $errorText = 'The kernel trace delivered no DPC/ISR events.' }
    [pscustomobject]@{
        Ok          = $ok
        Error       = $errorText
        Seconds     = [math]::Round([double]$Raw.Seconds, 1)
        Events      = [long]$Raw.Events
        EventsLost  = [long]$Raw.EventsLost
        BuffersLost = [long]$Raw.BuffersLost
        Drivers     = @($drivers | Sort-Object -Property MaxUs -Descending)
    }
}

function Stop-RTDriverTrace {
    <#
      Stops the trace started by Start-RTDriverTrace (the kernel session is always stopped) and returns
      @{ Ok; Error; Seconds; Events; EventsLost; BuffersLost; Drivers }, Drivers sorted by MaxUs descending,
      each @{ Driver; Kind ('DPC'|'ISR'|'DPC+ISR'); Count; MaxUs; TotalMs; PercentTime (share of all
      DPC/ISR time); Explanation }. Never throws.
    #>
    param([AllowNull()]$Trace)
    $fail = { param($msg) [pscustomobject]@{ Ok = $false; Error = $msg; Seconds = 0; Events = 0; EventsLost = 0; BuffersLost = 0; Drivers = @() } }
    if ($Trace -isnot [RTAudio.DriverTrace]) { return (& $fail 'The driver trace was not started.') }
    try { $raw = $Trace.Stop() }
    catch { return (& $fail "Stopping the driver trace failed: $($_.Exception.Message)") }
    if ($null -eq $raw) { return (& $fail 'The driver trace returned no result.') }
    ConvertTo-RTDriverTraceResult -Raw $raw
}

# Ordered: first matching pattern wins. Matched against the file name without extension.
$script:DriverExplanations = @(
    @('ndis', 'Network stack (NDIS): the network adapter driver is busy. Turn off Wi-Fi/airplane mode while recording, update or disable the network adapter, and turn off its power saving and interrupt moderation.'),
    @('tcpip', 'TCP/IP network stack: heavy network traffic (downloads, cloud sync, updates). Pause sync/downloads while recording or disconnect the network.'),
    @('netwtw*', 'Intel Wi-Fi driver: a frequent cause of latency spikes. Turn off Wi-Fi (airplane mode) while recording, use Ethernet, and install the latest driver from Intel.'),
    @('wdiwifi', 'Windows Wi-Fi framework: Wi-Fi scanning and power saving cause spikes. Turn off Wi-Fi (airplane mode) while recording or use Ethernet.'),
    @('athw*', 'Qualcomm Atheros Wi-Fi driver: turn off Wi-Fi (airplane mode) while recording and update the driver from the PC maker.'),
    @('rt640x64', 'Realtek Ethernet driver: install the latest driver from Realtek, turn off Energy-Efficient Ethernet and interrupt moderation, or disable the adapter while recording.'),
    @('e1d*', 'Intel Ethernet driver: install the latest driver from Intel, turn off Energy-Efficient Ethernet and interrupt moderation, or disable the adapter while recording.'),
    @('nvlddmkm', 'NVIDIA graphics driver: do a clean install of the latest Studio driver (DDU), set the power management mode to "Prefer maximum performance" and remove GeForce Experience overlays.'),
    @('amdkmdag', 'AMD graphics driver: do a clean install of the latest driver (DDU) and turn off ULPS and overlays in Adrenalin.'),
    @('igdkmd*', 'Intel graphics driver: install the latest driver from Intel or the PC maker and turn off panel self refresh / display power saving.'),
    @('dxgkrnl', 'Windows graphics kernel: usually the GPU driver underneath. Update the graphics driver (clean install) and avoid animated wallpapers/overlays while recording.'),
    @('acpi', 'ACPI (power and firmware): usually caused by BIOS power management or battery polling. Update the BIOS, use the High Performance plan, on laptops run on mains power; disable C-states in the BIOS if it persists.'),
    @('intelppm', 'Intel CPU power management: CPU sleep states (C-states) waking up slowly. Use the High/Ultimate Performance plan and disable deep C-states in the BIOS.'),
    @('amdppm', 'AMD CPU power management: CPU sleep states (C-states) waking up slowly. Use the High/Ultimate Performance plan and disable Global C-states in the BIOS.'),
    @('storport', 'Storage port driver: disk activity. Update the storage/chipset driver, keep samples on a fast SSD and turn off disk sleep (AHCI link power management).'),
    @('stornvme', 'NVMe SSD driver: update the SSD firmware and the chipset/storage driver; turn off NVMe power saving (APST) via the power plan.'),
    @('storahci', 'SATA (AHCI) driver: update the chipset/SATA driver, turn off link power management and disk sleep.'),
    @('usbport', 'USB host controller (legacy): a USB device is busy. Unplug other USB devices, move the audio interface to another port/controller, and turn off USB selective suspend.'),
    @('usbxhci', 'USB 3 host controller: a USB device on the same controller is busy. Unplug webcams/hubs/storage, move the audio interface to another port (ideally its own controller), and turn off USB selective suspend.'),
    @('ucx01000', 'USB host controller framework: a USB device is busy. Unplug other USB devices and move the audio interface to another port or controller.'),
    @('usbhub3', 'USB 3 hub driver: a hub or device behind it. Connect the audio interface directly to the PC, not through a hub or dock.'),
    @('bthport', 'Bluetooth stack: turn off Bluetooth while recording; never monitor through Bluetooth headphones.'),
    @('bthusb', 'Bluetooth USB radio: turn off Bluetooth while recording, or disable the Bluetooth adapter in Device Manager.'),
    @('hdaudbus', 'Onboard/HDMI audio bus: disable unused onboard and HDMI/DisplayPort audio devices when you use an external audio interface.'),
    @('portcls', 'Windows audio port driver: an onboard or HDMI audio device. Disable unused audio devices and update the onboard audio driver.'),
    @('ntoskrnl', 'Windows kernel: timers and scheduling, usually triggered by other drivers or power management. Look at the other drivers in the list, use the High Performance plan and check BIOS power settings.'),
    @('ntkrnl*', 'Windows kernel: timers and scheduling, usually triggered by other drivers or power management. Look at the other drivers in the list, use the High Performance plan and check BIOS power settings.'),
    @('hal', 'Hardware abstraction layer: timers and interrupts, usually triggered by other drivers or power management. Look at the other drivers in the list and check BIOS power settings.'),
    @('wdf01000', 'Windows driver framework: the real driver is hidden behind it (often USB, touchpad, sensors or vendor utilities). Disable devices one at a time in Device Manager to find it.'),
    @('wdfilter', 'Microsoft Defender file scanning: real-time scanning of files being read. Add exclusions for your DAW, plugin and sample folders.')
)

function Get-RTDriverExplanation {
    # Pure: short explanation and fix for a known culprit driver ('ndis.sys'); '' when unknown.
    param([AllowNull()][AllowEmptyString()][string]$Driver)
    if ([string]::IsNullOrWhiteSpace($Driver)) { return '' }
    $leaf = ($Driver -split '[\\/]')[-1].Trim()
    $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
    foreach ($e in $script:DriverExplanations) {
        if ($base -like $e[0]) { return $e[1] }
    }
    ''
}

function Get-RTDriverTraceFindings {
    # Pure: findings from a Stop-RTDriverTrace result. MaxUs >= 1000 Problem, >= 500 Warning, else one summary.
    param([AllowNull()]$Result)
    if ($null -eq $Result -or -not $Result.Ok) {
        $why = if ($null -ne $Result -and $Result.Error) { [string]$Result.Error } else { 'The driver trace did not run.' }
        New-RTFinding -Id 'drv.trace' -Severity Info -Category 'Latency' -Title 'Could not name the drivers behind DPC/ISR latency' -Detail $why -Advice 'Run the tool as administrator with LatencyMon and similar tools closed, or use LatencyMon.' -GuideId 'latencymon'
        return
    }
    $drivers = @($Result.Drivers)
    $lost = if ([long]$Result.EventsLost -gt 0) { " ($($Result.EventsLost) trace events were lost, so the numbers may be incomplete.)" } else { '' }
    $flagged = @($drivers | Where-Object { [double]$_.MaxUs -ge 500 })
    foreach ($d in $flagged) {
        $sev = if ([double]$d.MaxUs -ge 1000) { 'Problem' } else { 'Warning' }
        $title = if ($sev -eq 'Problem') { "$($d.Driver) causes long $($d.Kind) delays (up to $([math]::Round([double]$d.MaxUs / 1000, 2)) ms)" }
                 else { "$($d.Driver) causes elevated $($d.Kind) delays (up to $($d.MaxUs) us)" }
        $detail = "$($d.Count) $($d.Kind) calls in $($Result.Seconds) s, longest $($d.MaxUs) us, $($d.TotalMs) ms in total = $($d.PercentTime)% of all DPC/ISR time.$lost"
        $advice = if ($d.Explanation) { [string]$d.Explanation } else { 'Find the device that uses this driver (Device Manager, view by driver), update its driver or disable it while recording, then measure again.' }
        New-RTFinding -Id "drv.$($d.Driver)" -Severity $sev -Category 'Latency' -Title $title -Detail $detail -Advice $advice -GuideId 'latencymon'
    }
    if ($flagged.Count -eq 0) {
        $top = @($drivers | Select-Object -First 3 | ForEach-Object { "$($_.Driver) $($_.MaxUs) us" })
        $detail = if ($top.Count -gt 0) { "Longest DPC/ISR per driver in $($Result.Seconds) s: $($top -join ', ').$lost" } else { "No DPC/ISR activity recorded in $($Result.Seconds) s.$lost" }
        $sev = if ($drivers.Count -gt 0) { 'Ok' } else { 'Info' }
        New-RTFinding -Id 'drv.trace' -Severity $sev -Category 'Latency' -Title 'No driver caused long DPC/ISR delays' -Detail $detail -Advice 'For a longer test, run LatencyMon while playing a project.' -GuideId 'latencymon'
    }
}
