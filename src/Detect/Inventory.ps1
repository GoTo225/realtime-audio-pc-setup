# Hardware / software inventory used by checks, tweak providers and the guide.
# Everything here must work on any Windows display language: match on IDs, never on localized text.

$script:InterfaceVendors = [ordered]@{
    '1235' = 'Focusrite';         '0499' = 'Yamaha / Steinberg'; '1397' = 'Behringer';     '17CC' = 'Native Instruments'
    '0582' = 'Roland';            '07FD' = 'MOTU';               '194F' = 'PreSonus';      '2708' = 'Audient'
    '1C75' = 'Arturia';           '1686' = 'Zoom';               '0644' = 'TASCAM';        '0763' = 'M-Audio'
    '0E41' = 'Line 6';            '2A39' = 'RME';                '2B5A' = 'Universal Audio'; '31E9' = 'Solid State Logic'
    '1935' = 'Elektron'
}
$script:InterfaceNamePattern = '\b(Focusrite|Scarlett|Clarett|Steinberg|UR\d{2}|Yamaha|RME|Fireface|Babyface|Universal Audio|Apollo|UA Volt|MOTU|PreSonus|Studio ?\d{2,4}c?|Behringer|UMC\d+|Komplete Audio|Audient|Arturia|MiniFuse|AudioFuse|Solid State Logic|SSL ?\d|Rubix|TASCAM|M-Audio|Apogee|Antelope|Line 6|Audio ?Interface)\b'
$script:GenericAsioPattern = 'ASIO4ALL|FL Studio ASIO|Generic Low Latency|Realtek ASIO|FlexASIO|ASIO2WASAPI|Voicemeeter'

function Get-RTAudioDeviceType {
    param([string]$Name, [string]$InstanceId)
    $id = $InstanceId.ToUpper()
    if ($id -match '^(SW|ROOT)\\') { return 'Virtual' }
    if ($id -match '^BTHENUM\\|^BTHHFENUM\\|^BTHLEDEVICE\\') { return 'Bluetooth' }
    if ($id -match 'VID_([0-9A-F]{4})' -and $script:InterfaceVendors.Contains($Matches[1])) { return 'Interface' }
    if ($Name -match $script:InterfaceNamePattern) { return 'Interface' }
    if ($id -match 'CTLR_DEV|LINKTYPE_') { return 'Controller' }      # Intel Smart Sound controller: hosts other codecs, never disable
    if ($id -match 'VEN_10DE|VEN_1002|VEN_8086&DEV_28' -or $Name -match 'Display Audio|HDMI|DisplayPort') { return 'Display' }
    if ($id -match '^(HDAUDIO|INTELAUDIO)\\') { return 'Onboard' }
    if ($id -match '^USB\\') { return 'UsbOther' }
    'Other'
}

# Get-PnpDevice / Get-PnpDeviceProperty cost seconds per call; one Win32_PnPEntity enumeration plus
# GetDeviceProperties on the returned instances is ~50x faster.
function Get-RTMediaEntities {
    @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='MEDIA'" -ErrorAction SilentlyContinue | Where-Object { $_.Present -ne $false })
}

function Get-RTDeviceProperties {
    param([Parameter(Mandatory)]$Entity, [string[]]$Keys)
    $h = @{}
    try {
        $r = Invoke-CimMethod -InputObject $Entity -MethodName GetDeviceProperties -Arguments @{ devicePropertyKeys = $Keys } -ErrorAction Stop
        foreach ($p in $r.deviceProperties) { if ($p.PSObject.Properties['Data']) { $h[$p.KeyName] = $p.Data } }
    } catch { }
    $h
}

function Test-RTDeviceDisabled { param($Entity) "$($Entity.ConfigManagerErrorCode)" -match 'DISABLED|^22$' }

function Get-RTAudioDevices {
    foreach ($d in Get-RTMediaEntities) {
        $props = Get-RTDeviceProperties $d @('DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate')
        $vendor = ''
        if ($d.DeviceID -match 'VID_([0-9A-F]{4})' -and $script:InterfaceVendors.Contains($Matches[1].ToUpper())) { $vendor = $script:InterfaceVendors[$Matches[1].ToUpper()] }
        elseif ($d.Manufacturer) { $vendor = $d.Manufacturer }
        [pscustomobject]@{
            Name           = $d.Name
            InstanceId     = $d.DeviceID
            Type           = Get-RTAudioDeviceType -Name $d.Name -InstanceId $d.DeviceID
            Vendor         = $vendor
            Enabled        = -not (Test-RTDeviceDisabled $d)
            Status         = "$($d.Status)"
            DriverProvider = "$($props['DEVPKEY_Device_DriverProvider'])"
            DriverVersion  = "$($props['DEVPKEY_Device_DriverVersion'])"
            DriverDate     = $(if ($props['DEVPKEY_Device_DriverDate']) { [datetime]$props['DEVPKEY_Device_DriverDate'] } else { $null })
            Service        = "$($d.Service)"
        }
    }
}

function Get-RTUsbHubDepth {
    # Number of external (non-root) USB hubs between the device and the host controller.
    # Hubs are recognised by their USB class code (09), which is language independent.
    param([string]$InstanceId)
    $byId = @{}
    Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE 'USB%'" -ErrorAction SilentlyContinue | ForEach-Object { $byId[$_.DeviceID.ToUpper()] = $_ }
    $depth = 0; $cur = $byId[$InstanceId.ToUpper()]
    for ($i = 0; $cur -and $i -lt 10; $i++) {
        $parentId = "$((Get-RTDeviceProperties $cur @('DEVPKEY_Device_Parent'))['DEVPKEY_Device_Parent'])"
        if ($parentId -notmatch '^USB\\') { break }
        $cur = $byId[$parentId.ToUpper()]
        if ($cur -and $parentId -notmatch '^USB\\ROOT_HUB' -and @($cur.CompatibleID) -match 'USB\\Class_09') { $depth++ }
    }
    $depth
}

function Get-RTAsioDrivers {
    $names = foreach ($k in 'HKLM:\SOFTWARE\ASIO', 'HKLM:\SOFTWARE\WOW6432Node\ASIO') {
        if (Test-Path $k) { Get-ChildItem $k | ForEach-Object { $_.PSChildName } }
    }
    @($names | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ Name = $_; Generic = ($_ -match $script:GenericAsioPattern) }
    })
}

$script:DawPatterns = [ordered]@{
    'FL Studio'     = '^FL Studio'
    'Cubase'        = '^(Steinberg )?Cubase'
    'Nuendo'        = '^(Steinberg )?Nuendo'
    'Ableton Live'  = '^Ableton Live'
    'REAPER'        = '^REAPER'
    'Bitwig Studio' = '^Bitwig Studio'
    'Studio One'    = 'Studio One'
    'Pro Tools'     = '^(Avid )?Pro Tools'
}

function Get-RTInstalledDaws {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $apps = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName })
    foreach ($daw in $script:DawPatterns.Keys) {
        $hit = $apps | Where-Object { $_.DisplayName -match $script:DawPatterns[$daw] } | Select-Object -First 1
        if ($hit) {
            [pscustomobject]@{
                Name            = $daw
                DisplayName     = $hit.DisplayName
                Version         = $(if ($hit.PSObject.Properties['DisplayVersion']) { $hit.DisplayVersion } else { '' })
                InstallLocation = $(if ($hit.PSObject.Properties['InstallLocation']) { "$($hit.InstallLocation)".Trim('"') } else { '' })
            }
        }
    }
}

function Get-RTLatencySample {
    <#
      Samples per-core DPC/interrupt time and CPU performance once per second.
      Uses the WMI perf classes because Get-Counter counter paths are localized.
    #>
    param([int]$Seconds = 20)
    $cores = @{}; $perf = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt [Math]::Max(1, $Seconds); $i++) {
        $tick = [Diagnostics.Stopwatch]::StartNew()
        foreach ($p in Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue) {
            if ($p.Name -eq '_Total') { continue }
            if (-not $cores.ContainsKey($p.Name)) { $cores[$p.Name] = @{ Dpc = New-Object System.Collections.ArrayList; Isr = New-Object System.Collections.ArrayList } }
            [void]$cores[$p.Name].Dpc.Add([double]$p.PercentDPCTime)
            [void]$cores[$p.Name].Isr.Add([double]$p.PercentInterruptTime)
        }
        $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        if ($pi) { [void]$perf.Add([double]$pi.PercentProcessorPerformance) }
        if ($i -lt $Seconds - 1) { Start-Sleep -Milliseconds ([Math]::Max(0, 1000 - $tick.ElapsedMilliseconds)) }
    }
    $perCore = foreach ($k in $cores.Keys) {
        $dpc = $cores[$k].Dpc | Measure-Object -Average -Maximum
        $isr = $cores[$k].Isr | Measure-Object -Average -Maximum
        [pscustomobject]@{ Core = [int]$k; DpcAvg = [math]::Round($dpc.Average, 2); DpcMax = $dpc.Maximum; IsrAvg = [math]::Round($isr.Average, 2); IsrMax = $isr.Maximum }
    }
    $perfStats = $perf | Measure-Object -Average -Minimum
    [pscustomobject]@{
        Seconds      = $Seconds
        Cores        = @($perCore | Sort-Object Core)
        PerfAvg      = $(if ($perf.Count) { [math]::Round($perfStats.Average, 0) } else { $null })
        PerfMin      = $(if ($perf.Count) { $perfStats.Minimum } else { $null })
    }
}
