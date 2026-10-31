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

Describe 'Safety' {
    It 'refuses to apply without administrator rights' -Skip:(Test-RTAdmin) {
        { Invoke-RTApply -Ids 'power.usb-suspend' } | Should Throw
    }
    It 'rejects unknown tweak ids' {
        { Invoke-RTApply -Ids 'does.not.exist' -DryRun } | Should Throw
    }
}
