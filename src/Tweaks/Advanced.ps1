# Defender exclusions and boot (BCD) timer settings. All opt-in or Aggressive-only.

function Get-RTDefenderCandidates {
    param($ctx)
    $paths = @(
        (Join-Path $env:CommonProgramFiles 'VST3'),
        (Join-Path $env:CommonProgramFiles 'CLAP'),
        (Join-Path $env:CommonProgramFiles 'Avid\Audio\Plug-Ins'),
        (Join-Path $env:ProgramFiles 'VSTPlugins'),
        (Join-Path $env:ProgramFiles 'Steinberg\VSTPlugins'),
        (Join-Path $env:ProgramFiles 'Common Files\Steinberg\VST2')
    )
    $paths += @($ctx.Daws | Where-Object { $_.InstallLocation } | ForEach-Object { $_.InstallLocation.TrimEnd('\') })
    @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)
}

Register-RTTweakProvider {
    param($ctx)
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mp -or -not $mp.RealTimeProtectionEnabled) { return }
    $paths = Get-RTDefenderCandidates $ctx
    if (-not $paths) { return }
    @{
        Id = 'defender.exclusions'; Category = 'Defender'; Risk = 'Moderate'; Presets = @(); Order = 80
        Title = "Exclude DAW and plugin folders from Defender real-time scanning ($($paths.Count) folders)"
        Why = "Defender scans every plugin DLL and file the DAW opens, which slows project loading and can cause hiccups. Trade-off: malware placed in these folders would not be scanned on access. Folders: $($paths -join '; ')"
        Params = @{ Paths = $paths }
        Test = {
            param($t)
            $pref = Get-MpPreference -ErrorAction SilentlyContinue
            $have = @($pref.ExclusionPath)
            if ($have -match '^N/A') { return New-RTTestResult 'Unknown' 'needs administrator rights to read' "$($t.Params.Paths.Count) folders" }
            $missing = @($t.Params.Paths | Where-Object { $have -notcontains $_ })
            New-RTTestResult -Status $(if ($missing) { 'NotOptimal' } else { 'Ok' }) -Current "$($t.Params.Paths.Count - $missing.Count) of $($t.Params.Paths.Count) excluded" -Desired 'all excluded'
        }
        Backup = {
            param($t)
            $have = @((Get-MpPreference).ExclusionPath)
            @{ Added = @($t.Params.Paths | Where-Object { $have -notcontains $_ }) }
        }
        Apply = {
            param($t)
            $have = @((Get-MpPreference).ExclusionPath)
            $missing = @($t.Params.Paths | Where-Object { $have -notcontains $_ })
            if ($missing) { Add-MpPreference -ExclusionPath $missing }
        }
        Revert = { param($t, $state) $added = @($state.Added | Where-Object { $_ }); if ($added) { Remove-MpPreference -ExclusionPath $added } }
    }
}

function Get-RTBcdValue {
    # bcdedit element names are not localized; reading needs administrator rights.
    param([string]$Name)
    $out = bcdedit /enum '{current}' 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Available = $false; Present = $false; Value = $null } }
    $line = $out | Where-Object { $_ -match "^$Name\s+(\S+)" } | Select-Object -First 1
    [pscustomobject]@{ Available = $true; Present = [bool]$line; Value = $(if ($line -match "^$Name\s+(\S+)") { $Matches[1] }) }
}

function ConvertTo-RTBcdBool { param([string]$Value) if ($Value -match '^(Yes|Ja|Oui|S.|true|on|1)$') { 'yes' } else { 'no' } }

Register-RTTweak @{
    Id = 'boot.platform-clock'; Category = 'Boot / timers'; Risk = 'Moderate'; Presets = @('Recommended'); Reboot = $true
    Title = 'Remove forced HPET (bcdedit useplatformclock)'
    Why = 'Forcing the HPET as the only clock source (an old "tweak") makes every timer read slow and usually increases latency. Windows picks the best clock by itself.'
    Test = {
        param($t)
        $v = Get-RTBcdValue 'useplatformclock'
        if (-not $v.Available) { return New-RTTestResult 'Unknown' 'needs administrator rights to read' 'not set' }
        if (-not $v.Present) { return New-RTTestResult 'Ok' 'not set' 'not set' }
        New-RTTestResult 'NotOptimal' "useplatformclock $($v.Value)" 'not set'
    }
    Backup = { param($t) $v = Get-RTBcdValue 'useplatformclock'; @{ Present = $v.Present; Value = $v.Value } }
    Apply  = { param($t) bcdedit /deletevalue '{current}' useplatformclock | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'bcdedit /deletevalue failed' } }
    Revert = { param($t, $state) if ($state.Present) { bcdedit /set '{current}' useplatformclock (ConvertTo-RTBcdBool $state.Value) | Out-Null } }
}

Register-RTTweak @{
    Id = 'boot.dynamic-tick'; Category = 'Boot / timers'; Risk = 'Advanced'; Presets = @('Aggressive'); Reboot = $true
    Title = 'Disable dynamic tick (bcdedit disabledynamictick yes)'
    Why = 'Keeps the system timer ticking regularly instead of pausing it when idle. Can smooth out latency on some systems, at the cost of idle power. Test with LatencyMon before and after; revert if it does not help.'
    Test = {
        param($t)
        $v = Get-RTBcdValue 'disabledynamictick'
        if (-not $v.Available) { return New-RTTestResult 'Unknown' 'needs administrator rights to read' 'yes' }
        $on = $v.Present -and (ConvertTo-RTBcdBool $v.Value) -eq 'yes'
        New-RTTestResult -Status $(if ($on) { 'Ok' } else { 'NotOptimal' }) -Current $(if ($v.Present) { $v.Value } else { 'not set' }) -Desired 'yes'
    }
    Backup = { param($t) $v = Get-RTBcdValue 'disabledynamictick'; @{ Present = $v.Present; Value = $v.Value } }
    Apply  = { param($t) bcdedit /set '{current}' disabledynamictick yes | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'bcdedit /set failed' } }
    Revert = {
        param($t, $state)
        if ($state.Present) { bcdedit /set '{current}' disabledynamictick (ConvertTo-RTBcdBool $state.Value) | Out-Null }
        else { bcdedit /deletevalue '{current}' disabledynamictick | Out-Null }
    }
}
