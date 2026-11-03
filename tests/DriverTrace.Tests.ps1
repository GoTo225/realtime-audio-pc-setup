# Pester 3.4 compatible. Run: Invoke-Pester .\tests\DriverTrace.Tests.ps1
# Needs no administrator rights: the live kernel trace is not started here (only the non-elevated refusal is tested).

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Engine.psm1') -Force -DisableNameChecking

InModuleScope Engine {
    Describe 'Get-RTDriverExplanation' {
        $known = @('ndis.sys', 'tcpip.sys', 'Netwtw10.sys', 'Netwtw14.sys', 'wdiwifi.sys', 'rt640x64.sys', 'e1d68x64.sys',
            'nvlddmkm.sys', 'amdkmdag.sys', 'igdkmdn64.sys', 'dxgkrnl.sys', 'ACPI.sys', 'intelppm.sys', 'amdppm.sys',
            'storport.sys', 'stornvme.sys', 'storahci.sys', 'USBPORT.SYS', 'USBXHCI.SYS', 'ucx01000.sys', 'usbhub3.sys',
            'bthport.sys', 'BTHUSB.sys', 'HDAudBus.sys', 'portcls.sys', 'ntoskrnl.exe', 'hal.dll', 'Wdf01000.sys', 'WdFilter.sys')
        foreach ($d in $known) {
            It "explains $d" {
                (Get-RTDriverExplanation -Driver $d).Length -gt 20 | Should Be $true
            }
        }
        It 'is case-insensitive and accepts names without extension or with a path' {
            Get-RTDriverExplanation -Driver 'NDIS.SYS' | Should Be (Get-RTDriverExplanation -Driver 'ndis.sys')
            Get-RTDriverExplanation -Driver 'nvlddmkm' | Should Be (Get-RTDriverExplanation -Driver 'nvlddmkm.sys')
            Get-RTDriverExplanation -Driver 'C:\Windows\System32\drivers\stornvme.sys' | Should Be (Get-RTDriverExplanation -Driver 'stornvme.sys')
        }
        It 'mentions the hidden driver for Wdf01000' {
            Get-RTDriverExplanation -Driver 'Wdf01000.sys' | Should Match 'hidden'
        }
        It 'returns empty for unknown, empty or null' {
            Get-RTDriverExplanation -Driver 'foobar.sys' | Should Be ''
            Get-RTDriverExplanation -Driver 'acpiex.sys' | Should Be ''
            Get-RTDriverExplanation -Driver '' | Should Be ''
            Get-RTDriverExplanation -Driver $null | Should Be ''
        }
        It 'is ASCII only' {
            $bad = @($script:DriverExplanations | Where-Object { $_[1] -match '[^\x20-\x7E]' })
            $bad.Count | Should Be 0
        }
    }

    Describe 'ConvertTo-RTDriverTraceResult' {
        $stat = { param($n, $c, $t, $m, $dpc, $isr) [pscustomobject]@{ Driver = $n; Count = $c; TotalTicks = $t; MaxTicks = $m; Dpc = $dpc; Isr = $isr } }
        # 10 MHz clock: 1 tick = 0.1 us
        $raw = [pscustomobject]@{
            Ok = $true; Error = $null; Seconds = 10.04; Events = 1500; EventsLost = 0; BuffersLost = 0; Frequency = 10000000
            Drivers = @(
                (& $stat 'ndis.sys' 1000 30000 2000 $true $false),
                (& $stat 'nvlddmkm.sys' 400 60000 15000 $true $true),
                (& $stat 'USBXHCI.SYS' 100 10000 500 $false $true))
        }
        $r = ConvertTo-RTDriverTraceResult -Raw $raw
        It 'sorts by MaxUs descending' {
            ($r.Drivers | ForEach-Object Driver) -join ',' | Should Be 'nvlddmkm.sys,ndis.sys,USBXHCI.SYS'
        }
        It 'converts ticks to microseconds and milliseconds' {
            $r.Drivers[0].MaxUs | Should Be 1500
            $r.Drivers[0].TotalMs | Should Be 6
            $r.Drivers[1].MaxUs | Should Be 200
        }
        It 'computes the share of DPC/ISR time' {
            $r.Drivers[0].PercentTime | Should Be 60
            $r.Drivers[1].PercentTime | Should Be 30
        }
        It 'derives the kind' {
            $r.Drivers[0].Kind | Should Be 'DPC+ISR'
            $r.Drivers[1].Kind | Should Be 'DPC'
            $r.Drivers[2].Kind | Should Be 'ISR'
        }
        It 'attaches explanations and keeps the header fields' {
            $r.Drivers[1].Explanation | Should Be (Get-RTDriverExplanation -Driver 'ndis.sys')
            $r.Ok | Should Be $true
            $r.Seconds | Should Be 10
            $r.Events | Should Be 1500
        }
        It 'treats a run without events as failed' {
            $empty = [pscustomobject]@{ Ok = $true; Error = $null; Seconds = 5; Events = 0; EventsLost = 0; BuffersLost = 0; Frequency = 10000000; Drivers = @() }
            $e = ConvertTo-RTDriverTraceResult -Raw $empty
            $e.Ok | Should Be $false
            $e.Error | Should Match 'no DPC/ISR events'
            @($e.Drivers).Count | Should Be 0
        }
    }

    Describe 'Get-RTDriverTraceFindings' {
        $drv = { param($n, $max) [pscustomobject]@{ Driver = $n; Kind = 'DPC'; Count = 10; MaxUs = $max; TotalMs = 1.5; PercentTime = 12.5; Explanation = (Get-RTDriverExplanation -Driver $n) } }
        $res = { param($drivers) [pscustomobject]@{ Ok = $true; Error = ''; Seconds = 10; Events = 100; EventsLost = 0; BuffersLost = 0; Drivers = $drivers } }

        It 'flags >= 1000 us as Problem and >= 500 us as Warning' {
            $f = @(Get-RTDriverTraceFindings -Result (& $res @((& $drv 'nvlddmkm.sys' 1000), (& $drv 'ndis.sys' 500), (& $drv 'acpi.sys' 499.9))))
            $f.Count | Should Be 2
            $f[0].Id | Should Be 'drv.nvlddmkm.sys'
            $f[0].Severity | Should Be 'Problem'
            $f[1].Id | Should Be 'drv.ndis.sys'
            $f[1].Severity | Should Be 'Warning'
        }
        It 'puts count, max and percent in Detail and the explanation in Advice' {
            $f = @(Get-RTDriverTraceFindings -Result (& $res @((& $drv 'ndis.sys' 2500))))[0]
            $f.Category | Should Be 'Latency'
            $f.GuideId | Should Be 'latencymon'
            $f.Detail | Should Match '10 DPC calls'
            $f.Detail | Should Match '2500 us'
            $f.Detail | Should Match '12.5%'
            $f.Advice | Should Be (Get-RTDriverExplanation -Driver 'ndis.sys')
        }
        It 'gives generic advice for unknown drivers' {
            $f = @(Get-RTDriverTraceFindings -Result (& $res @((& $drv 'vendorx.sys' 800))))[0]
            $f.Severity | Should Be 'Warning'
            $f.Advice.Length -gt 0 | Should Be $true
        }
        It 'returns one Ok summary when every driver is below 500 us' {
            $f = @(Get-RTDriverTraceFindings -Result (& $res @((& $drv 'ndis.sys' 120), (& $drv 'acpi.sys' 80))))
            $f.Count | Should Be 1
            $f[0].Severity | Should Be 'Ok'
            $f[0].Id | Should Be 'drv.trace'
            $f[0].Detail | Should Match 'ndis.sys 120 us'
        }
        It 'returns Info when nothing was recorded' {
            $f = @(Get-RTDriverTraceFindings -Result (& $res @()))
            $f.Count | Should Be 1
            $f[0].Severity | Should Be 'Info'
        }
        It 'returns Info with the error when the trace failed' {
            $failed = [pscustomobject]@{ Ok = $false; Error = 'kernel logger busy'; Seconds = 0; Events = 0; EventsLost = 0; BuffersLost = 0; Drivers = @() }
            $f = @(Get-RTDriverTraceFindings -Result $failed)
            $f.Count | Should Be 1
            $f[0].Severity | Should Be 'Info'
            $f[0].Detail | Should Be 'kernel logger busy'
            @(Get-RTDriverTraceFindings -Result $null)[0].Severity | Should Be 'Info'
        }
    }

    Describe 'Start-RTDriverTrace / Stop-RTDriverTrace' {
        It 'refuses to start without administrator rights' {
            Mock Test-RTAdmin { $false }
            { Start-RTDriverTrace } | Should Throw 'Run as administrator to name the driver'
        }
        It 'explains a busy kernel logger without stopping it' {
            Get-RTDriverTraceStartError -Code 183 | Should Match 'LatencyMon'
            Get-RTDriverTraceStartError -Code 5 | Should Match 'Run as administrator'
            Get-RTDriverTraceStartError -Code -1 | Should Match 'already running in this tool'
            Get-RTDriverTraceStartError -Code 87 | Should Match '87'
        }
        It 'returns a failed result for a missing handle instead of throwing' {
            $r = Stop-RTDriverTrace -Trace $null
            $r.Ok | Should Be $false
            @($r.Drivers).Count | Should Be 0
        }
        It 'returns the cached result when stopped twice and a never-started trace has no session' {
            $t = New-Object RTAudio.DriverTrace
            $t.IsRunning | Should Be $false
            $a = Stop-RTDriverTrace -Trace $t
            $b = Stop-RTDriverTrace -Trace $t
            $a.Ok | Should Be $false     # no events
            $b.Ok | Should Be $false
        }
    }

    Describe 'RTAudio.DriverTrace native helpers' {
        It 'has the Windows SDK structure layout' {
            [RTAudio.DriverTrace]::CheckLayout() | Should Be ''
        }
        It 'maps an address to the greatest driver base below it' {
            $bases = [uint64[]]@(0x1000, 0x5000, 0x9000)
            $names = [string[]]@('a.sys', 'b.sys', 'c.sys')
            [RTAudio.DriverTrace]::Resolve(0x5000, $bases, $names) | Should Be 'b.sys'
            [RTAudio.DriverTrace]::Resolve(0x8FFF, $bases, $names) | Should Be 'b.sys'
            [RTAudio.DriverTrace]::Resolve([uint64]::Parse('FFFFF80000000000', 'HexNumber'), $bases, $names) | Should Be 'c.sys'
            [RTAudio.DriverTrace]::Resolve(0x10, $bases, $names) | Should Be $null
            [RTAudio.DriverTrace]::Resolve(0, $bases, $names) | Should Be $null
        }
        It 'aggregates routines per driver' {
            $t = New-Object RTAudio.DriverTrace
            $t.Record(0x1100, 50, $false)
            $t.Record(0x1200, 300, $false)
            $t.Record(0x5100, 20, $true)
            $t.Record(0x5100, -5, $true)       # bad timestamp, ignored
            $s = $t.Summarize([uint64[]]@(0x1000, 0x5000), [string[]]@('a.sys', 'b.sys'))
            $s.Count | Should Be 2
            $s[0].Driver | Should Be 'a.sys'
            $s[0].Count | Should Be 2
            $s[0].TotalTicks | Should Be 350
            $s[0].MaxTicks | Should Be 300
            $s[1].Count | Should Be 1
            $s[1].Isr | Should Be $true
        }
        It 'lists drivers without throwing (names need elevation)' {
            $bases = $null; $names = $null
            { [RTAudio.DriverTrace]::GetDrivers([ref]$bases, [ref]$names) } | Should Not Throw
        }
    }
}
