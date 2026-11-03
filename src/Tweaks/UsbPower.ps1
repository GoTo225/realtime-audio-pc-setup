# Per-device "Allow the computer to turn off this device to save power" for every node on the path
# from a USB audio interface to its host controller (the device, its composite parent, hubs, root
# hub, controller). Windows exposes this flag language independently as WMI root\wmi
# MSPower_DeviceEnable; InstanceName is the PnP instance id (instance part lower-cased) plus '_0'.
# Devices whose driver does not support it (e.g. usbccgp composite parents) have no instance.

$script:UsbPowerCache = $null

function ConvertTo-RTPowerInstanceKey {
    # 'USB\ROOT_HUB30\4&1d409f65&0&0_0' -> 'USB\ROOT_HUB30\4&1D409F65&0&0'
    param([string]$InstanceName)
    ($InstanceName -replace '_\d+$', '').ToUpper()
}

function Get-RTUsbPowerInstance {
    # MSPower_DeviceEnable instance for a PnP instance id ($null if none). Cached 10 s unless -Fresh.
    param([Parameter(Mandatory)][string]$InstanceId, [switch]$Fresh)
    if ($Fresh -or -not $script:UsbPowerCache -or ((Get-Date) - $script:UsbPowerCache.At).TotalSeconds -gt 10) {
        $map = @{}
        foreach ($p in @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)) {
            if ($p.InstanceName) { $map[(ConvertTo-RTPowerInstanceKey $p.InstanceName)] = $p }
        }
        $script:UsbPowerCache = @{ At = Get-Date; Map = $map }
    }
    $script:UsbPowerCache.Map[$InstanceId.ToUpper()]
}

function Get-RTUsbPowerTargets {
    <#
      Pure: nodes on the paths of the given USB interfaces that have a power-management flag
      (PowerKeys: upper-case instance ids), de-duplicated across interfaces. Each: InstanceId, Name, Kind.
    #>
    param([Parameter(Mandatory)][hashtable]$Nodes, [object[]]$Interfaces, [string[]]$PowerKeys)
    $seen = @{}
    foreach ($i in @($Interfaces | Where-Object { $_ -and "$($_.InstanceId)" -match '^USB\\' })) {
        foreach ($n in @(Get-RTUsbChain -Nodes $Nodes -InstanceId "$($i.InstanceId)" -IncludeSelf)) {
            $k = "$($n.InstanceId)".ToUpper()
            if ($seen.ContainsKey($k) -or $PowerKeys -notcontains $k) { continue }
            $seen[$k] = $true
            $n
        }
    }
}

$script:UsbPowerTweak = @{
    Test = {
        param($t)
        $p = Get-RTUsbPowerInstance $t.Params.InstanceId
        if (-not $p) { return New-RTTestResult 'NotApplicable' 'device not present' 'not allowed' }
        if ($p.Enable) { New-RTTestResult 'NotOptimal' 'Windows may turn it off' 'not allowed' }
        else { New-RTTestResult 'Ok' 'not allowed' 'not allowed' }
    }
    Backup = {
        param($t)
        $p = Get-RTUsbPowerInstance $t.Params.InstanceId -Fresh
        if (-not $p) { throw "Device not present: $($t.Params.InstanceId)" }
        @{ InstanceId = $t.Params.InstanceId; Enable = [bool]$p.Enable }
    }
    Apply = {
        param($t)
        $p = Get-RTUsbPowerInstance $t.Params.InstanceId -Fresh
        if (-not $p) { throw "Device not present: $($t.Params.InstanceId)" }
        Set-CimInstance -InputObject $p -Property @{ Enable = $false } -ErrorAction Stop
        $script:UsbPowerCache = $null
    }
    Revert = {
        param($t, $state)
        $p = Get-RTUsbPowerInstance $t.Params.InstanceId -Fresh
        if (-not $p) { throw "Device not present: $($t.Params.InstanceId)" }
        Set-CimInstance -InputObject $p -Property @{ Enable = [bool]$state.Enable } -ErrorAction Stop
        $script:UsbPowerCache = $null
    }
}

Register-RTTweakProvider {
    param($ctx)
    $ifs = @($ctx['Interfaces'] | Where-Object { $_ -and "$($_.InstanceId)" -match '^USB\\' })
    if (-not $ifs) { return }
    $nodes = Get-RTUsbTopology -ExtraIds @($ifs | ForEach-Object { "$($_.InstanceId)" })
    [void](Get-RTUsbPowerInstance 'x' -Fresh)
    $keys = @($script:UsbPowerCache.Map.Keys)
    foreach ($n in @(Get-RTUsbPowerTargets -Nodes $nodes -Interfaces $ifs -PowerKeys $keys)) {
        $label = if ($n.Name) { $n.Name } else { $n.InstanceId }
        $what = @{ Device = 'device'; Hub = 'hub'; RootHub = 'root hub'; Controller = 'controller' }[$n.Kind]
        @{
            Id = "usb.power.$(Get-RTShortHash $n.InstanceId)"; Category = 'Power'; Risk = 'Safe'; Presets = @('Recommended'); Order = 25
            Title = "Don't let Windows turn off $label to save power"
            Why = "Windows may power down this $what when it thinks it is idle; waking it takes time and causes dropouts or a disconnected interface. One entry per device on the path from the audio interface to its USB controller (Device Manager > Power Management)."
            Kind = 'Custom'
            Params = @{ InstanceId = $n.InstanceId }
            Test = $script:UsbPowerTweak.Test; Backup = $script:UsbPowerTweak.Backup
            Apply = $script:UsbPowerTweak.Apply; Revert = $script:UsbPowerTweak.Revert
        }
    }
}
