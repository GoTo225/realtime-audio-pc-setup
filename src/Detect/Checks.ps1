# Read-only anomaly checks. Each detector gets ($ctx, $latencySeconds) and returns findings.

Register-RTDetector -Id 'daws' -Detect {
    param($ctx)
    if (-not $ctx.Daws) {
        return New-RTFinding -Id 'daw.none' -Severity Info -Category 'Software' -Title 'No supported DAW detected' `
            -Detail 'Looked for FL Studio, Cubase, Nuendo, Ableton Live, REAPER, Bitwig Studio, Studio One and Pro Tools.'
    }
    foreach ($d in $ctx.Daws) {
        $guide = 'daw-' + ($d.Name -replace '[^A-Za-z0-9]', '').ToLower()
        New-RTFinding -Id "daw.$guide" -Severity Info -Category 'Software' -Title "Detected $($d.DisplayName)" `
            -Detail "Version $($d.Version)" -Advice 'See the guide for the recommended audio settings for this DAW.' -GuideId $guide
    }
}

Register-RTDetector -Id 'asio' -Detect {
    param($ctx)
    $asio = @(Get-RTAsioDrivers)
    $vendor = @($asio | Where-Object { -not $_.Generic })
    $list = ($asio | ForEach-Object Name) -join ', '
    if (-not $asio) {
        New-RTFinding -Id 'asio.none' -Severity Problem -Category 'Audio driver' -Title 'No ASIO driver installed' `
            -Advice 'Install the ASIO driver from your audio interface manufacturer. Without an interface, FL Studio ASIO or ASIO4ALL is the fallback.' -GuideId 'asio-driver'
    } elseif (-not $vendor -and $ctx.Interfaces) {
        New-RTFinding -Id 'asio.generic-with-interface' -Severity Warning -Category 'Audio driver' `
            -Title "Audio interface found ($(($ctx.Interfaces | ForEach-Object Name) -join ', ')), but only generic ASIO drivers are installed" `
            -Detail "Installed: $list" -Advice "Install the manufacturer's ASIO driver; generic wrappers add latency and are less stable." -GuideId 'asio-driver'
    } elseif (-not $vendor) {
        New-RTFinding -Id 'asio.generic-only' -Severity Info -Category 'Audio driver' -Title 'Only generic ASIO drivers installed' `
            -Detail "Installed: $list" -Advice 'Fine for onboard audio. For low latency (under ~10 ms) a dedicated audio interface with its own ASIO driver is strongly recommended.' -GuideId 'asio-driver'
    } else {
        New-RTFinding -Id 'asio.ok' -Severity Ok -Category 'Audio driver' -Title "Dedicated ASIO driver installed: $(($vendor | ForEach-Object Name) -join ', ')" -Detail "All: $list"
    }
}

Register-RTDetector -Id 'interface' -Detect {
    param($ctx)
    if (-not $ctx.Interfaces) {
        return New-RTFinding -Id 'iface.none' -Severity Info -Category 'Hardware' -Title 'No dedicated audio interface detected' `
            -Detail "Audio devices: $((@($ctx.AudioDevices | Where-Object Type -ne 'Virtual') | ForEach-Object { "$($_.Name) [$($_.Type)]" }) -join '; ')" `
            -Advice 'If you do have one connected, it may use an unknown vendor ID; the other checks still apply.'
    }
    foreach ($i in $ctx.Interfaces) {
        $n = $i.Name
        if (-not $i.Enabled) {
            New-RTFinding -Id "iface.disabled.$n" -Severity Problem -Category 'Hardware' -Title "$n is disabled in Device Manager" -GuideId 'asio-driver'
            continue
        }
        if ($i.Status -ne 'OK') {
            New-RTFinding -Id "iface.status.$n" -Severity Problem -Category 'Hardware' -Title "$n reports status '$($i.Status)'" `
                -Advice 'Reinstall the manufacturer driver and reconnect the device.' -GuideId 'asio-driver'
        }
        if ($i.DriverProvider -match '^Microsoft' -or $i.Service -match '^usbaudio2?$') {
            New-RTFinding -Id "iface.classdriver.$n" -Severity Warning -Category 'Audio driver' -Title "$n uses the generic Windows USB audio driver" `
                -Detail "Driver: $($i.DriverProvider) $($i.DriverVersion) ($($i.Service))" `
                -Advice "Most interfaces reach their lowest stable latency only with the manufacturer's driver." -GuideId 'asio-driver'
        } elseif ($i.DriverDate -and $i.DriverDate -lt (Get-Date).AddYears(-3)) {
            New-RTFinding -Id "iface.olddriver.$n" -Severity Info -Category 'Audio driver' -Title "$n driver is from $($i.DriverDate.ToString('yyyy-MM'))" `
                -Detail "$($i.DriverProvider) $($i.DriverVersion)" -Advice 'Check the manufacturer site for a newer driver.' -GuideId 'asio-driver'
        }
        if ($i.InstanceId -match '^USB\\') {
            $hubs = Get-RTUsbHubDepth -InstanceId $i.InstanceId
            if ($hubs -gt 0) {
                New-RTFinding -Id "iface.hub.$n" -Severity Warning -Category 'Hardware' -Title "$n is connected through $hubs USB hub(s)" `
                    -Advice 'Connect the interface directly to a USB port on the motherboard (rear I/O); monitor and keyboard hubs are common dropout sources.' -GuideId 'usb-connection'
            } else {
                New-RTFinding -Id "iface.direct.$n" -Severity Ok -Category 'Hardware' -Title "$n is connected directly (no USB hub)"
            }
        }
    }
}

Register-RTDetector -Id 'power-source' -Detect {
    param($ctx)
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if (-not $bat) { return }
    if ($bat | Where-Object { $_.BatteryStatus -eq 1 }) {
        New-RTFinding -Id 'power.battery' -Severity Warning -Category 'Power' -Title 'Running on battery' `
            -Advice 'Plug in the charger: on battery Windows and the firmware throttle the CPU regardless of the power plan.' -GuideId 'laptop'
    } else {
        New-RTFinding -Id 'power.laptop' -Severity Info -Category 'Power' -Title 'Laptop detected' -Advice 'Always produce on AC power; see the laptop guide page.' -GuideId 'laptop'
    }
}

Register-RTDetector -Id 'latency' -Slow -Detect {
    param($ctx, $seconds)
    if ($seconds -le 0) { return }
    $s = Get-RTLatencySample -Seconds $seconds
    if (-not $s.Cores) { return New-RTFinding -Id 'lat.unavailable' -Severity Info -Category 'Latency' -Title 'Performance counters unavailable; latency sampling skipped' }
    $worstDpc = $s.Cores | Sort-Object DpcMax -Descending | Select-Object -First 1
    $worstIsr = $s.Cores | Sort-Object IsrMax -Descending | Select-Object -First 1
    $detail = "Sampled $($s.Seconds) s. Highest DPC time: core $($worstDpc.Core) peak $($worstDpc.DpcMax)% (avg $($worstDpc.DpcAvg)%). " +
              "Highest interrupt time: core $($worstIsr.Core) peak $($worstIsr.IsrMax)% (avg $($worstIsr.IsrAvg)%)."
    # Sustained load (per-core average) matters more than a single busy 1-second window.
    $peak = [math]::Max($worstDpc.DpcMax, $worstIsr.IsrMax)
    $sustained = ($s.Cores | ForEach-Object { [math]::Max($_.DpcAvg, $_.IsrAvg) } | Measure-Object -Maximum).Maximum
    $advice = 'This is a coarse indicator. Run LatencyMon for 10+ minutes to find the exact driver (e.g. ndis.sys = network, nvlddmkm.sys = NVIDIA, ACPI.sys = power management).'
    if ($sustained -ge 5 -or $peak -ge 25) {
        New-RTFinding -Id 'lat.dpc' -Severity Problem -Category 'Latency' -Title 'High DPC/interrupt load detected' -Detail $detail -Advice $advice -GuideId 'latencymon'
    } elseif ($sustained -ge 2 -or $peak -ge 10) {
        New-RTFinding -Id 'lat.dpc' -Severity Warning -Category 'Latency' -Title 'Elevated DPC/interrupt load' -Detail $detail -Advice $advice -GuideId 'latencymon'
    } else {
        New-RTFinding -Id 'lat.dpc' -Severity Ok -Category 'Latency' -Title 'DPC/interrupt load looks normal' -Detail $detail -Advice 'For a definitive answer, run LatencyMon while playing a project.' -GuideId 'latencymon'
    }
    if ($null -ne $s.PerfMin -and $s.PerfMin -lt 70) {
        New-RTFinding -Id 'lat.throttle' -Severity Warning -Category 'Power' -Title "CPU dropped to $($s.PerfMin)% of nominal performance while sampling" `
            -Detail "Average: $($s.PerfAvg)%." -Advice 'Apply the power tweaks (High/Ultimate Performance plan, minimum processor state) and check cooling/BIOS power limits.' -GuideId 'bios'
    }
}

Register-RTDetector -Id 'vbs' -Detect {
    param($ctx)
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if (-not $dg) { return }
    if (@($dg.SecurityServicesRunning) -contains 2) {
        New-RTFinding -Id 'sec.hvci' -Severity Warning -Category 'Security vs. latency' -Title 'Memory Integrity (HVCI) is on' `
            -Detail 'Virtualization-based code integrity adds overhead to driver calls and can raise DPC latency on some systems.' `
            -Advice 'Only consider turning it off if LatencyMon shows problems; it is a real security feature. On managed (work) PCs leave it alone.' -GuideId 'memory-integrity'
    } elseif ($dg.VirtualizationBasedSecurityStatus -eq 2) {
        New-RTFinding -Id 'sec.vbs' -Severity Info -Category 'Security vs. latency' -Title 'Virtualization-based security is running' -GuideId 'memory-integrity'
    }
}

Register-RTDetector -Id 'antivirus' -Detect {
    param($ctx)
    $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    foreach ($p in $av | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' }) {
        New-RTFinding -Id "sec.av.$($p.displayName)" -Severity Info -Category 'Background' -Title "Third-party antivirus: $($p.displayName)" `
            -Advice 'Add exclusions for your DAW, plugin and sample folders in its settings; the Defender tweak does not affect it.'
    }
}

$script:BackgroundApps = [ordered]@{
    'iCUE' = 'Corsair iCUE'; 'ArmouryCrate' = 'ASUS Armoury Crate'; 'LightingService' = 'ASUS Aura'; 'NZXT CAM' = 'NZXT CAM'
    'SignalRgb' = 'SignalRGB'; 'RazerCentralService' = 'Razer Synapse'; 'lghub' = 'Logitech G HUB'; 'MSI.CentralServer' = 'MSI Center'
    'OneDrive' = 'OneDrive'; 'Dropbox' = 'Dropbox'; 'GoogleDriveFS' = 'Google Drive'; 'steam' = 'Steam'
    'EpicGamesLauncher' = 'Epic Games Launcher'; 'Discord' = 'Discord'; 'ms-teams' = 'Microsoft Teams'
}

Register-RTDetector -Id 'background' -Detect {
    param($ctx)
    $running = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
    $hits = @($script:BackgroundApps.Keys | Where-Object { $running -contains $_ } | ForEach-Object { $script:BackgroundApps[$_] })
    if ($hits) {
        New-RTFinding -Id 'bg.apps' -Severity Info -Category 'Background' -Title "Background apps that commonly interfere: $($hits -join ', ')" `
            -Advice 'Quit them while recording, or remove them from startup. RGB/monitoring tools poll hardware (SMBus/USB) and cause latency spikes; sync tools hit the disk.' -GuideId 'startup-apps'
    }
}

Register-RTDetector -Id 'reboot' -Detect {
    param($ctx)
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($pending) {
        New-RTFinding -Id 'sys.reboot' -Severity Warning -Category 'System' -Title 'A reboot is pending' -Advice 'Updates are half-installed and may run maintenance in the background. Reboot before a session.' -GuideId 'windows-update'
    }
}

Register-RTDetector -Id 'storage' -Detect {
    param($ctx)
    $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue
    if ($sys -and $sys.Size) {
        $pct = [math]::Round(100 * $sys.FreeSpace / $sys.Size)
        if ($pct -lt 10) {
            New-RTFinding -Id 'disk.free' -Severity Warning -Category 'Storage' -Title "System drive is $(100 - $pct)% full" -Detail "$([math]::Round($sys.FreeSpace / 1GB)) GB free" -Advice 'Keep at least 10-15% free for the page file, plugin caches and recording.'
        }
    }
    $hdd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object MediaType -eq 'HDD')
    if ($hdd) {
        New-RTFinding -Id 'disk.hdd' -Severity Info -Category 'Storage' -Title "Spinning hard disk(s) present: $(($hdd | ForEach-Object FriendlyName) -join ', ')" `
            -Advice 'Keep sample libraries and projects on an SSD; HDDs are fine for backups and archives.'
    }
    $trim = fsutil behavior query DisableDeleteNotify 2>$null
    if ("$trim" -match 'NTFS\s+DisableDeleteNotify\s*=\s*1') {
        New-RTFinding -Id 'disk.trim' -Severity Warning -Category 'Storage' -Title 'TRIM is disabled for NTFS' -Advice 'Enable it: fsutil behavior set DisableDeleteNotify 0'
    }
}

Register-RTDetector -Id 'memory' -Detect {
    param($ctx)
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $cs) { return }
    $gb = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    if ($gb -lt 8) {
        New-RTFinding -Id 'mem.low' -Severity Warning -Category 'Hardware' -Title "Only $gb GB RAM" -Advice 'Sample-based instruments page to disk with less than 16 GB; 32 GB is comfortable for orchestral work.'
    } elseif ($gb -lt 16) {
        New-RTFinding -Id 'mem.mid' -Severity Info -Category 'Hardware' -Title "$gb GB RAM" -Advice '16 GB or more is recommended for larger sample libraries.'
    }
}

Register-RTDetector -Id 'wireless' -Detect {
    param($ctx)
    $wifi = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.NdisPhysicalMedium -eq 9 -or $_.PhysicalMediaType -match '802\.11') })
    $bt = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' -and $_.InstanceId -match '^(USB|PCI)\\' })
    if ($wifi -or $bt) {
        $what = @(); if ($wifi) { $what += 'Wi-Fi' }; if ($bt) { $what += 'Bluetooth' }
        New-RTFinding -Id 'net.wireless' -Severity Info -Category 'Network' -Title "$($what -join ' and ') active" `
            -Advice 'Wireless drivers are a frequent cause of DPC spikes (ndis.sys, wdiwifi.sys, bthport.sys). If LatencyMon points there, turn them off (airplane mode) while recording. Never use Bluetooth headphones for monitoring: they add 100-300 ms.' -GuideId 'latencymon'
    }
}
