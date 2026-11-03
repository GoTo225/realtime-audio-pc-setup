# Pester 3.4 compatible. Run: Invoke-Pester .\tests\Usb.Tests.ps1
# Pure USB topology / power logic over fake device lists; nothing here touches WMI or changes settings.

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Engine.psm1') -Force -DisableNameChecking

InModuleScope Engine {
    function New-FakeTopology {
        $list = @(
            # Chipset controller with a USB 2 hub, a USB 3 hub and devices
            (New-RTPnpNode 'ACPI\PNP0A08\0' 'ROOT\ACPI_HAL\0000' 'PCI root complex' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_8086&DEV_7A60&SUBSYS_0C411028&REV_11\3&1&A0' 'ACPI\PNP0A08\0' 'Intel USB 3.20 xHCI' 'USB' 'USBXHCI'),
            (New-RTPnpNode 'USB\ROOT_HUB30\4&1&0&0' 'PCI\VEN_8086&DEV_7A60&SUBSYS_0C411028&REV_11\3&1&A0' 'USB Root Hub (USB 3.0)' 'USB' 'USBHUB3'),
            (New-RTPnpNode 'USB\VID_05E3&PID_0610\5&1&0&1' 'USB\ROOT_HUB30\4&1&0&0' 'Generic USB Hub' 'USB' 'usbhub' @('USB\Class_09&SubClass_00&Prot_02', 'USB\Class_09')),
            (New-RTPnpNode 'USB\VID_0BDA&PID_0483\5&1&0&2' 'USB\ROOT_HUB30\4&1&0&0' 'Generic SuperSpeed USB Hub' 'USB' 'xusbhub' @('USB\USB30_HUB')),
            (New-RTPnpNode 'USB\VID_1235&PID_8211\S123' 'USB\VID_05E3&PID_0610\5&1&0&1' 'USB Composite Device' 'USB' 'usbccgp' @('USB\COMPOSITE')),
            (New-RTPnpNode 'USB\VID_1235&PID_8211&MI_00\6&1&0&0000' 'USB\VID_1235&PID_8211\S123' 'Focusrite USB Audio' 'MEDIA' 'FocusriteUsb' @('USB\Class_01&SubClass_01')),
            (New-RTPnpNode 'USB\VID_1235&PID_8211&MI_03\6&1&0&0003' 'USB\VID_1235&PID_8211\S123' 'Focusrite Control' 'USBDevice' 'WINUSB' @('USB\Class_fe')),
            (New-RTPnpNode 'USB\VID_04E8&PID_4001\S7' 'USB\VID_0BDA&PID_0483\5&1&0&2' 'USB Attached SCSI (UAS) Mass Storage Device' 'SCSIAdapter' 'UASPStor' @('USB\Class_08&SubClass_06&Prot_62')),
            (New-RTPnpNode 'SCSI\DISK&VEN_SAMSUNG&PROD_PSSD_T7\7&1&0&000000' 'USB\VID_04E8&PID_4001\S7' 'Samsung PSSD T7 SCSI Disk Device' 'DiskDrive' 'disk'),
            (New-RTPnpNode 'USB\VID_046D&PID_085E\SB' 'USB\ROOT_HUB30\4&1&0&0' 'USB Composite Device' 'USB' 'usbccgp' @('USB\COMPOSITE')),
            (New-RTPnpNode 'USB\VID_046D&PID_085E&MI_00\6&2&0&0000' 'USB\VID_046D&PID_085E\SB' 'Logitech BRIO' 'Camera' 'usbvideo' @('USB\Class_0e&SubClass_03')),
            (New-RTPnpNode 'USB\VID_046D&PID_085E&MI_02\6&2&0&0002' 'USB\VID_046D&PID_085E\SB' 'Logitech BRIO Audio' 'MEDIA' 'usbaudio' @('USB\Class_01')),
            (New-RTPnpNode 'USB\VID_046D&PID_C31C\5&1&0&3' 'USB\ROOT_HUB30\4&1&0&0' 'USB Composite Device' 'USB' 'usbccgp' @('USB\COMPOSITE')),
            (New-RTPnpNode 'USB\VID_046D&PID_C31C&MI_00\6&3&0&0000' 'USB\VID_046D&PID_C31C\5&1&0&3' 'USB Input Device' 'HIDClass' 'HidUsb' @('USB\Class_03&SubClass_01&Prot_01')),
            (New-RTPnpNode 'USB\VID_046D&PID_C31C&MI_01\6&3&0&0001' 'USB\VID_046D&PID_C31C\5&1&0&3' 'USB Input Device' 'HIDClass' 'HidUsb' @('USB\Class_03&SubClass_00&Prot_00')),
            (New-RTPnpNode 'HID\VID_046D&PID_C31C&MI_00\7&1&0&0000' 'USB\VID_046D&PID_C31C&MI_00\6&3&0&0000' 'HID Keyboard Device' 'Keyboard' 'kbdhid'),
            (New-RTPnpNode 'USB\VID_8087&PID_0033\5&1&0&14' 'USB\ROOT_HUB30\4&1&0&0' 'Intel Wireless Bluetooth' 'Bluetooth' 'BTHUSB' @('USB\Class_e0&SubClass_01&Prot_01')),
            # ASMedia add-on controller behind a root port, with a second interface
            (New-RTPnpNode 'PCI\VEN_8086&DEV_7A40\3&1&D8' 'ACPI\PNP0A08\0' 'PCI Express Root Port' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_1B21&DEV_2142\4&9&0&00E0' 'PCI\VEN_8086&DEV_7A40\3&1&D8' 'ASMedia USB 3.1 eXtensible Host Controller' 'USB' 'USBXHCI'),
            (New-RTPnpNode 'USB\ROOT_HUB30\5&9&0&0' 'PCI\VEN_1B21&DEV_2142\4&9&0&00E0' 'USB Root Hub (USB 3.0)' 'USB' 'USBHUB3'),
            (New-RTPnpNode 'USB\VID_2708&PID_0002\A1' 'USB\ROOT_HUB30\5&9&0&0' 'Audient iD14' 'MEDIA' 'AudientUsb' @('USB\Class_01')),
            # Thunderbolt controller (switch with NHI) and a PCIe interface behind it
            (New-RTPnpNode 'PCI\VEN_8086&DEV_7A44\3&1&E0' 'ACPI\PNP0A08\0' 'PCI Express Root Port' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_8086&DEV_1136\UTB0' 'PCI\VEN_8086&DEV_7A44\3&1&E0' 'Upstream Switch Port' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_8086&DEV_1136\TB0' 'PCI\VEN_8086&DEV_1136\UTB0' 'Downstream Switch Port' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_8086&DEV_1136\TB1' 'PCI\VEN_8086&DEV_1136\UTB0' 'Downstream Switch Port' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_8086&DEV_1137\NHI' 'PCI\VEN_8086&DEV_1136\TB0' 'Thunderbolt(TM) Controller' 'System' 'nhi'),
            (New-RTPnpNode 'PCI\VEN_1AF0&DEV_0001\APOLLO' 'PCI\VEN_8086&DEV_1136\TB1' 'Universal Audio Thunderbolt' 'MEDIA' 'uadtb'),
            # PCIe card on its own root port
            (New-RTPnpNode 'PCI\VEN_8086&DEV_7A38\3&1&E8' 'ACPI\PNP0A08\0' 'PCI Express Root Port' 'System' 'pci'),
            (New-RTPnpNode 'PCI\VEN_10EE&DEV_3FC6\RME' 'PCI\VEN_8086&DEV_7A38\3&1&E8' 'RME HDSPe AIO' 'MEDIA' 'hdspe')
        )
        $h = @{}; foreach ($n in $list) { $h[$n.InstanceId.ToUpper()] = $n }
        $h
    }
    $focusrite = 'USB\VID_1235&PID_8211&MI_00\6&1&0&0000'

    Describe 'USB topology helpers' {
        $nodes = New-FakeTopology
        It 'walks from a function up to the host controller' {
            $c = @(Get-RTUsbChain -Nodes $nodes -InstanceId $focusrite -IncludeSelf)
            ($c | ForEach-Object Kind) -join ',' | Should Be 'Device,Device,Hub,RootHub,Controller'
            $c[-1].InstanceId | Should Be 'PCI\VEN_8086&DEV_7A60&SUBSYS_0C411028&REV_11\3&1&A0'
        }
        It 'starts with the parent without -IncludeSelf and matches ids case-insensitively' {
            $c = @(Get-RTUsbChain -Nodes $nodes -InstanceId $focusrite.ToLower())
            $c[0].InstanceId | Should Be 'USB\VID_1235&PID_8211\S123'
        }
        It 'recognises USB 3 hubs (USB30_HUB) as hubs' {
            Get-RTUsbNodeKind $nodes['USB\VID_0BDA&PID_0483\5&1&0&2'] | Should Be 'Hub'
        }
        It 'walks up from a disk below a USB device' {
            $c = @(Get-RTUsbChain -Nodes $nodes -InstanceId 'SCSI\DISK&VEN_SAMSUNG&PROD_PSSD_T7\7&1&0&000000')
            $c[-1].Kind | Should Be 'Controller'
            @($c | Where-Object Kind -eq 'Hub').Count | Should Be 1
        }
        It 'returns nothing for a non-USB device' {
            @(Get-RTUsbChain -Nodes $nodes -InstanceId 'PCI\VEN_10EE&DEV_3FC6\RME').Count | Should Be 0
        }
        It 'finds the device plugged into the port' {
            Get-RTUsbPortDeviceId @(Get-RTUsbChain -Nodes $nodes -InstanceId $focusrite -IncludeSelf) | Should Be 'USB\VID_1235&PID_8211\S123'
        }
        It 'maps controller vendors' {
            (Get-RTUsbControllerVendor 'PCI\VEN_1B21&DEV_2142\4&9').Vendor | Should Be 'ASMedia'
            (Get-RTUsbControllerVendor 'PCI\VEN_1B21&DEV_2142\4&9').AddOn | Should Be $true
            (Get-RTUsbControllerVendor 'pci\ven_8086&dev_7a60\3').AddOn | Should Be $false
            Get-RTUsbControllerVendor 'ACPI\PNP0A08\0' | Should Be $null
        }
        It 'detects Thunderbolt paths' {
            Test-RTThunderboltPath -Nodes $nodes -InstanceId 'PCI\VEN_1AF0&DEV_0001\APOLLO' | Should Be $true
            Test-RTThunderboltPath -Nodes $nodes -InstanceId 'PCI\VEN_10EE&DEV_3FC6\RME' | Should Be $false
            Test-RTThunderboltPath -Nodes $nodes -InstanceId 'PCI\VEN_8086&DEV_7A60&SUBSYS_0C411028&REV_11\3&1&A0' | Should Be $false
        }
    }

    Describe 'Get-RTUsbDeviceCategory' {
        It 'names storage after the disk' {
            $r = Get-RTUsbDeviceCategory @((New-RTPnpNode 'USB\A' '' 'USB Mass Storage Device' 'USB' 'USBSTOR'), (New-RTPnpNode 'USBSTOR\DISK' 'USB\A' 'SanDisk Extreme' 'DiskDrive' 'disk'))
            $r.Category | Should Be 'storage'
            $r.Name | Should Be 'SanDisk Extreme'
        }
        It 'classifies network, Bluetooth, keyboards and unknown devices' {
            (Get-RTUsbDeviceCategory @(New-RTPnpNode 'USB\N' '' 'Realtek USB GbE' 'Net' 'rtux64w10')).Category | Should Be 'network'
            (Get-RTUsbDeviceCategory @(New-RTPnpNode 'USB\B' '' 'BT' 'USB' 'BTHUSB' @('USB\Class_e0&SubClass_01&Prot_01'))).Category | Should Be 'bluetooth'
            (Get-RTUsbDeviceCategory @((New-RTPnpNode 'USB\K' '' 'Composite' 'USB' 'usbccgp'), (New-RTPnpNode 'USB\K&MI_00' 'USB\K' 'Input' 'HIDClass' 'HidUsb'))).Category | Should Be 'hid'
            (Get-RTUsbDeviceCategory @(New-RTPnpNode 'USB\X' '' 'Dongle' 'USBDevice' 'WINUSB')).Category | Should Be 'other'
        }
    }

    Describe 'Get-RTUsbControllerPeers' {
        $nodes = New-FakeTopology
        $peers = @(Get-RTUsbControllerPeers -Nodes $nodes -InstanceId $focusrite)
        It 'lists storage, camera and Bluetooth on the same controller' {
            ($peers | Where-Object Category -eq 'storage').Name | Should Be 'Samsung PSSD T7 SCSI Disk Device'
            ($peers | Where-Object Category -eq 'camera').Name | Should Be 'Logitech BRIO'
            @($peers | Where-Object Category -eq 'bluetooth').Count | Should Be 1
        }
        It 'skips hubs, keyboards and the interface itself' {
            $peers.Count | Should Be 3
            @($peers | Where-Object { $_.InstanceId -like 'USB\VID_1235*' -or $_.InstanceId -like 'USB\VID_046D&PID_C31C*' }).Count | Should Be 0
        }
        It 'finds nothing for an interface alone on its controller' {
            @(Get-RTUsbControllerPeers -Nodes $nodes -InstanceId 'USB\VID_2708&PID_0002\A1').Count | Should Be 0
        }
    }

    Describe 'Get-RTUsbTopologyFindings' {
        $nodes = New-FakeTopology
        $ifs = @(
            [pscustomobject]@{ Name = 'Scarlett 2i2'; InstanceId = $focusrite },
            [pscustomobject]@{ Name = 'Audient iD14'; InstanceId = 'USB\VID_2708&PID_0002\A1' },
            [pscustomobject]@{ Name = 'Apollo Twin'; InstanceId = 'PCI\VEN_1AF0&DEV_0001\APOLLO' },
            [pscustomobject]@{ Name = 'RME AIO'; InstanceId = 'PCI\VEN_10EE&DEV_3FC6\RME' }
        )
        $f = @(Get-RTUsbTopologyFindings -Nodes $nodes -Interfaces $ifs)
        It 'warns about storage and cameras sharing the controller' {
            $w = @($f | Where-Object { $_.Id -like 'usb-topology.shared.*' })
            $w.Count | Should Be 1
            $w[0].Severity | Should Be 'Warning'
            $w[0].Title | Should Be 'Scarlett 2i2 shares its USB controller with: Samsung PSSD T7 SCSI Disk Device (storage), Logitech BRIO (camera)'
            $w[0].GuideId | Should Be 'usb-connection'
        }
        It 'reports Ok plus an add-on controller note for the ASMedia port' {
            @($f | Where-Object { $_.Id -like 'usb-topology.ok.*' -and $_.Title -like 'Audient*' }).Count | Should Be 1
            $a = @($f | Where-Object { $_.Id -like 'usb-topology.addon.*' })
            $a.Count | Should Be 1
            $a[0].Title | Should Be 'Audient iD14 is connected to an add-on USB controller (ASMedia)'
        }
        It 'skips USB checks for PCIe and Thunderbolt interfaces' {
            ($f | Where-Object { $_.Title -like 'Apollo*' }).Title | Should Be "Apollo Twin is connected via Thunderbolt; USB checks don't apply"
            ($f | Where-Object { $_.Title -like 'RME*' }).Title | Should Be "RME AIO is connected via PCIe/Thunderbolt; USB checks don't apply"
        }
        It 'uses unique finding ids' {
            @($f | Group-Object Id | Where-Object Count -gt 1).Count | Should Be 0
        }
        It 'is registered as a detector' {
            @($script:Detectors | Where-Object { $_.Id -eq 'usb-topology' }).Count | Should Be 1
        }
    }

    Describe 'USB power management targets' {
        $nodes = New-FakeTopology
        It 'normalises MSPower_DeviceEnable instance names' {
            ConvertTo-RTPowerInstanceKey 'USB\ROOT_HUB30\4&1d409f65&0&0_0' | Should Be 'USB\ROOT_HUB30\4&1D409F65&0&0'
        }
        It 'returns each powered node on the interface paths once' {
            $keys = @('USB\VID_05E3&PID_0610\5&1&0&1', 'USB\ROOT_HUB30\4&1&0&0', 'PCI\VEN_8086&DEV_7A60&SUBSYS_0C411028&REV_11\3&1&A0', 'USB\VID_8087&PID_0033\5&1&0&14')
            $ifs = @(
                [pscustomobject]@{ Name = 'A'; InstanceId = $focusrite },
                [pscustomobject]@{ Name = 'B'; InstanceId = 'USB\VID_1235&PID_8211&MI_03\6&1&0&0003' },
                [pscustomobject]@{ Name = 'C'; InstanceId = 'PCI\VEN_10EE&DEV_3FC6\RME' }
            )
            $t = @(Get-RTUsbPowerTargets -Nodes $nodes -Interfaces $ifs -PowerKeys $keys)
            ($t | ForEach-Object Kind) -join ',' | Should Be 'Hub,RootHub,Controller'
        }
        It 'offers no tweaks without interfaces' {
            @(Get-RTTweaks -Context @{ Daws = @(); AudioDevices = @(); Interfaces = @() } | Where-Object { $_.Id -like 'usb.power.*' }).Count | Should Be 0
        }
    }
}
