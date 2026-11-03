#Requires -Version 5.1
<#
.SYNOPSIS
    RTAudio Setup - tune Windows for real-time audio (FL Studio, Cubase, Ableton, ...).

.DESCRIPTION
    Without arguments the GUI starts (elevating via UAC). With arguments it runs headless:

      .\RTAudio.ps1 -QuickCheck                       (GUI, read-only, no elevation)
      .\RTAudio.ps1 -Check [-ProbeSeconds 15] [-Report report.html]
      .\RTAudio.ps1 -Scan [-LatencySeconds 20] [-ProbeSeconds 10] [-Report report.html]
      .\RTAudio.ps1 -List
      .\RTAudio.ps1 -Preset Recommended [-DryRun] [-NoRestorePoint]
      .\RTAudio.ps1 -Apply power.plan,power.usb-suspend [-DryRun]
      .\RTAudio.ps1 -Undo [-UndoIds power.plan]
      .\RTAudio.ps1 -Guide

    Applying and undoing need an elevated prompt. Backups live in %ProgramData%\RTAudio\ledger.json.
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Scan')][switch]$Scan,
    [Parameter(ParameterSetName = 'Check')][switch]$Check,
    [Parameter(ParameterSetName = 'Scan')][Parameter(ParameterSetName = 'Check')][string]$Report,
    [Parameter(ParameterSetName = 'Scan')][Parameter(ParameterSetName = 'Gui')][int]$LatencySeconds = 20,
    [Parameter(ParameterSetName = 'Scan')][Parameter(ParameterSetName = 'Check')][int]$ProbeSeconds = 10,
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Preset', Mandatory)][ValidateSet('Safe', 'Recommended', 'Aggressive')][string]$Preset,
    [Parameter(ParameterSetName = 'Apply', Mandatory)][string[]]$Apply,
    [Parameter(ParameterSetName = 'Preset')][Parameter(ParameterSetName = 'Apply')][switch]$DryRun,
    [Parameter(ParameterSetName = 'Preset')][Parameter(ParameterSetName = 'Apply')][switch]$NoRestorePoint,
    [Parameter(ParameterSetName = 'Undo', Mandatory)][switch]$Undo,
    [Parameter(ParameterSetName = 'Undo')][string[]]$UndoIds,
    [Parameter(ParameterSetName = 'Guide')][switch]$Guide,
    [Parameter(ParameterSetName = 'Gui')][switch]$NoElevate,
    [Parameter(ParameterSetName = 'Gui')][switch]$QuickCheck
)

$ErrorActionPreference = 'Stop'
$enginePath = Join-Path $PSScriptRoot 'src\Engine.psm1'
Import-Module $enginePath -Force -DisableNameChecking

function Assert-Admin {
    if (-not (Test-RTAdmin)) { throw 'This action needs administrator rights. Run it from an elevated PowerShell (Run as administrator).' }
}

function Write-Results {
    param($Results)
    $Results | Format-Table @{ n = 'Outcome'; e = { $_.Outcome } }, Title, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    if ($Results | Where-Object { $_.Reboot -and $_.Outcome -in 'Applied', 'AppliedUnverified', 'Reverted' }) {
        Write-Host 'Some changes take effect after a reboot.' -ForegroundColor Yellow
    }
}

$progress = { param($m) Write-Host "  $m" -ForegroundColor DarkGray }

function Write-Readiness {
    param($Readiness)
    if (-not $Readiness) { return }
    $color = @{ Suitable = 'Green'; Limited = 'Yellow'; NotSuitable = 'Red' }[$Readiness.Level]
    Write-Host "`nAUDIO READINESS" -ForegroundColor Cyan
    Write-Host "  $($Readiness.Headline)" -ForegroundColor $color
    Write-Host "  $($Readiness.Summary)"
    Write-Host ''
    foreach ($a in $Readiness.Areas) {
        $c = @{ Good = 'Green'; Fair = 'Yellow'; Poor = 'Red'; Unknown = 'Gray' }[$a.Rating]
        Write-Host ('  {0,-8}{1,-23}{2}' -f $a.Rating, $a.Area, $a.Summary) -ForegroundColor $c
        if ($a.Advice -and $a.Rating -ne 'Good') { Write-Host "                               -> $($a.Advice)" }
    }
    $p = $Readiness.Probe
    if ($p -and $p.Ok) {
        Write-Host ''
        Write-Host '  Buffer @48 kHz   Latency   Stalls/min' -ForegroundColor DarkGray
        foreach ($b in $p.Buffers) {
            Write-Host ('  {0,5} samples   {1,6} ms   {2}' -f $b.Buffer, $b.BufferMs, $b.PerMinute) -ForegroundColor $(if ($b.Stalls) { 'Red' } else { 'Green' })
        }
        Write-Host "  Probe: $($p.Callbacks) callbacks, delay median $($p.MedianMs) ms, 99.9% $($p.P999Ms) ms, max $($p.MaxMs) ms (assumes 50% DSP load)." -ForegroundColor DarkGray
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Gui' {
        if (-not (Test-RTAdmin) -and -not $NoElevate -and -not $QuickCheck) {
            try {
                Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
                return
            } catch {
                Write-Warning 'Elevation was cancelled; starting in scan-only mode.'
            }
        }
        . (Join-Path $PSScriptRoot 'src\UI\UI.ps1')
        Show-RTAudioWindow -EnginePath $enginePath -QuickCheck:$QuickCheck
    }
    'Scan' {
        if (-not (Test-RTAdmin)) { Write-Warning 'Not elevated: a few checks (Defender, boot settings) will show as Unknown.' }
        $result = Invoke-RTScan -LatencySeconds $LatencySeconds -ProbeSeconds $ProbeSeconds -Progress $progress
        Write-Readiness $result.Readiness
        Write-Host "`nFINDINGS" -ForegroundColor Cyan
        foreach ($f in $result.Findings) {
            $color = @{ Problem = 'Red'; Warning = 'Yellow'; Info = 'Gray'; Ok = 'Green' }[$f.Severity]
            Write-Host ('[{0,-7}] {1}' -f $f.Severity, $f.Title) -ForegroundColor $color
            if ($f.Detail) { Write-Host "          $($f.Detail)" -ForegroundColor DarkGray }
            if ($f.Advice) { Write-Host "          -> $($f.Advice)" }
        }
        Write-Host "`nTWEAKS" -ForegroundColor Cyan
        $result.Tweaks | Format-Table Status, Id, Risk, @{ n = 'Presets'; e = { $_.Presets -join ',' } }, Current -AutoSize | Out-String -Width 220 | Write-Host
        if ($Report) { Write-Host "Report: $(Export-RTReport -Scan $result -Path $Report)" }
    }
    'Check' {
        Write-Host 'Quick audio check: read-only, takes about 20 seconds. Close other apps and leave the PC idle.' -ForegroundColor Cyan
        $result = Invoke-RTScan -LatencySeconds 0 -ProbeSeconds $ProbeSeconds -Progress $progress
        Write-Readiness $result.Readiness
        $issues = @($result.Findings | Where-Object { $_.Severity -in 'Problem', 'Warning' })
        if ($issues) {
            Write-Host "`nISSUES" -ForegroundColor Cyan
            foreach ($f in $issues) {
                Write-Host ('  [{0,-7}] {1}' -f $f.Severity, $f.Title) -ForegroundColor $(if ($f.Severity -eq 'Problem') { 'Red' } else { 'Yellow' })
            }
        }
        Write-Host "`nFor details and fixes run Start-RTAudio.cmd (or .\RTAudio.ps1 -Scan)." -ForegroundColor DarkGray
        if ($Report) { Write-Host "Report: $(Export-RTReport -Scan $result -Path $Report)" }
    }
    'List' {
        Get-RTTweaks | ForEach-Object {
            $r = Test-RTTweak $_
            [pscustomobject]@{ Id = $_.Id; Status = $r.Status; Risk = $_.Risk; Presets = ($_.Presets -join ','); Reboot = $_.Reboot; Title = $_.Title }
        } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    }
    { $_ -in 'Preset', 'Apply' } {
        if (-not $DryRun) { Assert-Admin }
        $ids = if ($Preset) { Get-RTPresetIds -Preset $Preset } else { $Apply }
        Write-Host "$(if ($DryRun) { 'Dry run' } else { 'Applying' }): $($ids.Count) tweak(s)" -ForegroundColor Cyan
        Write-Results (Invoke-RTApply -Ids $ids -DryRun:$DryRun -NoRestorePoint:$NoRestorePoint -Progress $progress)
    }
    'Undo' {
        Assert-Admin
        $applied = @(Get-RTAppliedTweaks)
        if (-not $applied) { Write-Host 'Nothing to undo.'; return }
        Write-Results (Invoke-RTUndo -Ids $UndoIds -Progress $progress)
    }
    'Guide' {
        foreach ($p in Get-RTGuide) {
            Write-Host "`n== $($p.title) ==$(if ($p.Done) { '  (done)' })" -ForegroundColor Cyan
            Write-Host $p.summary -ForegroundColor DarkGray
            $i = 0; foreach ($s in $p.steps) { $i++; Write-Host "  $i. $s" }
        }
    }
}
