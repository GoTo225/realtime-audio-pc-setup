# Pester 3.4 compatible. Run: Invoke-Pester .\tests\Endpoints.Tests.ps1
# Pure tests with fake endpoint data; nothing here reads or changes system settings.

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Engine.psm1') -Force -DisableNameChecking

InModuleScope Engine {
    function HexBytes([string]$Hex) { [byte[]]@($Hex -split ' ' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) }) }

    # Registry value as stored by Windows (8-byte blob header + WAVEFORMATEXTENSIBLE).
    $regExt24 = '41 00 00 00 01 00 00 00 fe ff 02 00 80 bb 00 00 00 dc 05 00 08 00 20 00 16 00 18 00 03 00 00 00 01 00 00 00 00 00 10 00 80 00 00 aa 00 38 9b 71'
    $regExt16 = '41 00 00 00 01 00 00 00 fe ff 02 00 80 bb 00 00 00 ee 02 00 04 00 10 00 16 00 10 00 03 00 00 00 01 00 00 00 00 00 10 00 80 00 00 aa 00 38 9b 71'

    Describe 'ConvertFrom-RTWaveFormat' {
        It 'parses the registry blob with WAVEFORMATEXTENSIBLE (48 kHz, 32-bit container, 24 valid bits)' {
            $f = ConvertFrom-RTWaveFormat -Bytes (HexBytes $regExt24)
            $f.SampleRate | Should Be 48000
            $f.Channels | Should Be 2
            $f.BitsPerSample | Should Be 32
            $f.ValidBits | Should Be 24
            $f.Float | Should Be $false
        }
        It 'parses 16-bit extensible' {
            $f = ConvertFrom-RTWaveFormat -Bytes (HexBytes $regExt16)
            $f.SampleRate | Should Be 48000
            $f.ValidBits | Should Be 16
        }
        It 'parses a raw WAVEFORMATEXTENSIBLE without the registry header (44.1 kHz)' {
            $raw = (HexBytes $regExt24)[8..47]
            $raw[4] = 0x44; $raw[5] = 0xAC   # 44100
            $f = ConvertFrom-RTWaveFormat -Bytes $raw
            $f.SampleRate | Should Be 44100
            $f.ValidBits | Should Be 24
        }
        It 'recognises the IEEE float subformat' {
            $b = HexBytes $regExt24
            $b[32] = 3                       # SubFormat KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
            $b[22] = 32; $b[26] = 32         # 32-bit container, 32 valid bits
            $f = ConvertFrom-RTWaveFormat -Bytes $b
            $f.Float | Should Be $true
            Format-RTWaveFormat $f | Should Be '48 kHz / 32-bit float'
        }
        It 'parses plain WAVEFORMATEX PCM (96 kHz, 24-bit)' {
            # tag 1, 2 ch, 96000 Hz, avg 576000, align 6, 24 bits, cbSize 0
            $f = ConvertFrom-RTWaveFormat -Bytes (HexBytes '01 00 02 00 00 77 01 00 00 ca 08 00 06 00 18 00 00 00')
            $f.SampleRate | Should Be 96000
            $f.ValidBits | Should Be 24
            $f.Float | Should Be $false
        }
        It 'parses plain WAVEFORMATEX float behind the registry header' {
            $f = ConvertFrom-RTWaveFormat -Bytes (HexBytes '41 00 00 00 01 00 00 00 03 00 02 00 88 58 01 00 00 c4 0a 00 08 00 20 00 00 00')
            $f.SampleRate | Should Be 88200
            $f.Float | Should Be $true
        }
        It 'uses the container size when wValidBitsPerSample is 0' {
            $b = HexBytes $regExt24
            $b[26] = 0
            (ConvertFrom-RTWaveFormat -Bytes $b).ValidBits | Should Be 32
        }
        It 'returns null for null, short, truncated or unknown data' {
            ConvertFrom-RTWaveFormat -Bytes $null | Should Be $null
            ConvertFrom-RTWaveFormat -Bytes (HexBytes '41 00 00 00') | Should Be $null
            ConvertFrom-RTWaveFormat -Bytes (HexBytes $regExt24)[0..30] | Should Be $null
            ConvertFrom-RTWaveFormat -Bytes (HexBytes '41 00 00 00 01 00 00 00 a0 86 01 00 00 00 00 00') | Should Be $null
            ConvertFrom-RTWaveFormat -Bytes (HexBytes '41 00 00 00 01 00 00 00 55 00 02 00 80 bb 00 00 00 00 00 00 00 00 10 00 00 00') | Should Be $null
        }
    }

    Describe 'Format-RTSampleRate' {
        It 'formats with invariant decimals' {
            Format-RTSampleRate 44100 | Should Be '44.1 kHz'
            Format-RTSampleRate 48000 | Should Be '48 kHz'
            Format-RTSampleRate 22050 | Should Be '22.05 kHz'
        }
    }

    function Fmt([int]$Rate, [int]$Bits = 24) { [pscustomobject]@{ SampleRate = $Rate; Channels = 2; BitsPerSample = 32; ValidBits = $Bits; Float = $false } }

    $ifaceId = 'USB\VID_1235&PID_8210&MI_00\7&1A2B3C&0&0000'
    $iface = [pscustomobject]@{ Name = 'Focusrite USB Audio'; InstanceId = $ifaceId; Type = 'Interface'; KnownVendor = 'Focusrite'; Enabled = $true }
    $onboardId = 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0289\5&1'

    function Ep {
        param([string]$Guid, [string]$Flow = 'Render', [string]$Dev = $ifaceId, $Format = (Fmt 48000), [int]$State = 1,
              [bool]$HasFx = $false, [bool]$Off = $false, $Excl = $null, [string]$Name = 'Speakers')
        New-RTEndpoint -Guid $Guid -Flow $Flow -Name $Name -DeviceName 'Dev' -DeviceInstanceId $Dev -State $State -Format $Format -HasFx $HasFx -SysFxDisabled $Off -ExclusiveAllowed $Excl
    }

    Describe 'New-RTEndpoint' {
        It 'builds MMDevice ids per flow' {
            (Ep '{a}').Id | Should Be '{0.0.0.00000000}.{a}'
            (Ep '{b}' -Flow Capture).Id | Should Be '{0.0.1.00000000}.{b}'
        }
        It 'is active only for state 1' {
            (Ep '{a}' -State 1).Active | Should Be $true
            (Ep '{a}' -State 4).Active | Should Be $false
        }
    }

    Describe 'Get-RTInterfaceEndpoints' {
        It 'matches the instance id case-insensitively' {
            $eps = @((Ep '{a}' -Dev $ifaceId.ToLower()), (Ep '{b}' -Dev $onboardId))
            $r = @(Get-RTInterfaceEndpoints -Endpoints $eps -Interface $iface)
            $r.Count | Should Be 1
            $r[0].Guid | Should Be '{a}'
        }
        It 'falls back to the USB VID/PID when no endpoint has the exact instance id' {
            $eps = @((Ep '{a}' -Dev 'USB\VID_1235&PID_8210&MI_01\7&1A2B3C&0&0001'), (Ep '{b}' -Dev 'USB\VID_1235&PID_8211\x'))
            $r = @(Get-RTInterfaceEndpoints -Endpoints $eps -Interface $iface)
            $r.Count | Should Be 1
            $r[0].Guid | Should Be '{a}'
        }
        It 'returns nothing for an interface without instance id' {
            @(Get-RTInterfaceEndpoints -Endpoints @(Ep '{a}') -Interface ([pscustomobject]@{ InstanceId = '' })).Count | Should Be 0
        }
    }

    Describe 'Get-RTEndpointFindings' {
        $ids = { param($f) @($f | ForEach-Object Id) }

        It 'reports the shared-mode format of active interface endpoints only' {
            $eps = @((Ep '{out}'), (Ep '{in}' -Flow Capture), (Ep '{gone}' -State 4), (Ep '{rt}' -Dev $onboardId))
            $f = @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface) -DefaultRenderId '{0.0.0.00000000}.{out}')
            (& $ids $f) -join ',' | Should Be 'endpoints.format.{out},endpoints.format.{in}'
            $f[0].Severity | Should Be 'Info'
            $f[0].Title | Should Match '48 kHz / 24-bit'
            $f[0].GuideId | Should Be 'windows-audio'
            $f[0].Category | Should Be 'Windows audio'
        }
        It 'warns when playback and recording run at different rates' {
            $eps = @((Ep '{out}' -Format (Fmt 48000)), (Ep '{in}' -Flow Capture -Format (Fmt 44100)))
            $f = @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface) -DefaultRenderId '{0.0.0.00000000}.{out}')
            $w = @($f | Where-Object Id -eq 'endpoints.ratemismatch.Focusrite USB Audio')
            $w.Count | Should Be 1
            $w[0].Severity | Should Be 'Warning'
            $w[0].Detail | Should Match '44.1 kHz'
        }
        It 'does not warn about rates without a recording endpoint, or when rates agree' {
            $f = @(Get-RTEndpointFindings -Endpoints @((Ep '{out}' -Format (Fmt 96000))) -Interfaces @($iface))
            @($f | Where-Object { $_.Id -like 'endpoints.ratemismatch*' }).Count | Should Be 0
            $f = @(Get-RTEndpointFindings -Endpoints @((Ep '{out}'), (Ep '{in}' -Flow Capture -Format (Fmt 48000 16))) -Interfaces @($iface))
            @($f | Where-Object { $_.Id -like 'endpoints.ratemismatch*' }).Count | Should Be 0
        }
        It 'flags unusual sample rates' {
            $f = @(Get-RTEndpointFindings -Endpoints @((Ep '{out}' -Format (Fmt 192000)), (Ep '{in}' -Flow Capture -Format (Fmt 88200))) -Interfaces @($iface))
            @($f | Where-Object { $_.Id -like 'endpoints.oddrate*' } | ForEach-Object Id) -join ',' | Should Be 'endpoints.oddrate.{out}'
        }
        It 'skips endpoints whose format is unknown' {
            $f = @(Get-RTEndpointFindings -Endpoints @((Ep '{out}' -Format $null)) -Interfaces @($iface))
            $f.Count | Should Be 0
        }
        It 'warns about enabled enhancements on interface endpoints only' {
            $eps = @((Ep '{out}' -HasFx $true), (Ep '{in}' -Flow Capture -HasFx $true -Off $true), (Ep '{rt}' -Dev $onboardId -HasFx $true))
            $f = @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface) -DefaultRenderId '{0.0.0.00000000}.{out}')
            @($f | Where-Object { $_.Id -like 'endpoints.enhancements*' } | ForEach-Object Id) -join ',' | Should Be 'endpoints.enhancements.{out}'
            @($f | Where-Object { $_.Id -like 'endpoints.enhancements*' })[0].Severity | Should Be 'Warning'
        }
        It 'checks the default playback device for enhancements when there is no interface' {
            $eps = @((Ep '{rt}' -Dev $onboardId -HasFx $true), (Ep '{hp}' -Dev $onboardId -HasFx $true -Off $true))
            (& $ids @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @() -DefaultRenderId '{0.0.0.00000000}.{rt}')) -join ',' | Should Be 'endpoints.enhancements.{rt}'
            @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @() -DefaultRenderId '{0.0.0.00000000}.{hp}').Count | Should Be 0
            @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @() -DefaultRenderId '').Count | Should Be 0
        }
        It 'does not warn about enhancements when the driver registers none' {
            @(Get-RTEndpointFindings -Endpoints @((Ep '{rt}' -Dev $onboardId)) -Interfaces @() -DefaultRenderId '{0.0.0.00000000}.{rt}').Count | Should Be 0
        }
        It 'reports when the default playback device is not the interface' {
            $eps = @((Ep '{out}'), (Ep '{rt}' -Dev $onboardId -Name 'Lautsprecher'))
            $f = @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface) -DefaultRenderId '{0.0.0.00000000}.{rt}')
            $n = @($f | Where-Object Id -eq 'endpoints.notdefault')
            $n.Count | Should Be 1
            $n[0].Severity | Should Be 'Info'
            $n[0].Title | Should Match 'Lautsprecher'
            $f = @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface) -DefaultRenderId '{0.0.0.00000000}.{out}')
            @($f | Where-Object Id -eq 'endpoints.notdefault').Count | Should Be 0
        }
        It 'does not report the default device when it is unknown or there is no interface' {
            $eps = @((Ep '{out}'), (Ep '{rt}' -Dev $onboardId))
            @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface) -DefaultRenderId '' | Where-Object Id -eq 'endpoints.notdefault').Count | Should Be 0
            @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @() -DefaultRenderId '{0.0.0.00000000}.{rt}').Count | Should Be 0
        }
        It 'ignores disabled interfaces' {
            $off = [pscustomobject]@{ Name = 'Focusrite USB Audio'; InstanceId = $ifaceId; Type = 'Interface'; KnownVendor = 'Focusrite'; Enabled = $false }
            @(Get-RTEndpointFindings -Endpoints @((Ep '{out}')) -Interfaces @($off)).Count | Should Be 0
        }
        It 'reports exclusive mode only when explicitly disabled' {
            $eps = @((Ep '{a}' -Excl $false), (Ep '{b}' -Excl $true), (Ep '{c}'))
            $f = @(Get-RTEndpointFindings -Endpoints $eps -Interfaces @($iface))
            @($f | Where-Object { $_.Id -like 'endpoints.exclusive*' } | ForEach-Object Id) -join ',' | Should Be 'endpoints.exclusive.{a}'
        }
        It 'handles empty input' {
            @(Get-RTEndpointFindings -Endpoints @() -Interfaces @()).Count | Should Be 0
        }
    }

    Describe 'Get-RTEndpoints (this machine, read-only)' {
        It 'returns endpoint objects with the expected shape' {
            foreach ($e in @(Get-RTEndpoints | Select-Object -First 5)) {
                $e.Flow | Should Match '^(Render|Capture)$'
                $e.Id | Should Match '^\{0\.0\.[01]\.00000000\}\.\{'
            }
        }
    }
}
