# Pester 3.4. Tests for System.ps1 (memory, firmware age), VendorApps.ps1 and Plugins.ps1.
# Pure functions are fed fake data; nothing here needs admin rights or changes the system.

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Engine.psm1') -Force -DisableNameChecking

InModuleScope Engine {
    function New-Mod { param($Gb = 16, $Speed = 3200, $Conf = 3200, $Type = 26, $Ff = 8)
        [pscustomobject]@{ Capacity = [uint64]$Gb * 1GB; Speed = $Speed; ConfiguredClockSpeed = $Conf; SMBIOSMemoryType = $Type; FormFactor = $Ff } }
    function Ids { param($f) (@($f | Where-Object { $_ }) | ForEach-Object { $_.Id }) -join ',' }

    Describe 'Get-RTMemoryFindings' {
        It 'flags one desktop DIMM as likely single-channel' {
            $f = @(Get-RTMemoryFindings -Modules @(New-Mod) -IsLaptop $false)
            Ids $f | Should Be 'mem.single-channel'
            $f[0].Title | Should Match 'Likely single-channel'
        }
        It 'softens the wording on laptops' {
            $f = @(Get-RTMemoryFindings -Modules @(New-Mod -Ff 12) -IsLaptop $true)
            $f[0].Title | Should Match 'Possibly'
            $f[0].Advice | Should Match 'soldered'
        }
        It 'does not flag two modules' {
            Ids (Get-RTMemoryFindings -Modules @((New-Mod), (New-Mod)) -IsLaptop $false) | Should Be ''
        }
        It 'does not flag soldered LPDDR5 or a single CAMM (proprietary form factor) module' {
            Ids (Get-RTMemoryFindings -Modules @(New-Mod -Type 35 -Ff 12 -Speed 6400 -Conf 6400) -IsLaptop $true) | Should Be ''
            Ids (Get-RTMemoryFindings -Modules @(New-Mod -Type 34 -Ff 6 -Speed 5600 -Conf 5600 -Gb 64) -IsLaptop $true) | Should Be ''
        }
        It 'reports configured speed below rated speed' {
            $f = @(Get-RTMemoryFindings -Modules @((New-Mod -Speed 3600 -Conf 3200), (New-Mod -Speed 3600 -Conf 3200)) -IsLaptop $false)
            Ids $f | Should Be 'mem.speed'
            $f[0].Title | Should Be 'RAM runs at 3200 MT/s but is rated 3600 MT/s'
        }
        It 'explains on laptops that the speed is usually fixed' {
            $f = @(Get-RTMemoryFindings -Modules @(New-Mod -Type 34 -Ff 6 -Speed 5600 -Conf 5200) -IsLaptop $true)
            Ids $f | Should Be 'mem.speed'
            $f[0].Advice | Should Match 'by design'
        }
        It 'suggests XMP/EXPO for desktop DDR4 at 2400 or less and DDR5 at 4800 or less' {
            Ids (Get-RTMemoryFindings -Modules @((New-Mod -Speed 2133 -Conf 2133), (New-Mod -Speed 2133 -Conf 2133)) -IsLaptop $false) | Should Be 'mem.xmp'
            Ids (Get-RTMemoryFindings -Modules @((New-Mod -Type 34 -Speed 4800 -Conf 4800), (New-Mod -Type 34 -Speed 4800 -Conf 4800)) -IsLaptop $false) | Should Be 'mem.xmp'
            Ids (Get-RTMemoryFindings -Modules @((New-Mod -Type 34 -Speed 6000 -Conf 6000), (New-Mod -Type 34 -Speed 6000 -Conf 6000)) -IsLaptop $false) | Should Be ''
        }
        It 'never suggests XMP on laptops' {
            Ids (Get-RTMemoryFindings -Modules @((New-Mod -Ff 12 -Speed 2400 -Conf 2400), (New-Mod -Ff 12 -Speed 2400 -Conf 2400)) -IsLaptop $true) | Should Be ''
        }
        It 'returns nothing without modules' {
            Ids (Get-RTMemoryFindings -Modules @() -IsLaptop $false) | Should Be ''
        }
    }

    Describe 'Get-RTFirmwareFindings' {
        $now = [datetime]'2026-11-01'
        function Dev { param($Name, $Date, $Provider = 'Intel') [pscustomobject]@{ Name = $Name; InstanceId = 'PCI\VEN_8086'; DriverVersion = '1.0'; DriverProvider = $Provider; DriverDate = $Date } }
        It 'reports an old BIOS, GPU driver and network driver' {
            $f = @(Get-RTFirmwareFindings -Now $now -Facts @{
                Bios        = [pscustomobject]@{ Version = '1.2'; Manufacturer = 'ACME'; ReleaseDate = [datetime]'2020-05-10' }
                Gpus        = @(Dev 'GPU A' ([datetime]'2024-01-01'))
                NetAdapters = @(Dev 'Wi-Fi X' ([datetime]'2021-01-01'))
            })
            Ids $f | Should Be 'fw.bios,fw.gpu.GPU A,fw.net.Wi-Fi X'
            $f[0].Title | Should Be 'BIOS from 2020-05'
            $f[0].GuideId | Should Be 'bios'
            $f[1].GuideId | Should Be 'gpu'
            $f[2].GuideId | Should Be 'latencymon'
        }
        It 'stays quiet for current firmware and drivers' {
            Ids (Get-RTFirmwareFindings -Now $now -Facts @{
                Bios        = [pscustomobject]@{ Version = '1'; Manufacturer = 'ACME'; ReleaseDate = [datetime]'2025-01-01' }
                Gpus        = @(Dev 'GPU A' ([datetime]'2025-12-01'))
                NetAdapters = @(Dev 'LAN' ([datetime]'2024-01-01'))
            }) | Should Be ''
        }
        It 'ignores Microsoft inbox network drivers and missing dates' {
            Ids (Get-RTFirmwareFindings -Now $now -Facts @{
                Bios = $null; Gpus = @(Dev 'GPU' $null)
                NetAdapters = @((Dev 'Inbox' ([datetime]'2006-06-21') 'Microsoft'), (Dev 'NoDate' $null))
            }) | Should Be ''
        }
        It 'reports a GPU on the Microsoft fallback driver instead of its date' {
            Ids (Get-RTFirmwareFindings -Now $now -Facts @{
                Bios = $null; NetAdapters = @(); Gpus = @(Dev 'Basic Display' ([datetime]'2006-06-21') 'Microsoft')
            }) | Should Be 'fw.gpu.basic.Basic Display'
        }
    }

    Describe 'Test-RTPhysicalDeviceId' {
        It 'accepts bus devices and rejects software devices' {
            Test-RTPhysicalDeviceId 'PCI\VEN_8086&DEV_7A70\3&1' | Should Be $true
            Test-RTPhysicalDeviceId 'USB\VID_0BDA&PID_8156\01' | Should Be $true
            Test-RTPhysicalDeviceId 'ROOT\DISPLAY\0000' | Should Be $false
            Test-RTPhysicalDeviceId 'SWD\MSRRAS\MS_NDISWANIP' | Should Be $false
            Test-RTPhysicalDeviceId 'BTH\MS_BTHPAN\6&1' | Should Be $false
            Test-RTPhysicalDeviceId '{5D624F94-8850-40C3-A3FA-A4FD2080BAF3}\VWIFIMP_WFD\4&1' | Should Be $false
        }
    }

    Describe 'Vendor apps' {
        function Iface { param($Name, $Vendor, $Enabled = $true) [pscustomobject]@{ Name = $Name; KnownVendor = $Vendor; Enabled = $Enabled } }
        It 'uses only vendor names that exist in VendorProfiles' {
            $bad = @($script:VendorApps | ForEach-Object { $_.Vendor } | Where-Object { -not $script:VendorProfiles.Contains($_) })
            ($bad -join ',') | Should Be ''
        }
        It 'picks the model-specific entry before the vendor default' {
            (Get-RTVendorAppEntry -Interface (Iface 'Vocaster Two' 'Focusrite')).App | Should Be 'Vocaster Hub'
            (Get-RTVendorAppEntry -Interface (Iface 'Focusrite USB Audio' 'Focusrite')).App | Should Be 'Focusrite Control'
            (Get-RTVendorAppEntry -Interface (Iface 'Universal Audio Apollo Twin' 'Universal Audio')).Required | Should Be $true
            (Get-RTVendorAppEntry -Interface (Iface 'Volt 2' 'Universal Audio')).App | Should Be 'UA Connect'
            Get-RTVendorAppEntry -Interface (Iface 'Steinberg UR22mkII' 'Yamaha / Steinberg') | Should Be $null
            (Get-RTVendorAppEntry -Interface (Iface 'Steinberg UR22C' 'Yamaha / Steinberg')).App | Should Be 'dspMixFx'
            Get-RTVendorAppEntry -Interface (Iface 'Fireface UCX II' 'RME') | Should Be $null
            Get-RTVendorAppEntry -Interface (Iface 'USB Audio' '') | Should Be $null
        }
        It 'reports a missing app as Info, once per app' {
            $f = @(Get-RTVendorAppFindings -Interfaces @((Iface 'Focusrite USB Audio' 'Focusrite'), (Iface 'Clarett+ 8Pre' 'Focusrite')) -Installed @('Some App'))
            Ids $f | Should Be 'vendorapp.missing.Focusrite Control'
            $f[0].Severity | Should Be 'Info'
            $f[0].Detail | Should Be 'For: Focusrite USB Audio, Clarett+ 8Pre'
        }
        It 'warns when the Apollo console software is missing' {
            $f = @(Get-RTVendorAppFindings -Interfaces @(Iface 'Universal Audio Apollo Twin X' 'Universal Audio') -Installed @())
            $f[0].Severity | Should Be 'Warning'
        }
        It 'reports Ok when the app is installed and ignores disabled interfaces' {
            $f = @(Get-RTVendorAppFindings -Interfaces @((Iface 'Studio 1824c' 'PreSonus'), (Iface 'MiniFuse 2' 'Arturia' $false)) -Installed @('PreSonus Universal Control'))
            Ids $f | Should Be 'vendorapp.ok.Universal Control'
            $f[0].Severity | Should Be 'Ok'
        }
    }

    Describe 'Get-RTPluginCount' {
        It 'counts .vst3 bundles once and respects the depth limit' {
            $base = Join-Path $TestDrive 'VST3'
            New-Item -ItemType Directory -Path (Join-Path $base 'Vendor\Synth.vst3\Contents\x86_64-win') -Force | Out-Null
            Set-Content (Join-Path $base 'Vendor\Synth.vst3\Contents\x86_64-win\Synth.vst3') 'x'
            Set-Content (Join-Path $base 'Flat.vst3') 'x'
            Set-Content (Join-Path $base 'readme.txt') 'x'
            New-Item -ItemType Directory -Path (Join-Path $base 'a\b\c\d\e') -Force | Out-Null
            Set-Content (Join-Path $base 'a\b\c\d\e\Deep.vst3') 'x'
            Get-RTPluginCount -Path $base -Extension '.vst3' -MaxDepth 4 | Should Be 2
            Get-RTPluginCount -Path $base -Extension '.vst3' -MaxDepth 5 | Should Be 3
        }
        It 'returns 0 for a missing folder' {
            Get-RTPluginCount -Path (Join-Path $TestDrive 'nope') -Extension '.dll' | Should Be 0
        }
    }

    Describe 'Get-RTPluginFolderSpecs' {
        It 'never uses localized folder names and covers both VST3 folders' {
            $specs = @(Get-RTPluginFolderSpecs)
            @($specs | Where-Object { $_.Kind -eq 'VST3' -and $_.Bits -eq 64 }).Count | Should Be 1
            @($specs | Where-Object { $_.Path -notmatch '^[A-Za-z]:\\|^\\\\' }).Count | Should Be 0
        }
    }

    Describe 'Get-RTPluginFindings' {
        function Folder { param($Path, $Kind = 'VST3', $Bits = 64, $Count = 5, $Name = '') @{ Path = $Path; Target = $Path; Kind = $Kind; Bits = $Bits; Count = $Count; Name = $Name } }
        $ssd = @{ MediaType = 'SSD'; BusType = 'NVMe'; Name = 'Fast' }
        $hdd = @{ MediaType = 'HDD'; BusType = 'SATA'; Name = 'Slow' }
        $usbHdd = @{ MediaType = 'HDD'; BusType = 'USB'; Name = 'Portable' }
        $usbSsd = @{ MediaType = 'Unspecified'; BusType = 'USB'; Name = 'T7' }
        It 'counts 32-bit plugins' {
            $f = @(Get-RTPluginFindings -Folders @((Folder 'C:\Program Files\Common Files\VST3'), (Folder 'C:\x86\VST3' 'VST3' 32 3), (Folder 'C:\x86\VSTPlugins' 'VST2' 32 4), (Folder 'C:\x86\Empty' 'VST2' 32 0)) -Drives @{ C = $ssd })
            Ids $f | Should Be 'plugins.32bit'
            $f[0].Title | Should Be '7 32-bit plugin file(s) found'
        }
        It 'is quiet when everything is on an internal SSD' {
            Ids (Get-RTPluginFindings -Folders @((Folder 'C:\VST3'), (Folder 'C:\Libs\Strings' 'Library' 0 0 'Strings')) -Drives @{ C = $ssd }) | Should Be ''
        }
        It 'groups plugin folders and libraries per slow drive' {
            $f = @(Get-RTPluginFindings -Drives @{ C = $ssd; D = $hdd; E = $usbHdd; F = $usbSsd } -Folders @(
                (Folder 'D:\VST2' 'VST2' 64 10),
                (Folder 'D:\Samples\Piano' 'Library' 0 0 'Piano'),
                (Folder 'E:\Kontakt\Choir' 'Library' 0 0 'Choir'),
                (Folder 'F:\Libs\Drums' 'Library' 0 0 'Drums'),
                (Folder 'D:\EmptyVst' 'VST2' 64 0)))
            Ids $f | Should Be 'plugins.drive.D,plugins.drive.E,plugins.drive.F'
            $f[0].Title | Should Be 'Plugin folders and sample libraries on a hard disk (HDD) (drive D:)'
            $f[0].Severity | Should Be 'Info'
            $f[1].Severity | Should Be 'Warning'
            $f[1].Title | Should Match 'external USB hard disk'
            $f[2].Severity | Should Be 'Info'
            $f[2].Title | Should Match 'USB drive'
        }
        It 'warns for plugins on a USB drive and for network shares' {
            $f = @(Get-RTPluginFindings -Drives @{ F = $usbSsd } -Folders @((Folder 'F:\VST3'), (Folder '\\nas\samples\Lib' 'Library' 0 0 'Lib')))
            Ids $f | Should Be 'plugins.drive.F,plugins.drive.UNC'
            @($f | Where-Object Severity -ne 'Warning').Count | Should Be 0
        }
        It 'ignores drives it could not resolve' {
            Ids (Get-RTPluginFindings -Folders @(Folder 'Z:\VST3') -Drives @{}) | Should Be ''
        }
    }
}
