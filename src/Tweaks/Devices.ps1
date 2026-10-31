# Machine-specific tweaks: one entry per unused audio device / network adapter.

function Get-RTShortHash {
    param([string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.ToUpper()))[0..3] | ForEach-Object { $_.ToString('x2') })
}

# One enumeration serves all per-device tests of a scan; Apply/Revert invalidate it.
$script:MediaCache = $null
function Get-RTCachedMediaEntity {
    param([string]$InstanceId)
    if (-not $script:MediaCache -or ((Get-Date) - $script:MediaCache.At).TotalSeconds -gt 10) {
        $map = @{}; foreach ($e in Get-RTMediaEntities) { $map[$e.DeviceID.ToUpper()] = $e }
        $script:MediaCache = @{ At = Get-Date; Map = $map }
    }
    $script:MediaCache.Map[$InstanceId.ToUpper()]
}

$script:DeviceDisableTweak = @{
    Test = {
        param($t)
        $d = Get-RTCachedMediaEntity $t.Params.InstanceId
        if (-not $d) { return New-RTTestResult 'NotApplicable' 'device not present' 'disabled' }
        $disabled = Test-RTDeviceDisabled $d
        New-RTTestResult -Status $(if ($disabled) { 'Ok' } else { 'NotOptimal' }) -Current $(if ($disabled) { 'disabled' } else { 'enabled' }) -Desired 'disabled'
    }
    Backup = { param($t) @{ InstanceId = $t.Params.InstanceId; WasEnabled = $true } }
    Apply  = { param($t) $script:MediaCache = $null; Disable-PnpDevice -InstanceId $t.Params.InstanceId -Confirm:$false }
    Revert = { param($t, $state) $script:MediaCache = $null; if ($state.WasEnabled) { Enable-PnpDevice -InstanceId $t.Params.InstanceId -Confirm:$false } }
}

Register-RTTweakProvider {
    param($ctx)
    $hasInterface = [bool]$ctx.Interfaces
    foreach ($d in $ctx.AudioDevices) {
        $why = $null; $presets = @()
        switch ($d.Type) {
            'Display' {
                $why = 'GPU/monitor (HDMI/DisplayPort) audio adds a driver that is a common source of DPC spikes. Only disable it if you do not use monitor or TV speakers.'
                if ($hasInterface) { $presets = @('Recommended') }
            }
            'Onboard' {
                # Without a dedicated interface the onboard chip is the audio device, so never offer it then.
                if ($hasInterface) { $why = 'With a dedicated interface the onboard audio chip is unused, but its driver and endpoints still load. Disabling it also stops Windows or apps from switching to it.' }
            }
            'UsbOther' { $why = 'Unused USB audio devices (webcam microphones, headsets) register extra endpoints and can confuse device selection. Disable only devices you do not use for audio.' }
        }
        if (-not $why) { continue }
        @{
            Id = "device.disable.$(Get-RTShortHash $d.InstanceId)"; Category = 'Audio devices'; Risk = 'Safe'; Presets = $presets; Order = 60
            Title = "Disable audio device: $($d.Name)"; Why = $why; Kind = 'Custom'
            Params = @{ InstanceId = $d.InstanceId }
            Test = $script:DeviceDisableTweak.Test; Backup = $script:DeviceDisableTweak.Backup
            Apply = $script:DeviceDisableTweak.Apply; Revert = $script:DeviceDisableTweak.Revert
        }
    }
}

# --- Network adapter power saving -------------------------------------------------

$script:NetAdvancedTweak = @{
    Test = {
        param($t)
        $p = Get-NetAdapterAdvancedProperty -Name $t.Params.Adapter -RegistryKeyword $t.Params.Keyword -ErrorAction SilentlyContinue
        if (-not $p) { return New-RTTestResult 'NotApplicable' 'not supported by adapter' $t.Params.Value }
        $cur = "$(@($p.RegistryValue)[0])"
        New-RTTestResult -Status $(if ($cur -eq "$($t.Params.Value)") { 'Ok' } else { 'NotOptimal' }) -Current "$($p.DisplayValue) ($cur)" -Desired $t.Params.Value
    }
    Backup = { param($t) @{ Value = "$(@((Get-NetAdapterAdvancedProperty -Name $t.Params.Adapter -RegistryKeyword $t.Params.Keyword).RegistryValue)[0])" } }
    Apply  = { param($t) Set-NetAdapterAdvancedProperty -Name $t.Params.Adapter -RegistryKeyword $t.Params.Keyword -RegistryValue $t.Params.Value }
    Revert = { param($t, $state) Set-NetAdapterAdvancedProperty -Name $t.Params.Adapter -RegistryKeyword $t.Params.Keyword -RegistryValue $state.Value }
}

Register-RTTweakProvider {
    param($ctx)
    $props = @(
        @{ Keyword = '*EEE'; Value = '0'; Label = 'Energy-Efficient Ethernet'; Why = 'EEE puts the link to sleep between packets; waking it causes interrupt bursts. Changing it briefly resets the network connection.' },
        @{ Keyword = '*InterruptModeration'; Value = '0'; Label = 'interrupt moderation'; Why = 'Interrupt moderation batches network interrupts into larger, longer DPCs. Turning it off gives smaller, more frequent ones. Only worth it if LatencyMon blames ndis.sys. Briefly resets the network connection.' }
    )
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue) {
        $keywords = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | ForEach-Object RegistryKeyword)
        foreach ($p in $props) {
            if ($keywords -notcontains $p.Keyword) { continue }
            @{
                Id = "net.$($p.Keyword.Trim('*').ToLower()).$(Get-RTShortHash $a.InterfaceGuid)"; Category = 'Network'; Risk = 'Moderate'; Presets = @('Aggressive'); Order = 70
                Title = "Turn off $($p.Label): $($a.Name)"; Why = $p.Why; Kind = 'Custom'
                Params = @{ Adapter = $a.Name; Keyword = $p.Keyword; Value = $p.Value }
                Test = $script:NetAdvancedTweak.Test; Backup = $script:NetAdvancedTweak.Backup
                Apply = $script:NetAdvancedTweak.Apply; Revert = $script:NetAdvancedTweak.Revert
            }
        }
    }
}
