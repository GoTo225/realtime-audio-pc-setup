# Memory configuration and firmware/driver age. Read-only, no admin needed.
# Decision logic lives in pure functions (Get-RT*Findings) over plain objects; collectors do the CIM calls.

# SMBIOS memory device types (SMBIOS spec 7.18.2) and form factors (Win32_PhysicalMemory.FormFactor).
$script:MemoryTypeNames = @{ 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
$script:LpddrTypes = @(27, 28, 29, 30, 35)
$script:SocketedFormFactors = @(8, 12)          # 8 = DIMM, 12 = SODIMM; 6 = proprietary (e.g. CAMM2), 0 = unknown

function Get-RTMemoryModules {
    @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Capacity             = [uint64]$_.Capacity
            Speed                = [int]$_.Speed
            ConfiguredClockSpeed = [int]$_.ConfiguredClockSpeed
            SMBIOSMemoryType     = [int]$_.SMBIOSMemoryType
            FormFactor           = [int]$_.FormFactor
        }
    })
}

function Get-RTMemoryFindings {
    <#
      Pure: Modules = objects with Capacity, Speed, ConfiguredClockSpeed (MT/s), SMBIOSMemoryType, FormFactor.
      IsLaptop = a battery is present. Returns 0..2 findings.
    #>
    param([object[]]$Modules, [bool]$IsLaptop)
    $mods = @($Modules | Where-Object { $_ -and $_.Capacity -gt 0 })
    if (-not $mods) { return }
    $type = [int]$mods[0].SMBIOSMemoryType
    $typeName = if ($script:MemoryTypeNames.ContainsKey($type)) { $script:MemoryTypeNames[$type] } else { '' }
    $lpddr = $script:LpddrTypes -contains $type
    $socketed = @($mods | Where-Object { $script:SocketedFormFactors -contains [int]$_.FormFactor -or [int]$_.FormFactor -eq 0 }).Count -eq $mods.Count
    $gb = [math]::Round((($mods | Measure-Object Capacity -Sum).Sum) / 1GB)
    $desc = "$($mods.Count) module(s), $gb GB" + $(if ($typeName) { " $typeName" } else { '' })

    # Soldered LPDDR and CAMM modules are multi-channel by design even when reported as one entry.
    if ($mods.Count -eq 1 -and $socketed -and -not $lpddr) {
        if ($IsLaptop) {
            New-RTFinding -Id 'mem.single-channel' -Severity Info -Category 'Hardware' -Title 'Possibly single-channel memory (one memory module reported)' `
                -Detail $desc -Advice 'One module usually means half the memory bandwidth. If the laptop has a free SO-DIMM slot, a second identical module helps with sample-heavy projects. Some laptops add soldered memory that Windows does not list separately; check the specifications.' -GuideId 'bios'
        } else {
            New-RTFinding -Id 'mem.single-channel' -Severity Info -Category 'Hardware' -Title 'Likely single-channel memory (one memory module installed)' `
                -Detail $desc -Advice 'One module gives half the memory bandwidth. A second identical module (in the slot the motherboard manual names for dual-channel) helps with sample-heavy projects.' -GuideId 'bios'
        }
    }

    $withSpeed = @($mods | Where-Object { $_.ConfiguredClockSpeed -gt 0 })
    if (-not $withSpeed) { return }
    $configured = [int](($withSpeed | Measure-Object ConfiguredClockSpeed -Minimum).Minimum)
    $rated = [int](($mods | Where-Object { $_.Speed -gt 0 } | Measure-Object Speed -Minimum).Minimum)
    $jedecDefault = (-not $IsLaptop) -and (($type -eq 26 -and $configured -le 2400) -or ($type -eq 34 -and $configured -le 4800))
    $ratedText = if ($rated -gt $configured) { " (modules report $rated MT/s)" } else { '' }
    if ($jedecDefault) {
        New-RTFinding -Id 'mem.xmp' -Severity Info -Category 'Hardware' -Title "$typeName memory runs at $configured MT/s, the JEDEC default$ratedText" `
            -Detail $desc -Advice "If the kit is rated higher (see its label or product page; Windows usually only sees the JEDEC speed), enable XMP/EXPO in the BIOS. Run a stability test afterwards and turn it off again if the system becomes unstable." -GuideId 'bios'
    } elseif ($rated -gt $configured) {
        $adv = if ($IsLaptop) { 'Laptops often limit memory speed by design (CPU/platform limit), so this is usually not adjustable. Nothing to do unless the manufacturer specifies a higher speed for this model.' }
               else { 'Check the BIOS memory settings (XMP/EXPO profile or manual speed). Some CPUs and boards run fully populated slots slower by design; see the motherboard manual.' }
        New-RTFinding -Id 'mem.speed' -Severity Info -Category 'Hardware' -Title "RAM runs at $configured MT/s but is rated $rated MT/s" -Detail $desc -Advice $adv -GuideId 'bios'
    }
}

Register-RTDetector -Id 'memory-config' -Detect {
    param($ctx)
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    Get-RTMemoryFindings -Modules (Get-RTMemoryModules) -IsLaptop ([bool]$bat)
}

# --- Firmware / driver age -----------------------------------------------------

function Test-RTPhysicalDeviceId {
    # Real hardware enumerated on a bus; excludes ROOT\, SWD\, BTH\ and {guid}\ software devices.
    param([string]$InstanceId)
    $InstanceId -match '^(PCI|USB|SDIO|SD|ACPI|HDAUDIO)\\'
}

function Get-RTFirmwareFacts {
    $f = @{ Bios = $null; Gpus = @(); NetAdapters = @() }
    $b = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($b) { $f.Bios = [pscustomobject]@{ Version = "$($b.SMBIOSBIOSVersion)"; Manufacturer = "$($b.Manufacturer)"; ReleaseDate = $b.ReleaseDate } }
    # GPUs and network adapters in one Win32_PnPEntity query: Win32_VideoController costs ~1.7 s on its
    # first use and Win32_PnPSignedDriver even more. -Property keeps the (full-scan) query at ~0.5 s.
    $ents = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display' OR PNPClass='Net'" -Property DeviceID, Name, Present, PNPClass -ErrorAction SilentlyContinue |
        Where-Object { $_.Present -ne $false -and (Test-RTPhysicalDeviceId "$($_.DeviceID)") })
    $devs = @(foreach ($e in $ents) {
        $p = Get-RTDeviceProperties $e @('DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverProvider')
        [pscustomobject]@{
            Class          = "$($e.PNPClass)"
            Name           = "$($e.Name)"
            InstanceId     = "$($e.DeviceID)"
            DriverVersion  = "$($p['DEVPKEY_Device_DriverVersion'])"
            DriverProvider = "$($p['DEVPKEY_Device_DriverProvider'])"
            DriverDate     = $(if ($p['DEVPKEY_Device_DriverDate']) { [datetime]$p['DEVPKEY_Device_DriverDate'] } else { $null })
        }
    })
    $f.Gpus = @($devs | Where-Object { $_.Class -eq 'Display' })
    $f.NetAdapters = @($devs | Where-Object { $_.Class -eq 'Net' })
    $f
}

function Get-RTFirmwareFindings {
    <#
      Pure: Facts = @{ Bios = {Version, Manufacturer, ReleaseDate}; Gpus/NetAdapters = {Name, InstanceId, DriverVersion, DriverProvider, DriverDate} }.
      Now is injectable for tests.
    #>
    param([Parameter(Mandatory)][hashtable]$Facts, [datetime]$Now = (Get-Date))
    $bios = $Facts['Bios']
    if ($bios -and $bios.ReleaseDate -and [datetime]$bios.ReleaseDate -lt $Now.AddYears(-3)) {
        New-RTFinding -Id 'fw.bios' -Severity Info -Category 'System' -Title "BIOS from $(([datetime]$bios.ReleaseDate).ToString('yyyy-MM'))" `
            -Detail ("$($bios.Manufacturer) $($bios.Version)".Trim()) `
            -Advice 'Check the PC or motherboard manufacturer for BIOS updates; they often fix DPC latency, USB and power management issues. Update only from the official support page and on AC power.' -GuideId 'bios'
    }
    foreach ($g in @($Facts['Gpus'] | Where-Object { $_ })) {
        # A Microsoft driver on a physical GPU is the Basic Display Adapter fallback: the vendor driver is missing.
        if ($g.DriverProvider -match '^Microsoft') {
            New-RTFinding -Id "fw.gpu.basic.$($g.Name)" -Severity Info -Category 'System' -Title "$($g.Name) runs on the Windows fallback display driver" `
                -Detail ("$($g.DriverProvider) $($g.DriverVersion)".Trim()) -Advice 'Install the graphics driver from NVIDIA/AMD/Intel or the PC manufacturer; the fallback driver uses the CPU for drawing and can cause latency spikes.' -GuideId 'gpu'
            continue
        }
        if ($g.DriverDate -and [datetime]$g.DriverDate -lt $Now.AddMonths(-18)) {
            New-RTFinding -Id "fw.gpu.$($g.Name)" -Severity Info -Category 'System' -Title "Graphics driver for $($g.Name) is from $(([datetime]$g.DriverDate).ToString('yyyy-MM'))" `
                -Detail "Version $($g.DriverVersion)" -Advice 'Install a current driver from NVIDIA/AMD/Intel or the laptop manufacturer. Graphics drivers are a common source of DPC spikes (e.g. nvlddmkm.sys).' -GuideId 'gpu'
        }
    }
    foreach ($n in @($Facts['NetAdapters'] | Where-Object { $_ })) {
        # Microsoft inbox drivers carry a fixed old date (often 2006-06-21); their age says nothing.
        if ($n.DriverProvider -match '^Microsoft') { continue }
        if ($n.DriverDate -and [datetime]$n.DriverDate -lt $Now.AddYears(-3)) {
            New-RTFinding -Id "fw.net.$($n.Name)" -Severity Info -Category 'System' -Title "Network driver for $($n.Name) is from $(([datetime]$n.DriverDate).ToString('yyyy-MM'))" `
                -Detail ("$($n.DriverProvider) $($n.DriverVersion)".Trim()) `
                -Advice 'Wi-Fi and LAN drivers are frequent DPC latency culprits (ndis.sys, wdiwifi.sys). Get a current driver from the chipset maker (Intel, Realtek, Killer/Qualcomm, MediaTek) or the PC manufacturer. If LatencyMon points at the network, disable the adapter while recording.' -GuideId 'latencymon'
        }
    }
}

Register-RTDetector -Id 'firmware-age' -Detect {
    param($ctx)
    Get-RTFirmwareFindings -Facts (Get-RTFirmwareFacts)
}
