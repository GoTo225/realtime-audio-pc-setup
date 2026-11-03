# "Is this PC suitable for real-time audio?" Aggregates the scan, a few hardware facts and the
# real-time probe into one verdict with a rating per area. Areas are marked by what they are:
#   Hardware - a limit of the machine; tweaks will not change it
#   Setup    - fixable with this tool, a driver install or a manual step
#   Measured - the real-time probe result on this machine as it is right now

function Get-RTHardwareFacts {
    $f = @{ Cpu = $null; RamGB = $null; SystemDisk = $null; FreePct = $null; IsLaptop = $false; OnBattery = $false }
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    if ($cpu) {
        $classes = 0; try { $classes = [RTAudio.RealtimeProbe]::EfficiencyClasses() } catch { }
        $f.Cpu = @{
            Name    = "$($cpu[0].Name)".Trim()
            Cores   = [int](($cpu | Measure-Object NumberOfCores -Sum).Sum)
            Threads = [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
            Hybrid  = $classes -gt 1
        }
    }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { $f.RamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB) }
    try {
        $num = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop).DiskNumber
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$num" } | Select-Object -First 1
        if ($pd) { $f.SystemDisk = @{ Name = "$($pd.FriendlyName)"; MediaType = "$($pd.MediaType)"; BusType = "$($pd.BusType)" } }
    } catch { }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue
    if ($ld -and $ld.Size) { $f.FreePct = [math]::Round(100 * $ld.FreeSpace / $ld.Size) }
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $f.IsLaptop = [bool]$bat
    $f.OnBattery = [bool]($bat | Where-Object { $_.BatteryStatus -eq 1 })
    $f
}

function New-RTArea {
    param([string]$Area, [ValidateSet('Good', 'Fair', 'Poor', 'Unknown')][string]$Rating,
          [ValidateSet('Hardware', 'Setup', 'Measured')][string]$Kind, [string]$Summary, [string]$Advice = '', [string]$GuideId = '')
    [pscustomobject]@{ Area = $Area; Rating = $Rating; Kind = $Kind; Summary = $Summary; Advice = $Advice; GuideId = $GuideId }
}

function Get-RTReadiness {
    <#
      Pure function over collected facts (so it can be tested with fake machines):
        Hardware  : output of Get-RTHardwareFacts
        Interfaces, VendorAsio (bool: the interface's own 64-bit ASIO driver is installed),
        AsioNames (string, optional), AnyAsio (bool), ClassDriverOnly (bool)
        Probe     : output of Invoke-RTRealtimeProbe or $null
        OpenTweaks: number of Safe/Recommended tweaks that are not applied yet
        Throttled : CPU dropped below 70 % during latency sampling
    #>
    param([Parameter(Mandatory)][hashtable]$Facts)
    $hw = $Facts.Hardware
    $areas = New-Object System.Collections.ArrayList

    # CPU
    if ($hw.Cpu) {
        $c = $hw.Cpu
        $sum = "$($c.Name), $($c.Cores) cores / $($c.Threads) threads" + $(if ($c.Hybrid) { ' (hybrid P/E cores)' } else { '' })
        $rating = if ($c.Threads -lt 4) { 'Poor' } elseif ($c.Cores -lt 4) { 'Fair' } else { 'Good' }
        $adv = switch ($rating) {
            'Poor' { 'Fewer than 4 threads: expect overloads with more than a handful of plugins. Freeze/render tracks often.' }
            'Fair' { 'Dual-core CPUs handle small projects; heavy synths and many plugins will need large buffers.' }
            default { if ($c.Hybrid) { 'Hybrid CPU: keep the High/Ultimate Performance plan (Recommended preset) so audio threads are not pushed to E-cores. If dropouts persist, test with E-cores disabled in the BIOS.' } else { '' } }
        }
        [void]$areas.Add((New-RTArea 'CPU' $rating 'Hardware' $sum $adv 'bios'))
    } else { [void]$areas.Add((New-RTArea 'CPU' 'Unknown' 'Hardware' 'Could not read processor information')) }

    # Memory
    if ($hw.RamGB) {
        $rating = if ($hw.RamGB -lt 8) { 'Poor' } elseif ($hw.RamGB -lt 16) { 'Fair' } else { 'Good' }
        $adv = @{ Poor = 'Below 8 GB even small sample libraries page to disk. Upgrade RAM.'; Fair = 'Fine for synths and small libraries; 16 GB+ for sample-heavy work, 32 GB for orchestral.'; Good = '' }[$rating]
        [void]$areas.Add((New-RTArea 'Memory' $rating 'Hardware' "$($hw.RamGB) GB RAM" $adv))
    }

    # Storage
    if ($hw.SystemDisk) {
        $d = $hw.SystemDisk
        $rating = switch ($d.MediaType) { 'HDD' { 'Poor' } 'SSD' { 'Good' } default { if ($d.BusType -eq 'NVMe') { 'Good' } else { 'Unknown' } } }
        $adv = if ($rating -eq 'Poor') { 'Windows runs from a spinning disk: slow plugin loading and streaming. Move the system, plugins and samples to an SSD.' } else { '' }
        if ($null -ne $hw.FreePct -and $hw.FreePct -lt 10 -and $rating -eq 'Good') { $rating = 'Fair'; $adv = "Only $($hw.FreePct)% free on the system drive; keep 10-15% free." }
        [void]$areas.Add((New-RTArea 'Storage' $rating 'Hardware' "System drive: $($d.Name) ($($d.BusType), $($d.MediaType))" $adv))
    }

    # Audio interface (hardware) and its driver (setup)
    $ifaces = @($Facts.Interfaces)
    if ($ifaces) {
        [void]$areas.Add((New-RTArea 'Audio interface' 'Good' 'Hardware' "$(($ifaces | ForEach-Object Name | Select-Object -Unique) -join ', ')"))
        if ($Facts.VendorAsio -and -not $Facts.ClassDriverOnly) {
            [void]$areas.Add((New-RTArea 'Audio driver' 'Good' 'Setup' $(if ($Facts['AsioNames']) { "Own ASIO driver: $($Facts['AsioNames'])" } else { 'Manufacturer ASIO driver installed' })))
        } else {
            [void]$areas.Add((New-RTArea 'Audio driver' 'Poor' 'Setup' 'Interface runs without its manufacturer ASIO driver' `
                "Install the interface's own driver; generic drivers rarely run stably below 256 samples." 'asio-driver'))
        }
    } else {
        [void]$areas.Add((New-RTArea 'Audio interface' 'Fair' 'Hardware' 'No dedicated audio interface found (onboard audio)' `
            'Onboard audio typically needs 256-512 samples and is not suited for recording with live monitoring. A USB interface is the single biggest upgrade.' 'asio-driver'))
        $rating = if ($Facts.AnyAsio) { 'Fair' } else { 'Poor' }
        [void]$areas.Add((New-RTArea 'Audio driver' $rating 'Setup' $(if ($Facts.AnyAsio) { 'Generic ASIO driver available' } else { 'No ASIO driver installed' }) `
            'With onboard audio use FL Studio ASIO or ASIO4ALL.' 'asio-driver'))
    }

    # Power
    if ($hw.OnBattery) {
        [void]$areas.Add((New-RTArea 'Power' 'Poor' 'Setup' 'Laptop running on battery' 'Plug in the charger: on battery the CPU is throttled. Re-run the check on AC power.' 'laptop'))
    } elseif ($Facts.Throttled) {
        [void]$areas.Add((New-RTArea 'Power' 'Fair' 'Setup' 'CPU dropped below 70% of nominal speed while sampling' 'Apply the power tweaks; check cooling and BIOS power limits.' 'bios'))
    } else {
        [void]$areas.Add((New-RTArea 'Power' 'Good' 'Setup' $(if ($hw.IsLaptop) { 'Laptop on AC power' } else { 'Mains powered' })))
    }

    # Windows tuning
    $open = [int]$Facts.OpenTweaks
    [void]$areas.Add((New-RTArea 'Windows tuning' $(if ($open -eq 0) { 'Good' } else { 'Fair' }) 'Setup' `
        $(if ($open -eq 0) { 'All Safe/Recommended tweaks applied' } else { "$open Safe/Recommended tweak(s) not applied" }) `
        $(if ($open) { 'Apply the Recommended preset on the Tweaks tab, then re-check.' } else { '' })))

    # Real-time probe
    $p = $Facts.Probe
    $stable = $null
    if ($p -and $p.Ok) {
        $stable = $p.StableBuffer
        $rating = if ($null -eq $stable) { 'Poor' } elseif ($stable -le 128) { 'Good' } elseif ($stable -le 512) { 'Fair' } else { 'Poor' }
        $sum = if ($null -eq $stable) { "Stalls even at 1024 samples (worst $($p.MaxMs) ms)" } else {
            "Stable down to $stable samples ($([math]::Round(1000.0 * $stable / 48000, 1)) ms at 48 kHz); worst stall $($p.MaxMs) ms" }
        $adv = if ($rating -eq 'Good') { 'Run LatencyMon for a long test with your DAW open to confirm.' } else {
            'Something steals time from audio threads. Apply the tweaks, close background apps, turn off Wi-Fi/Bluetooth, then run LatencyMon to find the driver.' }
        $top = $null
        if ($p.PSObject.Properties['Drivers'] -and $p.Drivers -and $p.Drivers.Ok) { $top = @($p.Drivers.Drivers) | Where-Object { $_.MaxUs -ge 500 } | Select-Object -First 1 }
        if ($top) {
            $adv = "Longest interruption: $($top.Driver) ($([math]::Round($top.MaxUs)) us). " + $(if ($top.Explanation) { $top.Explanation } else { 'Update or replace that driver.' })
        }
        [void]$areas.Add((New-RTArea 'Real-time performance' $rating 'Measured' $sum $adv 'latencymon'))
    } else {
        [void]$areas.Add((New-RTArea 'Real-time performance' 'Unknown' 'Measured' $(if ($p) { "Probe failed: $($p.Error)" } else { 'Not measured' })))
    }

    # Verdict
    $hwRatings = @($areas | Where-Object Kind -eq 'Hardware' | ForEach-Object Rating)
    $setupIssues = @($areas | Where-Object { $_.Kind -eq 'Setup' -and $_.Rating -in 'Fair', 'Poor' })
    $measured = [bool]($p -and $p.Ok)
    $level = if ($hwRatings -contains 'Poor' -or ($measured -and $null -eq $stable)) { 'NotSuitable' }
             elseif ($hwRatings -contains 'Fair' -or ($measured -and $stable -gt 256)) { 'Limited' }
             else { 'Suitable' }
    $headline = @{ Suitable = 'Suitable for real-time audio'; Limited = 'Suitable with limits'; NotSuitable = 'Not well suited for real-time audio' }[$level]
    $use = if (-not $measured) { 'Real-time performance was not measured.' }
           elseif ($null -eq $stable) { 'Even large buffers drop out right now.' }
           elseif ($stable -le 128) { "Recording with live monitoring at $stable samples should work." }
           elseif ($stable -le 256) { "Good for producing at $stable samples; for recording, " + $(if ($ifaces) { "use your interface's direct monitoring." } else { 'monitor the source directly, not through the PC.' }) }
           else { "Use $stable samples or more: fine for mixing, too much latency for playing live." }
    if ($measured -and -not $ifaces -and $null -ne $stable) { $use += ' The probe rates the PC; onboard audio drivers usually need larger buffers than that.' }
    if ($setupIssues) { $use += " $($setupIssues.Count) fixable item(s) below should improve this." }

    [pscustomobject]@{
        Level        = $level
        Headline     = $headline
        Summary      = $use
        StableBuffer = $stable
        Areas        = @($areas)
        Probe        = $p
    }
}

function Get-RTReadinessForScan {
    # Collects the facts for Get-RTReadiness from a finished scan (plus hardware queries).
    param([Parameter(Mandatory)]$Scan, $Probe)
    $ctx = $Scan.Context
    $asio = @(Get-RTAsioDrivers)
    $ifaces = @($ctx.Interfaces | Where-Object Enabled)
    $own = @(Get-RTAsioMatch -Interfaces $ifaces -Drivers $asio | ForEach-Object { $_.Drivers })
    $recommended = @($Scan.Tweaks | Where-Object { $_.Status -eq 'NotOptimal' -and @($_.Presets | Where-Object { $_ -in 'Safe', 'Recommended' }).Count })
    Get-RTReadiness -Facts @{
        Hardware        = Get-RTHardwareFacts
        Interfaces      = $ifaces
        VendorAsio      = [bool]$own
        AsioNames       = ($own | ForEach-Object Name | Select-Object -Unique) -join ', '
        AnyAsio         = [bool]$asio
        ClassDriverOnly = [bool]($ifaces -and -not ($ifaces | Where-Object { $_.DriverProvider -notmatch '^Microsoft' -and $_.Service -notmatch '^usbaudio2?$' }))
        Probe           = $Probe
        OpenTweaks      = $recommended.Count
        Throttled       = [bool]($Scan.Findings | Where-Object Id -eq 'lat.throttle')
    }
}

Register-RTDetector -Id 'cpu' -Detect {
    param($ctx)
    $classes = 0; try { $classes = [RTAudio.RealtimeProbe]::EfficiencyClasses() } catch { }
    if ($classes -gt 1) {
        New-RTFinding -Id 'cpu.hybrid' -Severity Info -Category 'Hardware' -Title 'Hybrid CPU with performance and efficiency cores' `
            -Advice 'Windows may schedule audio threads on slower E-cores when power saving kicks in. Use the High/Ultimate Performance plan and no core parking (Recommended preset); if dropouts persist, test with E-cores disabled in the BIOS.' -GuideId 'bios'
    }
}
