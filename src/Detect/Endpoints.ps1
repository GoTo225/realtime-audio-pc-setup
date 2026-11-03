# Read-only checks of the Windows audio endpoints (what the Sound control panel shows as playback and
# recording devices). Data comes from HKLM:\...\MMDevices\Audio, which every user can read; all logic
# uses property keys (fmtid,pid), never localized names. Names only appear in finding texts.
#
# Endpoint key:   DeviceState (DWORD, low nibble 1 = active, 2 = disabled, 4 = not present, 8 = unplugged)
# Properties:     {a45c254e-df1c-4efd-8020-67d146a850e0},2  PKEY_Device_FriendlyName part: endpoint name ('Speakers')
#                 {b3f8fa53-0004-438e-9003-51a46e139bfc},6  adapter/device name
#                 {b3f8fa53-0004-438e-9003-51a46e139bfc},2  '{1}.' + PnP instance id of the device
#                 {f19f064d-082c-4e27-bc73-6882a1bb8e4c},0  PKEY_AudioEngine_DeviceFormat (shared-mode format)
#                 {b3f8fa53-0004-438e-9003-51a46e139bfc},3  'Allow applications to take exclusive control' (absent = default = on)
# FxProperties:   {1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5  PKEY_AudioEndpoint_Disable_SysFx (1 = enhancements off)
#                 {d04e05a6-594b-4fb6-a80d-01af5eed7d1d},n  PKEY_FX_*EffectClsid: the APOs (enhancements) of the endpoint

$script:MMDevicesRoot   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$script:PkeyEndpointName = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$script:PkeyDeviceName   = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
$script:PkeyDeviceId     = '{b3f8fa53-0004-438e-9003-51a46e139bfc},2'
$script:PkeyExclusive    = '{b3f8fa53-0004-438e-9003-51a46e139bfc},3'
$script:PkeyDeviceFormat = '{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0'
$script:PkeyDisableSysFx = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'
$script:PkeyFxPrefix     = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},'
# Endpoint id prefixes used by the MMDevice API ('{0.0.<flow>.00000000}.{guid}').
$script:EndpointIdPrefix = @{ Render = '{0.0.0.00000000}.'; Capture = '{0.0.1.00000000}.' }
$script:CommonRates      = @(44100, 48000, 88200, 96000)

function ConvertFrom-RTWaveFormat {
    <#
      Parses a WAVEFORMATEX / WAVEFORMATEXTENSIBLE, optionally preceded by the 8-byte header Windows
      stores in the registry (VT_BLOB = 0x41 as the first word). Returns SampleRate, Channels,
      BitsPerSample (container), ValidBits, Float; $null if the bytes do not look like a wave format.
    #>
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { return $null }
    $b = $Bytes
    $off = 0
    if ($b.Length -ge 26 -and [BitConverter]::ToUInt16($b, 0) -eq 0x41) { $off = 8 }
    if ($b.Length -lt $off + 16) { return $null }
    $tag      = [BitConverter]::ToUInt16($b, $off)
    $channels = [BitConverter]::ToUInt16($b, $off + 2)
    $rate     = [BitConverter]::ToUInt32($b, $off + 4)
    $bits     = [BitConverter]::ToUInt16($b, $off + 14)
    if (@(1, 3, 0xFFFE) -notcontains $tag) { return $null }
    if ($channels -lt 1 -or $channels -gt 64 -or $rate -lt 1000 -or $rate -gt 1536000 -or $bits -lt 8 -or $bits -gt 64) { return $null }
    $valid = [int]$bits
    $float = ($tag -eq 3)
    if ($tag -eq 0xFFFE) {
        # cbSize (>= 22), wValidBitsPerSample, dwChannelMask, SubFormat GUID
        if ($b.Length -lt $off + 40) { return $null }
        $v = [BitConverter]::ToUInt16($b, $off + 18)
        if ($v -gt 0 -and $v -le $bits) { $valid = [int]$v }
        $sub = New-Object Guid (, [byte[]]$b[($off + 24)..($off + 39)])
        $float = ($sub -eq [Guid]'00000003-0000-0010-8000-00aa00389b71')
    }
    [pscustomobject]@{ SampleRate = [int]$rate; Channels = [int]$channels; BitsPerSample = [int]$bits; ValidBits = $valid; Float = [bool]$float }
}

function Format-RTSampleRate {
    param([int]$Rate)
    (($Rate / 1000.0).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)) + ' kHz'
}

function Format-RTWaveFormat {
    param($Format)
    if (-not $Format) { return 'unknown format' }
    $depth = if ($Format.Float) { "$($Format.BitsPerSample)-bit float" } else { "$($Format.ValidBits)-bit" }
    "$(Format-RTSampleRate $Format.SampleRate) / $depth"
}

function New-RTEndpoint {
    # One audio endpoint as a plain object (used by the collector and by tests).
    param(
        [string]$Guid, [ValidateSet('Render', 'Capture')][string]$Flow = 'Render', [string]$Name = '', [string]$DeviceName = '',
        [string]$DeviceInstanceId = '', [int]$State = 1, $Format = $null,
        [bool]$HasFx = $false, [bool]$SysFxDisabled = $false, $ExclusiveAllowed = $null
    )
    [pscustomobject]@{
        Id               = $script:EndpointIdPrefix[$Flow] + $Guid
        Guid             = $Guid
        Flow             = $Flow
        Name             = $Name
        DeviceName       = $DeviceName
        DisplayName      = $(if ($DeviceName) { "$Name ($DeviceName)" } else { $Name })
        DeviceInstanceId = $DeviceInstanceId
        State            = $State
        Active           = ($State -eq 1)
        Format           = $Format
        HasFx            = $HasFx              # endpoint has enhancement APOs registered
        SysFxDisabled    = $SysFxDisabled      # 'Audio enhancements: Off'
        ExclusiveAllowed = $ExclusiveAllowed   # $null = not set (Windows default: allowed)
    }
}

function Get-RTEndpoints {
    # Collector: all endpoints from the registry. Read-only, no admin needed.
    foreach ($flow in 'Render', 'Capture') {
        $root = Join-Path $script:MMDevicesRoot $flow
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            try {
                $state = $k.GetValue('DeviceState', $null)
                if ($null -eq $state) { continue }
                $props = $null; $fx = $null
                try { $props = $k.OpenSubKey('Properties') } catch { }
                try { $fx = $k.OpenSubKey('FxProperties') } catch { }
                $get = { param($key, $name) if ($key) { , $key.GetValue($name, $null) } else { $null } }   # comma: keep byte[] whole

                $instance = "$(& $get $props $script:PkeyDeviceId)"
                if ($instance -match '^\{\d+\}\.(.+)$') { $instance = $Matches[1] }
                $fmtBytes = & $get $props $script:PkeyDeviceFormat
                $format = if ($fmtBytes -is [byte[]]) { ConvertFrom-RTWaveFormat -Bytes $fmtBytes } else { $null }
                $excl = & $get $props $script:PkeyExclusive
                $hasFx = $false
                if ($fx) {
                    foreach ($n in $fx.GetValueNames()) {
                        if (-not $n.StartsWith($script:PkeyFxPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                        $clsids = @($fx.GetValue($n, $null)) | Where-Object { "$_" -match '^\{[0-9a-fA-F-]{36}\}$' -and "$_" -ne '{00000000-0000-0000-0000-000000000000}' }
                        if ($clsids) { $hasFx = $true; break }
                    }
                }
                $sysFxOff = (& $get $fx $script:PkeyDisableSysFx)
                New-RTEndpoint -Guid $k.PSChildName -Flow $flow -Name "$(& $get $props $script:PkeyEndpointName)" -DeviceName "$(& $get $props $script:PkeyDeviceName)" `
                    -DeviceInstanceId $instance -State ([int]([int64]$state -band 0xF)) -Format $format -HasFx $hasFx `
                    -SysFxDisabled ($null -ne $sysFxOff -and ([int64]$sysFxOff -band 1) -eq 1) `
                    -ExclusiveAllowed $(if ($null -ne $excl -and $excl -isnot [byte[]]) { [bool]([int64]$excl) } else { $null })
                if ($props) { $props.Close() }
                if ($fx) { $fx.Close() }
            } catch { Write-RTLog "Endpoint $($k.PSChildName): $_" }
        }
    }
}

function Get-RTDefaultEndpointId {
    <#
      Id of the Windows default endpoint ('{0.0.0.00000000}.{guid}') via IMMDeviceEnumerator, '' on failure.
      The registry 'Role:n' timestamps are not written on every system, so the COM API is the reliable source.
      Role: 0 = console (what Settings calls the default device), 1 = multimedia, 2 = communications.
    #>
    param([ValidateSet('Render', 'Capture')][string]$Flow = 'Render', [int]$Role = 0)
    try {
        if (-not ('RTAudio.EndpointDefaults' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RTAudio {
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }
    public static class EndpointDefaults {
        public static string Get(int dataFlow, int role) {
            IMMDeviceEnumerator e = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            try {
                IMMDevice d;
                if (e.GetDefaultAudioEndpoint(dataFlow, role, out d) != 0 || d == null) return "";
                string id;
                int hr = d.GetId(out id);
                Marshal.ReleaseComObject(d);
                return hr == 0 && id != null ? id : "";
            } finally { Marshal.ReleaseComObject(e); }
        }
    }
}
'@
        }
        [RTAudio.EndpointDefaults]::Get($(if ($Flow -eq 'Render') { 0 } else { 1 }), $Role)
    } catch { Write-RTLog "Default endpoint: $_"; '' }
}

function Get-RTInterfaceEndpoints {
    <#
      Pure: endpoints that belong to one interface. Matches the endpoint's PnP instance id to the
      device's (case-insensitive); if nothing matches exactly, falls back to the same USB VID/PID
      (some drivers expose endpoints on a sibling interface of the composite device).
    #>
    param([object[]]$Endpoints, $Interface)
    $id = "$($Interface.InstanceId)"
    if (-not $id) { return @() }
    $hit = @($Endpoints | Where-Object { $_ -and $_.DeviceInstanceId -and $_.DeviceInstanceId -eq $id })
    if (-not $hit -and $id -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
        $vp = "VID_$($Matches[1])&PID_$($Matches[2])"
        $hit = @($Endpoints | Where-Object { $_ -and $_.DeviceInstanceId -match "^USB\\$([regex]::Escape($vp))(&|\\)" })
    }
    $hit
}

function Get-RTEndpointFindings {
    <#
      Pure: findings from endpoint objects (New-RTEndpoint), the interfaces (Get-RTAudioDevices objects
      of Type 'Interface') and the default playback endpoint id ('' = unknown).
    #>
    param([object[]]$Endpoints, [object[]]$Interfaces, [string]$DefaultRenderId = '')
    $cat = 'Windows audio'; $guide = 'windows-audio'
    $active = @($Endpoints | Where-Object { $_ -and $_.Active })
    $Interfaces = @($Interfaces | Where-Object { $_ -and $_.Enabled })
    $default = if ($DefaultRenderId) { @($active | Where-Object { $_.Id -eq $DefaultRenderId }) | Select-Object -First 1 } else { $null }

    $allIfaceEndpoints = @()
    $enhCandidates = @()
    foreach ($i in $Interfaces) {
        $eps = @(Get-RTInterfaceEndpoints -Endpoints $active -Interface $i)
        if (-not $eps) { continue }
        $allIfaceEndpoints += $eps
        $enhCandidates += $eps

        foreach ($e in $eps) {
            $dir = if ($e.Flow -eq 'Render') { 'playback' } else { 'recording' }
            if (-not $e.Format) { continue }
            New-RTFinding -Id "endpoints.format.$($e.Guid)" -Severity Info -Category $cat -Title "Windows runs $($e.DisplayName) at $(Format-RTWaveFormat $e.Format) ($dir)" `
                -Advice 'Set your DAW project to the same sample rate, so Windows and the DAW do not fight over the clock.' -GuideId $guide
            if ($script:CommonRates -notcontains $e.Format.SampleRate) {
                New-RTFinding -Id "endpoints.oddrate.$($e.Guid)" -Severity Info -Category $cat -Title "$($e.DisplayName) runs at an unusual sample rate: $(Format-RTSampleRate $e.Format.SampleRate)" `
                    -Advice 'Music is normally made at 44.1 or 48 kHz (88.2/96 kHz for high-rate projects). Set the default format in the Sound control panel (Advanced tab) to the rate you work in.' -GuideId $guide
            }
        }

        $rated = @($eps | Where-Object { $_.Format })
        $render = @($rated | Where-Object { $_.Flow -eq 'Render' } | ForEach-Object { $_.Format.SampleRate } | Sort-Object -Unique)
        $capture = @($rated | Where-Object { $_.Flow -eq 'Capture' } | ForEach-Object { $_.Format.SampleRate } | Sort-Object -Unique)
        if ($render -and $capture -and @($render + $capture | Sort-Object -Unique).Count -gt 1) {
            $detail = ($rated | ForEach-Object { "$($_.DisplayName): $(Format-RTSampleRate $_.Format.SampleRate)" }) -join '; '
            New-RTFinding -Id "endpoints.ratemismatch.$($i.Name)" -Severity Warning -Category $cat -Title "$($i.Name): playback and recording run at different sample rates in Windows" `
                -Detail $detail -Advice 'Most interfaces run one clock for inputs and outputs. Set the same rate for the playback and the recording device (Sound control panel > Properties > Advanced), matching your DAW.' -GuideId $guide
        }
    }

    # Enhancements: on the interface endpoints, or on the default playback device when there is no interface.
    if (-not $allIfaceEndpoints -and $default) { $enhCandidates = @($default) }
    foreach ($e in $enhCandidates) {
        if ($e.HasFx -and -not $e.SysFxDisabled) {
            New-RTFinding -Id "endpoints.enhancements.$($e.Guid)" -Severity Warning -Category $cat -Title "Audio enhancements are on for $($e.DisplayName)" `
                -Detail 'The driver registers audio processing objects (enhancements) for this device and they are not turned off.' `
                -Advice "Settings > System > Sound > $($e.Name) > Audio enhancements: Off (Windows 10: device Properties > Enhancements > Disable all). They add latency and alter the sound." -GuideId $guide
        }
    }

    # Exclusive mode explicitly switched off on an interface endpoint (not set = Windows default = allowed).
    foreach ($e in $allIfaceEndpoints) {
        if ($null -ne $e.ExclusiveAllowed -and -not $e.ExclusiveAllowed) {
            New-RTFinding -Id "endpoints.exclusive.$($e.Guid)" -Severity Info -Category $cat -Title "Exclusive mode is disabled for $($e.DisplayName)" `
                -Advice "DAWs using WASAPI exclusive mode cannot take over this device. Fine if you use ASIO; otherwise enable 'Allow applications to take exclusive control' (Sound control panel > Properties > Advanced)." -GuideId $guide
        }
    }

    # Default playback device is not the interface.
    if ($allIfaceEndpoints -and $default -and -not @($allIfaceEndpoints | Where-Object { $_.Id -eq $default.Id })) {
        $names = (@($Interfaces | ForEach-Object Name) | Select-Object -Unique) -join ', '
        New-RTFinding -Id 'endpoints.notdefault' -Severity Info -Category $cat -Title "Windows plays sound through $($default.DisplayName), not through $names" `
            -Advice 'Fine if intentional: it keeps system sounds and browsers off the interface. To hear Windows audio through the interface, make it the default playback device.' -GuideId $guide
    }
}

Register-RTDetector -Id 'endpoints' -Detect {
    param($ctx)
    $endpoints = @(Get-RTEndpoints)
    if (-not $endpoints) { return }
    $interfaces = if ($ctx -is [hashtable] -and $ctx.ContainsKey('AudioDevices')) { @($ctx['AudioDevices'] | Where-Object { $_ -and $_.Type -eq 'Interface' }) } else { @() }
    Get-RTEndpointFindings -Endpoints $endpoints -Interfaces $interfaces -DefaultRenderId (Get-RTDefaultEndpointId -Flow Render -Role 0)
}
