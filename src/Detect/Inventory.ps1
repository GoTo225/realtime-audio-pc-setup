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
$script:GenericAsioPattern = 'ASIO4ALL|FL Studio ASIO|Generic Low Latency|built-in ASIO|Realtek ASIO|FlexASIO|ASIO2WASAPI|Voicemeeter'

# Per vendor: device names (for interfaces found by name, e.g. Thunderbolt/PCIe without a USB VID)
# and the names its ASIO drivers register under HKLM\SOFTWARE\ASIO. Driver names are product
# names set by the vendor, not localized text.
$script:VendorProfiles = [ordered]@{
    'Focusrite'          = @{ Device = 'Focusrite|Scarlett|Clarett|Saffire|Vocaster'; Asio = 'Focusrite' }
    'Yamaha / Steinberg' = @{ Device = 'Steinberg|Yamaha|\bUR\d{2}|\bUR-[A-Z]|\bIXO'; Asio = 'Steinberg|Yamaha' }
    'Behringer'          = @{ Device = 'Behringer|\bUMC\d+|\bUPHORIA'; Asio = 'Behringer|\bUMC' }
    'Native Instruments' = @{ Device = 'Native Instruments|Komplete Audio|Traktor Audio'; Asio = 'Native Instruments|Komplete|Traktor' }
    'Roland'             = @{ Device = 'Roland|Rubix|\bBOSS\b'; Asio = 'Roland|Rubix|\bBOSS\b' }
    'MOTU'               = @{ Device = 'MOTU'; Asio = 'MOTU' }
    'PreSonus'           = @{ Device = 'PreSonus|AudioBox|Studio ?\d{2,4}c?|Quantum'; Asio = 'PreSonus|AudioBox|\bStudio\b|Quantum' }
    'Audient'            = @{ Device = 'Audient|\biD\d{1,2}\b|\bEVO\b'; Asio = 'Audient|\bEVO\b' }
    'Arturia'            = @{ Device = 'Arturia|MiniFuse|AudioFuse'; Asio = 'Arturia|MiniFuse|AudioFuse' }
    'Zoom'               = @{ Device = '\bZOOM\b'; Asio = '\bZOOM\b' }
    'TASCAM'             = @{ Device = 'TASCAM|\bUS-\d'; Asio = 'TASCAM|\bUS-\d' }
    'M-Audio'            = @{ Device = 'M-Audio|\bAIR \d'; Asio = 'M-Audio|\bAIR\b' }
    'Line 6'             = @{ Device = 'Line ?6|\bPOD\b|\bHelix\b|\bHX '; Asio = 'Line ?6' }
    'RME'                = @{ Device = '\bRME\b|Fireface|Babyface|MADIface|Digiface|Hammerfall|HDSP|\bUFX'; Asio = '\bRME\b|Fireface|Babyface|MADIface|Digiface|Hammerfall|HDSP|\bUFX' }
    'Universal Audio'    = @{ Device = 'Universal Audio|Apollo|UA Volt|\bUAD\b'; Asio = 'Universal Audio|\bUAD\b|Apollo|Volt' }
    'Solid State Logic'  = @{ Device = 'Solid State Logic|\bSSL ?\d'; Asio = 'Solid State Logic|\bSSL\b' }
    'Elektron'           = @{ Device = 'Elektron|Overbridge'; Asio = 'Elektron|Overbridge' }
    'Apogee'             = @{ Device = 'Apogee'; Asio = 'Apogee' }
    'Antelope'           = @{ Device = 'Antelope'; Asio = 'Antelope' }
}

function Get-RTInterfaceVendor {
    # Known vendor (a VendorProfiles key) from the USB vendor ID, else from the device name; '' if unknown.
    param([string]$Name, [string]$InstanceId)
    if ($InstanceId -match 'VID_([0-9A-F]{4})' -and $script:InterfaceVendors.Contains($Matches[1].ToUpper())) { return $script:InterfaceVendors[$Matches[1].ToUpper()] }
    foreach ($v in $script:VendorProfiles.Keys) { if ($Name -match $script:VendorProfiles[$v].Device) { return $v } }
    ''
}

function Get-RTVendorOfAsio {
    # Vendor (a VendorProfiles key) whose ASIO naming matches this driver; '' if none.
    param([string]$Name)
    foreach ($v in $script:VendorProfiles.Keys) { if ($Name -match $script:VendorProfiles[$v].Asio) { return $v } }
    ''
}

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
        $known = Get-RTInterfaceVendor -Name $d.Name -InstanceId $d.DeviceID
        $vendor = if ($known) { $known } elseif ($d.Manufacturer) { "$($d.Manufacturer)" } else { '' }
        [pscustomobject]@{
            Name           = $d.Name
            InstanceId     = $d.DeviceID
            Type           = Get-RTAudioDeviceType -Name $d.Name -InstanceId $d.DeviceID
            Vendor         = $vendor
            KnownVendor    = $known
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
    # Uses the cached USB topology (Usb.ps1), which recognises USB 2 and USB 3 hubs (Class_09,
    # USB30_HUB/USB20_HUB, usbhub/usbhub3); root hubs are counted separately and not included.
    param([string]$InstanceId)
    @(Get-RTUsbDeviceChain -InstanceId $InstanceId | Where-Object { $_.Kind -eq 'Hub' }).Count
}

function Get-RTAsioDrivers {
    <#
      ASIO drivers from both registry views. 64-bit DAWs only see HKLM\SOFTWARE\ASIO, 32-bit hosts only
      the WOW6432Node view. Each entry points via its CLSID to a COM DLL; a missing DLL is a leftover
      of an uninstalled driver.
    #>
    $views = @(
        @{ Bits = 64; Asio = 'HKLM:\SOFTWARE\ASIO'; Clsid = 'HKLM:\SOFTWARE\Classes\CLSID' },
        @{ Bits = 32; Asio = 'HKLM:\SOFTWARE\WOW6432Node\ASIO'; Clsid = 'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID' }
    )
    $byName = [ordered]@{}
    foreach ($v in $views) {
        if (-not (Test-Path $v.Asio)) { continue }
        foreach ($k in Get-ChildItem $v.Asio -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            $clsid = if ($p -and $p.PSObject.Properties['CLSID']) { "$($p.CLSID)" } else { '' }
            $dll = ''
            if ($clsid) {
                $srv = Get-ItemProperty "$($v.Clsid)\$clsid\InprocServer32" -ErrorAction SilentlyContinue
                if ($srv -and $srv.PSObject.Properties['(default)']) { $dll = [Environment]::ExpandEnvironmentVariables("$($srv.'(default)')".Trim('"')) }
            }
            $name = $k.PSChildName
            if (-not $byName.Contains($name)) { $byName[$name] = @{ Name = $name; Views = @{} } }
            $byName[$name].Views[$v.Bits] = @{ Clsid = $clsid; Dll = $dll; DllExists = [bool]($dll -and (Test-Path -LiteralPath $dll)) }
        }
    }
    @(foreach ($e in $byName.Values) { New-RTAsioDriver -Name $e.Name -Views $e.Views })
}

function New-RTAsioDriver {
    # Views: @{ 64 = @{ Dll; DllExists }; 32 = @{ ... } } (either may be missing)
    param([string]$Name, [hashtable]$Views)
    $broken = @($Views.Keys | Where-Object { -not $Views[$_].DllExists } | Sort-Object -Descending | ForEach-Object { "$_-bit" })
    [pscustomobject]@{
        Name    = $Name
        Generic = ($Name -match $script:GenericAsioPattern)
        Vendor  = $(if ($Name -match $script:GenericAsioPattern) { '' } else { Get-RTVendorOfAsio $Name })
        Has64   = $Views.ContainsKey(64) -and $Views[64].DllExists
        Has32   = $Views.ContainsKey(32) -and $Views[32].DllExists
        Broken  = $broken                                   # registry views whose DLL is missing
        Dlls    = @($Views.Keys | Sort-Object -Descending | ForEach-Object { "$($_)-bit: $(if ($Views[$_].Dll) { $Views[$_].Dll } else { '(no DLL registered)' })" })
    }
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
