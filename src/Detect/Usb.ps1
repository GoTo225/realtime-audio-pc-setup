# USB topology: the path from a device to its host controller, devices sharing that controller,
# controller vendor and Thunderbolt detection. Everything matches IDs, classes and services, never
# localized names (names are only used for display).
#
# Collectors (WMI/CIM) build a plain node map: upper-case instance id -> node with
#   InstanceId, ParentId, Name, PnpClass, Service, CompatibleIds (string[]).
# All decisions are pure functions over that map, so tests can feed fake device lists.

$script:UsbHubServices        = @('usbhub', 'usbhub3')
$script:ThunderboltServices   = @('nhi', 'Usb4HostRouter')
$script:UsbControllerVendors  = @{
    '8086' = @{ Vendor = 'Intel';             AddOn = $false }
    '1022' = @{ Vendor = 'AMD';               AddOn = $false }
    '1B21' = @{ Vendor = 'ASMedia';           AddOn = $true }
    '1106' = @{ Vendor = 'VIA';               AddOn = $true }
    '1912' = @{ Vendor = 'Renesas/NEC';       AddOn = $true }
    '1B73' = @{ Vendor = 'Fresco Logic';      AddOn = $true }
    '104C' = @{ Vendor = 'Texas Instruments'; AddOn = $true }
}

#region Pure helpers ------------------------------------------------------------

function New-RTPnpNode {
    param([string]$InstanceId, [string]$ParentId = '', [string]$Name = '', [string]$PnpClass = '', [string]$Service = '', [string[]]$CompatibleIds = @())
    [pscustomobject]@{ InstanceId = $InstanceId; ParentId = $ParentId; Name = $Name; PnpClass = $PnpClass; Service = $Service; CompatibleIds = @($CompatibleIds | Where-Object { $_ }) }
}

function Test-RTUsbHubNode {
    # USB 2 hubs report class 09; hubs driven by usbhub3 report USB\USB30_HUB / USB\USB20_HUB instead.
    param($Node)
    if ($script:UsbHubServices -contains "$($Node.Service)") { return $true }
    [bool](@($Node.CompatibleIds) | Where-Object { "$_" -match '^USB\\(Class_09(&|$)|USB[23]0_HUB$)' })
}

function Get-RTUsbNodeKind {
    # 'Controller' for any non-USB node: only meaningful for the first non-USB ancestor of a USB device.
    param($Node)
    $id = "$($Node.InstanceId)".ToUpper()
    if ($id -notmatch '^USB\\') { return 'Controller' }
    if ($id -match '^USB\\ROOT_HUB') { return 'RootHub' }
    if (Test-RTUsbHubNode $Node) { return 'Hub' }
    'Device'
}

function Get-RTUsbChain {
    <#
      Ancestors of a USB device up to and including its host controller (parent first; with
      -IncludeSelf the device itself comes first). Empty if the device is not on a USB bus.
      Each element: InstanceId, Name, Kind ('Device','Hub','RootHub','Controller').
    #>
    param([Parameter(Mandatory)][hashtable]$Nodes, [Parameter(Mandatory)][string]$InstanceId, [switch]$IncludeSelf)
    $cur = $Nodes[$InstanceId.ToUpper()]
    if (-not $cur) { return @() }
    $out = New-Object System.Collections.ArrayList
    $seenUsb = "$($cur.InstanceId)" -match '^USB\\'
    if ($IncludeSelf) {
        $kind = if ($seenUsb) { Get-RTUsbNodeKind $cur } else { 'Device' }
        [void]$out.Add([pscustomobject]@{ InstanceId = $cur.InstanceId; Name = $cur.Name; Kind = $kind })
    }
    for ($i = 0; $i -lt 32; $i++) {
        $parentId = "$($cur.ParentId)"
        if (-not $parentId) { break }
        $p = $Nodes[$parentId.ToUpper()]
        $isUsb = $parentId -match '^USB\\'
        if ($isUsb) {
            if (-not $p) { break }
            $seenUsb = $true
            [void]$out.Add([pscustomobject]@{ InstanceId = $p.InstanceId; Name = $p.Name; Kind = (Get-RTUsbNodeKind $p) })
        } elseif ($seenUsb) {
            $name = if ($p) { $p.Name } else { '' }
            [void]$out.Add([pscustomobject]@{ InstanceId = $(if ($p) { $p.InstanceId } else { $parentId }); Name = $name; Kind = 'Controller' })
            return @($out)
        } else {
            # e.g. USBSTOR\DISK or HID\ below a USB device: keep walking until the USB part starts
            if (-not $p) { break }
            [void]$out.Add([pscustomobject]@{ InstanceId = $p.InstanceId; Name = $p.Name; Kind = 'Device' })
        }
        $cur = $p
    }
    @()
}

function Get-RTPnpAncestorIds {
    param([hashtable]$Nodes, [string]$InstanceId)
    $ids = New-Object System.Collections.ArrayList
    $cur = $Nodes[$InstanceId.ToUpper()]
    for ($i = 0; $cur -and $i -lt 64; $i++) {
        $parentId = "$($cur.ParentId)"
        if (-not $parentId) { break }
        [void]$ids.Add($parentId.ToUpper())
        $cur = $Nodes[$parentId.ToUpper()]
    }
    @($ids)
}

function Get-RTPnpChildIndex {
    param([hashtable]$Nodes)
    $idx = @{}
    foreach ($n in $Nodes.Values) {
        if (-not $n.ParentId) { continue }
        $k = "$($n.ParentId)".ToUpper()
        if (-not $idx.ContainsKey($k)) { $idx[$k] = New-Object System.Collections.ArrayList }
        [void]$idx[$k].Add($n)
    }
    $idx
}

function Get-RTPnpSubtree {
    param([hashtable]$Nodes, [hashtable]$Children, [string]$RootId)
    $out = New-Object System.Collections.ArrayList
    $root = $Nodes[$RootId.ToUpper()]
    if (-not $root) { return @() }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root)
    while ($queue.Count -gt 0 -and $out.Count -lt 500) {
        $n = $queue.Dequeue()
        [void]$out.Add($n)
        $k = "$($n.InstanceId)".ToUpper()
        if ($Children.ContainsKey($k)) { foreach ($c in $Children[$k]) { $queue.Enqueue($c) } }
    }
    @($out)
}

function Test-RTThunderboltPath {
    <#
      True if the device sits below a Thunderbolt / USB4 controller: it shares a PCI ancestor (root port
      or switch port, never the root complex) with a Thunderbolt NHI / USB4 host router (driver services
      nhi, Usb4HostRouter). A root port is a single link, so everything below it is the same controller.
      Misses CPU-integrated Thunderbolt whose NHI hangs directly off the root complex.
    #>
    param([Parameter(Mandatory)][hashtable]$Nodes, [Parameter(Mandatory)][string]$InstanceId)
    $mine = @(@($InstanceId.ToUpper()) + @(Get-RTPnpAncestorIds -Nodes $Nodes -InstanceId $InstanceId) | Where-Object { $_ -match '^PCI\\' })
    if (-not $mine) { return $false }
    foreach ($n in $Nodes.Values) {
        if ($script:ThunderboltServices -notcontains "$($n.Service)") { continue }
        $theirs = @(@("$($n.InstanceId)".ToUpper()) + @(Get-RTPnpAncestorIds -Nodes $Nodes -InstanceId $n.InstanceId) | Where-Object { $_ -match '^PCI\\' })
        foreach ($a in $theirs) { if ($mine -contains $a) { return $true } }
    }
    $false
}

function Get-RTUsbControllerVendor {
    # Vendor of a host controller from its PCI vendor id; $null if it is not a PCI device.
    param([string]$InstanceId)
    $m = [regex]::Match("$InstanceId", '^PCI\\VEN_([0-9A-Fa-f]{4})', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $ven = $m.Groups[1].Value.ToUpper()
    if ($script:UsbControllerVendors.ContainsKey($ven)) {
        $v = $script:UsbControllerVendors[$ven]
        return [pscustomobject]@{ VendorId = $ven; Vendor = $v.Vendor; AddOn = $v.AddOn }
    }
    [pscustomobject]@{ VendorId = $ven; Vendor = "PCI vendor $ven"; AddOn = $false }
}

function Get-RTUsbDeviceCategory {
    <#
      Category of a device plugged into a USB port, from all nodes of its subtree:
      'storage','camera','network','bluetooth','audio','hid' (only HID functions) or 'other'.
      Name: the most telling node name (e.g. the disk rather than 'USB Mass Storage Device').
    #>
    param([object[]]$Subtree)
    $rules = @(
        @{ Category = 'storage';   Test = { param($n) $n.PnpClass -eq 'DiskDrive' -or @('USBSTOR', 'UASPStor') -contains "$($n.Service)" -or (@($n.CompatibleIds) -match '^USB\\Class_08(&|$)') } },
        @{ Category = 'camera';    Test = { param($n) @('Camera', 'Image') -contains "$($n.PnpClass)" -or (@($n.CompatibleIds) -match '^USB\\Class_0e(&|$)') } },
        @{ Category = 'network';   Test = { param($n) $n.PnpClass -eq 'Net' } },
        @{ Category = 'bluetooth'; Test = { param($n) $n.PnpClass -eq 'Bluetooth' -or (@($n.CompatibleIds) -match '^USB\\Class_e0&SubClass_01&Prot_01') } },
        @{ Category = 'audio';     Test = { param($n) $n.PnpClass -eq 'MEDIA' -or (@($n.CompatibleIds) -match '^USB\\Class_01(&|$)') } }
    )
    $nodes = @($Subtree | Where-Object { $_ })
    foreach ($r in $rules) {
        $hits = @($nodes | Where-Object { & $r.Test $_ })
        if ($hits) {
            # Prefer a function/disk name over the generic composite or mass-storage parent name.
            $named = @($hits | Where-Object { $_.PnpClass -and $_.PnpClass -ne 'USB' -and $_.Name })
            $name = if ($named) { $named[-1].Name } elseif ($hits[0].Name) { $hits[0].Name } else { "$($nodes[0].Name)" }
            return [pscustomobject]@{ Category = $r.Category; Name = $name }
        }
    }
    $hidOnly = $true; $anyHid = $false
    foreach ($n in $nodes) {
        if (@('HIDClass', 'Keyboard', 'Mouse') -contains "$($n.PnpClass)" -or (@($n.CompatibleIds) -match '^USB\\Class_03(&|$)')) { $anyHid = $true; continue }
        # the composite parent itself (usbccgp) says nothing about the device
        if ("$($n.PnpClass)" -eq 'USB' -and "$($n.Service)" -eq 'usbccgp') { continue }
        $hidOnly = $false
    }
    if ($anyHid -and $hidOnly) { return [pscustomobject]@{ Category = 'hid'; Name = "$($nodes[0].Name)" } }
    [pscustomobject]@{ Category = 'other'; Name = $(if ($nodes) { "$($nodes[0].Name)" } else { '' }) }
}

function Get-RTUsbPortDeviceId {
    # The device actually plugged into a port: the last non-hub node of the chain before the first hub.
    param([object[]]$ChainWithSelf)
    $port = $null
    foreach ($n in $ChainWithSelf) {
        if ($n.Kind -eq 'Device') { $port = $n.InstanceId } else { break }
    }
    $port
}

function Get-RTUsbControllerPeers {
    <#
      Devices on the same host controller as the given device, excluding hubs, the device's own
      functions/children and HID-only devices (keyboard/mouse: too little bandwidth to matter).
      Each: InstanceId, Name, Category.
    #>
    param([Parameter(Mandatory)][hashtable]$Nodes, [Parameter(Mandatory)][string]$InstanceId, [hashtable]$Children)
    $chain = @(Get-RTUsbChain -Nodes $Nodes -InstanceId $InstanceId -IncludeSelf)
    if (-not $chain -or $chain[-1].Kind -ne 'Controller') { return @() }
    if (-not $Children) { $Children = Get-RTPnpChildIndex $Nodes }
    $own = "$(Get-RTUsbPortDeviceId $chain)".ToUpper()
    $ctrl = "$($chain[-1].InstanceId)".ToUpper()
    $out = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    if ($Children.ContainsKey($ctrl)) { foreach ($c in $Children[$ctrl]) { $queue.Enqueue($c) } }
    $guard = 0
    while ($queue.Count -gt 0 -and $guard++ -lt 1000) {
        $n = $queue.Dequeue()
        if ("$($n.InstanceId)" -notmatch '^USB\\') { continue }
        $kind = Get-RTUsbNodeKind $n
        $k = "$($n.InstanceId)".ToUpper()
        if ($kind -eq 'RootHub' -or $kind -eq 'Hub') {
            if ($Children.ContainsKey($k)) { foreach ($c in $Children[$k]) { $queue.Enqueue($c) } }
            continue
        }
        if ($k -eq $own) { continue }
        $cat = Get-RTUsbDeviceCategory -Subtree (Get-RTPnpSubtree -Nodes $Nodes -Children $Children -RootId $n.InstanceId)
        if ($cat.Category -eq 'hid') { continue }
        [void]$out.Add([pscustomobject]@{ InstanceId = $n.InstanceId; Name = $cat.Name; Category = $cat.Category })
    }
    $rank = @{ storage = 0; camera = 1; network = 2; bluetooth = 3; audio = 4; other = 5 }
    @($out | Sort-Object { $rank[$_.Category] }, Name)
}

function Get-RTUsbTopologyFindings {
    # Interfaces: objects with Name and InstanceId (as in $ctx.Interfaces).
    param([Parameter(Mandatory)][hashtable]$Nodes, [object[]]$Interfaces)
    $children = Get-RTPnpChildIndex $Nodes
    foreach ($i in @($Interfaces | Where-Object { $_ })) {
        $id = "$($i.InstanceId)"
        $hash = Get-RTShortHash $id
        $name = "$($i.Name)"
        if ($id -notmatch '^USB\\') {
            $tb = Test-RTThunderboltPath -Nodes $Nodes -InstanceId $id
            $how = if ($tb) { 'Thunderbolt' } else { 'PCIe/Thunderbolt' }
            New-RTFinding -Id "usb-topology.pcie.$hash" -Severity Info -Category 'Hardware' `
                -Title "$name is connected via $how; USB checks don't apply" `
                -Detail $(if ($tb) { 'Its path to the CPU runs through a Thunderbolt controller. Use a certified cable and, if possible, a port directly on the computer rather than a dock.' } else { 'Not a USB device, so USB port, hub and controller-sharing advice does not apply.' })
            continue
        }
        $chain = @(Get-RTUsbChain -Nodes $Nodes -InstanceId $id -IncludeSelf)
        if (-not $chain -or $chain[-1].Kind -ne 'Controller') { continue }
        $ctrl = $chain[-1]
        $ctrlLabel = if ($ctrl.Name) { $ctrl.Name } else { $ctrl.InstanceId }
        $tbNote = if (Test-RTThunderboltPath -Nodes $Nodes -InstanceId $ctrl.InstanceId) { ' This controller sits behind a Thunderbolt/USB4 controller (USB-C port or dock).' } else { '' }
        $peers = @(Get-RTUsbControllerPeers -Nodes $Nodes -InstanceId $id -Children $children)
        $heavy = @($peers | Where-Object { @('storage', 'camera', 'network') -contains $_.Category })
        $light = @($peers | Where-Object { @('storage', 'camera', 'network') -notcontains $_.Category })
        $list = { param($ps) (@($ps | ForEach-Object { "$($_.Name) ($($_.Category))" }) -join ', ') }
        if ($heavy) {
            New-RTFinding -Id "usb-topology.shared.$hash" -Severity Warning -Category 'Hardware' `
                -Title "$name shares its USB controller with: $(& $list $heavy)" `
                -Detail ("Controller: $ctrlLabel.$tbNote" + $(if ($light) { " Also on it: $(& $list $light)." } else { '' })) `
                -Advice 'Drives, cameras and network adapters move a lot of data and can cause crackles. Move one of them (or the interface) to a port on another USB controller, e.g. the other rear port group or a USB-C port.' `
                -GuideId 'usb-connection'
        } else {
            New-RTFinding -Id "usb-topology.ok.$hash" -Severity Ok -Category 'Hardware' `
                -Title "$name does not share its USB controller with drives, cameras or network adapters" `
                -Detail ("Controller: $ctrlLabel.$tbNote" + $(if ($light) { " Also on it: $(& $list $light)." } else { '' }))
        }
        $vendor = Get-RTUsbControllerVendor $ctrl.InstanceId
        if ($vendor -and $vendor.AddOn) {
            New-RTFinding -Id "usb-topology.addon.$hash" -Severity Info -Category 'Hardware' `
                -Title "$name is connected to an add-on USB controller ($($vendor.Vendor))" `
                -Detail "Controller: $ctrlLabel. Ports wired to the chipset (Intel/AMD) are usually more reliable for audio; add-on controllers often drive the extra USB 3 or USB-C ports." `
                -Advice 'If you hear crackles or dropouts, try a rear port that belongs to the chipset controller.' -GuideId 'usb-connection'
        }
    }
}

#endregion

#region Collectors (WMI/CIM) ---------------------------------------------------

# One Win32_PnPEntity enumeration (~1 s) per scan; parent ids are looked up lazily per device
# (~5 ms each) and memoised. Shared by the detector and the USB power tweak provider.
$script:UsbTopologyCache = $null

function Add-RTPnpNodeChain {
    # Adds the device and all its ancestors to the cache's node map.
    param([hashtable]$Cache, [string]$InstanceId)
    $id = $InstanceId
    for ($i = 0; $id -and $i -lt 64; $i++) {
        $k = $id.ToUpper()
        if ($Cache.Nodes.ContainsKey($k)) { return }
        $e = $Cache.Entities[$k]
        if (-not $e) { return }
        $parent = "$((Get-RTDeviceProperties $e @('DEVPKEY_Device_Parent'))['DEVPKEY_Device_Parent'])"
        $Cache.Nodes[$k] = New-RTPnpNode -InstanceId $e.DeviceID -ParentId $parent -Name "$($e.Name)" -PnpClass "$($e.PNPClass)" -Service "$($e.Service)" -CompatibleIds @($e.CompatibleID)
        $id = $parent
    }
}

function Get-RTUsbTopology {
    <#
      Node map (see top of file) with every present USB device, disk, Thunderbolt controller, their
      ancestors, and the ancestors of -ExtraIds. Cached for 10 s.
    #>
    param([string[]]$ExtraIds = @())
    if (-not $script:UsbTopologyCache -or ((Get-Date) - $script:UsbTopologyCache.At).TotalSeconds -gt 10) {
        $entities = @{}
        foreach ($e in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
            if ($e.DeviceID -and $e.Present -ne $false) { $entities[$e.DeviceID.ToUpper()] = $e }
        }
        $cache = @{ At = Get-Date; Entities = $entities; Nodes = @{} }
        foreach ($e in $entities.Values) {
            if ($e.DeviceID -match '^USB\\' -or "$($e.PNPClass)" -eq 'DiskDrive' -or $script:ThunderboltServices -contains "$($e.Service)") {
                Add-RTPnpNodeChain -Cache $cache -InstanceId $e.DeviceID
            }
        }
        $script:UsbTopologyCache = $cache
    }
    foreach ($x in @($ExtraIds | Where-Object { $_ })) { Add-RTPnpNodeChain -Cache $script:UsbTopologyCache -InstanceId $x }
    $script:UsbTopologyCache.Nodes
}

function Get-RTUsbDeviceChain {
    # Live: ancestor chain of a device up to its USB host controller (see Get-RTUsbChain).
    param([Parameter(Mandatory)][string]$InstanceId, [switch]$IncludeSelf)
    $nodes = Get-RTUsbTopology -ExtraIds @($InstanceId)
    Get-RTUsbChain -Nodes $nodes -InstanceId $InstanceId -IncludeSelf:$IncludeSelf
}

#endregion

Register-RTDetector -Id 'usb-topology' -Detect {
    param($ctx)
    $ifs = @($ctx['Interfaces'] | Where-Object { $_ -and $_.InstanceId })
    if (-not $ifs) { return }
    $nodes = Get-RTUsbTopology -ExtraIds @($ifs | ForEach-Object { "$($_.InstanceId)" })
    Get-RTUsbTopologyFindings -Nodes $nodes -Interfaces $ifs
}
