# Pester 3.4 compatible (ships with Windows PowerShell 5.1). Run: Invoke-Pester .\tests
# Nothing here needs administrator rights or changes system settings; registry tests use HKCU:\Software\RTAudioTest.

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Engine.psm1') -Force -DisableNameChecking

Describe 'Source files' {
    It 'are ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI)' {
        $bad = Get-ChildItem (Join-Path $root '*') -Recurse -Include *.ps1, *.psm1 |
            Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1 } |
            ForEach-Object Name
        ($bad -join ', ') | Should Be ''
    }
}

Describe 'ConvertFrom-RTPowercfgQuery' {
    It 'parses German output of a list setting' {
        $lines = @(
            'GUID des Energieschemas: a6c72b1a-e3fc-4f8a-a52d-fef492beeb67  (Hoechstleistung)',
            '    GUID der Energieeinstellung: 48e6b7a6-50f5-4782-a5d4-53bb8f07e226  (USB)',
            '      Index der moeglichen Einstellung: 000',
            '      Index der moeglichen Einstellung: 001',
            '    Index der aktuellen Wechselstromeinstellung: 0x00000001',
            '    Index der aktuellen Gleichstromeinstellung: 0x00000000')
        $r = ConvertFrom-RTPowercfgQuery $lines
        $r.AC | Should Be 1
        $r.DC | Should Be 0
    }
    It 'ignores min/max lines of a range setting' {
        $lines = @(
            '      Minimum Possible Setting: 0x00000000',
            '      Maximum Possible Setting: 0x00000064',
            '      Possible Settings increment: 0x00000001',
            '      Possible Settings units: %',
            '    Current AC Power Setting Index: 0x00000064',
            '    Current DC Power Setting Index: 0x00000005')
        $r = ConvertFrom-RTPowercfgQuery $lines
        $r.AC | Should Be 100
        $r.DC | Should Be 5
    }
    It 'returns null for unrelated output' {
        ConvertFrom-RTPowercfgQuery @('Invalid parameters') | Should Be $null
    }
}

InModuleScope Engine {
    Describe 'Get-RTAudioDeviceType' {
        $cases = @(
            @{ Name = 'Focusrite USB Audio'; Id = 'USB\VID_1235&PID_8210&MI_00\6&1'; Type = 'Interface' },
            @{ Name = 'Some Device'; Id = 'USB\VID_0499&PID_1718&MI_00\6&2'; Type = 'Interface' },
            @{ Name = 'Line (Babyface Pro)'; Id = 'USB\VID_FFFF&PID_0001\X'; Type = 'Interface' },
            @{ Name = 'NVIDIA High Definition Audio'; Id = 'HDAUDIO\FUNC_01&VEN_10DE&DEV_00A0&SUBSYS_10DE0000&REV_1001\5&1'; Type = 'Display' },
            @{ Name = 'HD Audio Driver for Display Audio'; Id = 'INTELAUDIO\SGPC_FUNC_01&VEN_8086&DEV_2818&SUBSYS_80860101&REV_1000\5&1'; Type = 'Display' },
            @{ Name = 'Intel Smart Sound'; Id = 'INTELAUDIO\CTLR_DEV_7A50&LINKTYPE_06&DEVTYPE_06&VEN_8086&DEV_AE50\0602'; Type = 'Controller' },
            @{ Name = 'Realtek(R) Audio'; Id = 'INTELAUDIO\FUNC_01&VEN_10EC&DEV_0289&SUBSYS_10280C41&REV_1000\5&1'; Type = 'Onboard' },
            @{ Name = 'MOMENTUM 4'; Id = 'BTHENUM\{0000110B-0000-1000-8000-00805F9B34FB}_LOCALMFG&0002\7&1'; Type = 'Bluetooth' },
            @{ Name = 'BRIO 4K Stream Edition'; Id = 'USB\VID_046D&PID_086B&MI_02\D&1'; Type = 'UsbOther' },
            @{ Name = 'NVIDIA Broadcast'; Id = 'ROOT\UNNAMED_DEVICE\0000'; Type = 'Virtual' }
        )
        foreach ($c in $cases) {
            It "classifies '$($c.Name)' as $($c.Type)" {
                Get-RTAudioDeviceType -Name $c.Name -InstanceId $c.Id | Should Be $c.Type
            }
        }
    }

    Describe 'Registry tweak kind' {
        $key = 'HKCU:\Software\RTAudioTest'
        BeforeEach {
            Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue
            New-Item $key -Force | Out-Null
            New-ItemProperty $key -Name Existing -Value 5 -PropertyType DWord | Out-Null
        }
        AfterEach { Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue }

        $tweak = Complete-RTTweak @{
            Id = 'test.reg'; Category = 'Test'; Title = 'Test'; Why = 'Test'; Risk = 'Safe'; Kind = 'Registry'
            Params = @{ Values = @(@{ Path = $key; Name = 'Existing'; Value = 1 }, @{ Path = $key; Name = 'Missing'; Value = -1 }) }
        }

        It 'detects, applies and reverts through a JSON round trip of the backup' {
            (Test-RTTweak $tweak).Status | Should Be 'NotOptimal'
            $state = & $tweak.Backup $tweak
            # The ledger stores state as JSON; revert must work on what comes back.
            $restored = ConvertTo-RTHashtable (ConvertFrom-Json (ConvertTo-Json -InputObject @{ s = $state } -Depth 10))
            & $tweak.Apply $tweak
            (Test-RTTweak $tweak).Status | Should Be 'Ok'
            (Get-RTRegValue $key 'Missing').Value | Should Be -1
            Test-RTRegValueEqual ([uint32]::MaxValue) -1 | Should Be $true
            Test-RTRegValueEqual '10' 10 | Should Be $true
            Test-RTRegValueEqual 2 24 | Should Be $false
            & $tweak.Revert $tweak $restored.s
            (Get-ItemProperty $key).Existing | Should Be 5
            (Get-Item $key).GetValueNames() -contains 'Missing' | Should Be $false
        }
    }

    Describe 'Ledger' {
        It 'round-trips nested state' {
            $script:LedgerPath = Join-Path $TestDrive 'ledger.json'
            $script:DataDir = $TestDrive
            Save-RTLedger @{ 'a.b' = @{ Title = 'T'; State = @(@{ Path = 'HKCU:\x'; Existed = $false; Value = $null }) } }
            $l = Read-RTLedger
            $l['a.b'].Title | Should Be 'T'
            @($l['a.b'].State)[0].Existed | Should Be $false
        }
    }

    Describe 'Get-RTInterfaceVendor' {
        It 'uses the USB vendor ID first' { Get-RTInterfaceVendor -Name 'USB Audio' -InstanceId 'USB\VID_1235&PID_8210\1' | Should Be 'Focusrite' }
        It 'falls back to the name for Thunderbolt/PCIe devices' { Get-RTInterfaceVendor -Name 'Universal Audio Apollo Twin X' -InstanceId 'PCI\VEN_1234&DEV_0001\1' | Should Be 'Universal Audio' }
        It 'returns empty for unknown devices' { Get-RTInterfaceVendor -Name 'Mystery Box' -InstanceId 'USB\VID_FFFF&PID_0001\1' | Should Be '' }
    }

    Describe 'Get-RTAsioFindings' {
        $ok = @{ Dll = 'x.dll'; DllExists = $true }
        $drv = { param($name, $views = @{ 64 = $ok; 32 = $ok }) New-RTAsioDriver -Name $name -Views $views }
        $iface = { param($name, $vendor) [pscustomobject]@{ Name = $name; KnownVendor = $vendor; Enabled = $true } }
        $ids = { param($f) @($f | ForEach-Object Id) }

        It 'confirms a matching vendor driver' {
            $f = Get-RTAsioFindings -Interfaces @(& $iface 'Scarlett 2i2' 'Focusrite') -Drivers @(& $drv 'Focusrite USB ASIO')
            & $ids $f | Should Be 'asio.match.Scarlett 2i2'
        }
        It 'flags a driver of another brand as mismatch and as leftover' {
            $f = Get-RTAsioFindings -Interfaces @(& $iface 'UMC404HD' 'Behringer') -Drivers @(& $drv 'Focusrite USB ASIO')
            $i = & $ids $f
            $i -contains 'asio.mismatch.UMC404HD' | Should Be $true
            $i -contains 'asio.orphans' | Should Be $true
        }
        It 'does not treat FL Studio ASIO as a PreSonus driver' {
            $f = Get-RTAsioFindings -Interfaces @(& $iface 'Studio 24c' 'PreSonus') -Drivers @(& $drv 'FL Studio ASIO')
            & $ids $f | Should Be 'asio.generic.Studio 24c'
        }
        It 'warns that a generic driver sits next to the matching one' {
            $f = Get-RTAsioFindings -Interfaces @(& $iface 'Babyface Pro' 'RME') -Drivers @((& $drv 'ASIO Babyface Pro'), (& $drv 'ASIO4ALL v2'))
            (& $ids $f) -contains 'asio.alsogeneric.Babyface Pro' | Should Be $true
        }
        It 'cannot verify an interface of unknown vendor and does not call its driver a leftover' {
            $f = Get-RTAsioFindings -Interfaces @(& $iface 'Mystery Box' '') -Drivers @(& $drv 'Mystery ASIO')
            & $ids $f | Should Be 'asio.unverified.Mystery Box'
        }
        It 'reports registry entries whose DLL is missing, and 32-bit-only drivers' {
            $f = Get-RTAsioFindings -Interfaces @() -Drivers @(
                (& $drv 'MOTU Pro Audio' @{ 64 = @{ Dll = 'gone.dll'; DllExists = $false } }),
                (& $drv 'Old TASCAM ASIO' @{ 32 = $ok }))
            $i = & $ids $f
            $i -contains 'asio.broken.MOTU Pro Audio' | Should Be $true
            $i -contains 'asio.32bit.Old TASCAM ASIO' | Should Be $true
        }
        It 'does not accept a 32-bit-only vendor driver as a match' {
            $f = Get-RTAsioFindings -Interfaces @(& $iface 'Scarlett 2i2' 'Focusrite') -Drivers @(& $drv 'Focusrite USB ASIO' @{ 32 = $ok })
            (& $ids $f) -contains 'asio.match.Scarlett 2i2' | Should Be $false
        }
        It 'reports no ASIO driver at all' {
            & $ids (Get-RTAsioFindings -Interfaces @() -Drivers @()) | Should Be 'asio.none'
        }
    }

    Describe 'Measure-RTBufferStalls' {
        It 'counts consecutive late callbacks as one stall and scales thresholds with the buffer' {
            # 64 samples @48k = 1.33 ms -> 50% headroom 0.67 ms; 128 -> 1.33 ms; 256 -> 2.67 ms
            $d = [float[]]@(0, 0.1, 0.9, 0.8, 0, 1.5, 0.2, 3.0, 2.0, 0)
            $r = @(Measure-RTBufferStalls -DelaysMs $d -Seconds 60 -Buffers 64, 128, 256)
            $r[0].Stalls | Should Be 3
            $r[1].Stalls | Should Be 2
            $r[2].Stalls | Should Be 1
            $r[2].PerMinute | Should Be 1
        }
    }

    Describe 'Get-RTReadiness' {
        $goodHw = @{ Cpu = @{ Name = 'CPU'; Cores = 8; Threads = 16; Hybrid = $false }; RamGB = 32
                     SystemDisk = @{ Name = 'SSD'; MediaType = 'SSD'; BusType = 'NVMe' }; FreePct = 50; IsLaptop = $false; OnBattery = $false }
        $iface = @([pscustomobject]@{ Name = 'Scarlett 2i2'; Enabled = $true })
        $probe = { param($stable) [pscustomobject]@{ Ok = $true; StableBuffer = $stable; MaxMs = 0.5; Buffers = @() } }
        $facts = { param($hw, $p, $ifaces = $iface) @{ Hardware = $hw; Interfaces = $ifaces; VendorAsio = $true; AnyAsio = $true; ClassDriverOnly = $false; Probe = $p; OpenTweaks = 0; Throttled = $false } }

        It 'rates a well-equipped, tuned PC as suitable' {
            $r = Get-RTReadiness (& $facts $goodHw (& $probe 128))
            $r.Level | Should Be 'Suitable'
            $r.StableBuffer | Should Be 128
            @($r.Areas | Where-Object Rating -ne 'Good').Count | Should Be 0
        }
        It 'limits a PC without an audio interface' {
            (Get-RTReadiness (& $facts $goodHw (& $probe 128) @())).Level | Should Be 'Limited'
        }
        It 'limits a PC that only runs stable at large buffers' {
            (Get-RTReadiness (& $facts $goodHw (& $probe 512))).Level | Should Be 'Limited'
        }
        It 'rejects a PC that stalls at every buffer size or has a hardware limit' {
            (Get-RTReadiness (& $facts $goodHw (& $probe $null))).Level | Should Be 'NotSuitable'
            $weak = $goodHw.Clone(); $weak.RamGB = 4
            (Get-RTReadiness (& $facts $weak (& $probe 128))).Level | Should Be 'NotSuitable'
        }
        It 'treats missing vendor ASIO and battery power as fixable setup issues' {
            $f = & $facts ($goodHw.Clone()) (& $probe 128)
            $f.VendorAsio = $false; $f.Hardware.OnBattery = $true; $f.Hardware.IsLaptop = $true
            $r = Get-RTReadiness $f
            $r.Level | Should Be 'Suitable'
            ($r.Areas | Where-Object Area -eq 'Audio driver').Rating | Should Be 'Poor'
            ($r.Areas | Where-Object Area -eq 'Power').Kind | Should Be 'Setup'
            $r.Summary | Should Match 'fixable'
        }
        It 'works without a probe result' {
            $r = Get-RTReadiness (& $facts $goodHw $null)
            ($r.Areas | Where-Object Area -eq 'Real-time performance').Rating | Should Be 'Unknown'
        }
    }

    Describe 'Tweak validation' {
        It 'rejects an invalid risk' {
            { Complete-RTTweak @{ Id = 'x'; Category = 'c'; Title = 't'; Why = 'w'; Risk = 'Yolo'; Kind = 'Registry'; Params = @{ Values = @() } } } | Should Throw
        }
        It 'rejects a custom tweak without scriptblocks' {
            { Complete-RTTweak @{ Id = 'x'; Category = 'c'; Title = 't'; Why = 'w'; Risk = 'Safe' } } | Should Throw
        }
    }
}

Describe 'Catalog' {
    $tweaks = Get-RTTweaks
    It 'has unique ids' {
        @($tweaks | Group-Object { $_.Id } | Where-Object Count -gt 1).Count | Should Be 0
    }
    It 'runs the power plan before power settings' {
        $plan = $tweaks | Where-Object { $_.Id -eq 'power.plan' }
        @($tweaks | Where-Object { $_.Kind -eq 'PowerSetting' -and $_.Order -le $plan.Order }).Count | Should Be 0
    }
    It 'has cumulative presets (Safe within Recommended within Aggressive)' {
        $safe = Get-RTPresetIds -Preset Safe; $rec = Get-RTPresetIds -Preset Recommended; $agg = Get-RTPresetIds -Preset Aggressive
        @($safe | Where-Object { $rec -notcontains $_ }).Count | Should Be 0
        @($rec | Where-Object { $agg -notcontains $_ }).Count | Should Be 0
        $safe.Count -gt 0 | Should Be $true
    }
    It 'offers DAW-specific tweaks only when the DAW is installed' {
        $none = Get-RTTweaks -Context @{ Daws = @(); AudioDevices = @(); Interfaces = @() }
        $fl = Get-RTTweaks -Context @{ Daws = @([pscustomobject]@{ Name = 'FL Studio'; InstallLocation = '' }); AudioDevices = @(); Interfaces = @() }
        @($none | Where-Object { $_.Id -eq 'daw.flstudio-priority' }).Count | Should Be 0
        @($fl | Where-Object { $_.Id -eq 'daw.flstudio-priority' }).Count | Should Be 1
    }
    It 'keeps Advanced tweaks out of Safe and Recommended' {
        @($tweaks | Where-Object { $_.Risk -eq 'Advanced' -and ($_.Presets -contains 'Safe' -or $_.Presets -contains 'Recommended') }).Count | Should Be 0
    }
}

Describe 'Guide' {
    $pages = Get-Content -Raw (Join-Path $root 'src\Guide\guide.json') | ConvertFrom-Json
    It 'has unique page ids' {
        @($pages | Group-Object id | Where-Object Count -gt 1).Count | Should Be 0
    }
    It 'only references whitelisted actions' {
        $unknown = @($pages | Where-Object { $_.PSObject.Properties['actions'] } | ForEach-Object { $_.actions } | Where-Object { -not (Get-RTGuideAction $_) })
        ($unknown -join ', ') | Should Be ''
    }
    It 'has a page for every GuideId used by the checks' {
        $ids = Select-String -Path (Join-Path $root 'src\Detect\*.ps1') -Pattern "-GuideId '([^']+)'" -AllMatches |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $missing = @($ids | Where-Object { @($pages.id) -notcontains $_ })
        ($missing -join ', ') | Should Be ''
    }
    It 'has a page for every detected DAW' {
        InModuleScope Engine {
            $missing = foreach ($d in $script:DawPatterns.Keys) {
                $id = 'daw-' + ($d -replace '[^A-Za-z0-9]', '').ToLower()
                $page = Get-RTGuide -All -Context @{ Daws = @() } | Where-Object id -eq $id
                if (-not $page) { $id }
            }
            ($missing -join ', ') | Should Be ''
        }
    }
}

Describe 'Invoke-RTRealtimeProbe' {
    It 'runs without administrator rights and reports every buffer size' {
        $p = Invoke-RTRealtimeProbe -Seconds 2
        $p.Ok | Should Be $true
        $p.Callbacks -gt 1000 | Should Be $true
        @($p.Buffers).Count | Should Be 5
        $p.MaxMs -ge $p.MedianMs | Should Be $true
    }
}

Describe 'Safety' {
    It 'refuses to apply without administrator rights' -Skip:(Test-RTAdmin) {
        { Invoke-RTApply -Ids 'power.usb-suspend' } | Should Throw
    }
    It 'rejects unknown tweak ids' {
        { Invoke-RTApply -Ids 'does.not.exist' -DryRun } | Should Throw
    }
}
