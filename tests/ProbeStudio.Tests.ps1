# Pester 3.4. Probe history/comparison and studio mode. Nothing here changes system settings.

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Engine.psm1') -Force -DisableNameChecking

InModuleScope Engine {
    Describe 'Compare-RTProbe' {
        $rec = { param($stable, $per128, $secs = 10)
            [pscustomobject]@{ Timestamp = '2026-11-03T10:00:00'; Label = 'scan'; Seconds = $secs; StableBuffer = $stable
                               Buffers = @([pscustomobject]@{ Buffer = 128; PerMinute = $per128 }, [pscustomobject]@{ Buffer = 256; PerMinute = 0 }) } }
        It 'reports an improvement' {
            $c = Compare-RTProbe -Before (& $rec 256 24) -After (& $rec 128 0)
            $c.Verdict | Should Be 'Better'
            $c.Text | Should Match '256 samples -> 128 samples'
            $c.Text | Should Match '128: 24 -> 0'
        }
        It 'reports a regression, including to no stable buffer at all' {
            (Compare-RTProbe -Before (& $rec 128 0) -After (& $rec 256 30)).Verdict | Should Be 'Worse'
            (Compare-RTProbe -Before (& $rec 128 0) -After (& $rec $null 30)).Verdict | Should Be 'Worse'
            (Compare-RTProbe -Before (& $rec $null 30) -After (& $rec 512 30)).Verdict | Should Be 'Better'
        }
        It 'warns that short runs vary and that runs of different length are not comparable' {
            (Compare-RTProbe -Before (& $rec 256 24) -After (& $rec 128 0)).Text | Should Match 'Short runs vary'
            (Compare-RTProbe -Before (& $rec 256 24 10) -After (& $rec 256 2 300)).Text | Should Match 'different length'
        }
    }

    Describe 'Probe history' {
        It 'appends records, keeps the newest 50 and returns the previous one' {
            $script:ProbeHistoryPath = Join-Path $TestDrive 'history.json'
            $probe = [pscustomobject]@{ Seconds = 10; StableBuffer = 256; MaxMs = 1.2; P999Ms = 0.9; Buffers = @([pscustomobject]@{ Buffer = 64; PerMinute = 5 }) }
            Add-RTProbeHistory -Record (ConvertTo-RTProbeRecord -Probe $probe -Label 'first') | Should Be $null
            for ($i = 0; $i -lt 55; $i++) { $prev = Add-RTProbeHistory -Record (ConvertTo-RTProbeRecord -Probe $probe -Label "run $i") }
            $prev.Label | Should Be 'run 53'
            @(Get-RTProbeHistory).Count | Should Be 50
        }
    }

    Describe 'Invoke-RTRealtimeProbe cancel' {
        It 'stops early when asked and still returns a result' {
            $control = [hashtable]::Synchronized(@{ Cancel = $false })
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $p = Invoke-RTRealtimeProbe -Seconds 60 -Control $control -Progress { param($m) $control.Cancel = $true }
            $sw.Elapsed.TotalSeconds -lt 15 | Should Be $true
            $p.Ok | Should Be $true
            $p.Seconds -lt 60 | Should Be $true
        }
    }

    Describe 'Studio mode' {
        It 'has unique action ids with titles and reasons' {
            $a = @(Get-RTStudioActions)
            $a.Count -ge 5 | Should Be $true
            @($a | Group-Object Id | Where-Object Count -gt 1).Count | Should Be 0
            @($a | Where-Object { -not $_.Title -or -not $_.Why }).Count | Should Be 0
        }
        It 'keeps risky actions (Wi-Fi, Bluetooth) out of the defaults' {
            @(Get-RTStudioActions | Where-Object { $_.Default -and $_.Id -in 'studio.wifi', 'studio.bluetooth' }).Count | Should Be 0
        }
        It 'treats a missing or corrupt state file as off' {
            $script:StudioPath = Join-Path $TestDrive 'studio.json'
            $script:LogPath = Join-Path $TestDrive 'test.log'      # keep the expected error out of the real log
            Get-RTStudioState | Should Be $null
            Set-Content -Path $script:StudioPath -Value '{not json'
            Get-RTStudioState | Should Be $null
        }
        It 'round-trips its state' {
            $script:StudioPath = Join-Path $TestDrive 'studio2.json'
            $script:DataDir = $TestDrive
            Save-RTStudioState @{ StartedAt = 'now'; Actions = [ordered]@{ 'studio.indexing' = @{ WasRunning = $true } } }
            $s = Get-RTStudioState
            $s.Actions['studio.indexing'].WasRunning | Should Be $true
        }
        It 'refuses to start without administrator rights' -Skip:(Test-RTAdmin) {
            { Enable-RTStudioMode } | Should Throw
        }
    }
}
