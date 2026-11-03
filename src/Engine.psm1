#Requires -Version 5.1
<#
  RTAudio engine: tweak registry, scan, apply (with backup ledger), undo, guide, report.

  Tweak definition (hashtable):
    Id, Category, Title, Why, Risk ('Safe'|'Moderate'|'Advanced'), Reboot (bool),
    Presets (subset of 'Safe','Recommended','Aggressive'), Order (int, lower runs first),
    Kind ('Registry'|'PowerSetting'|'Custom'), Params (hashtable),
    Test/Backup/Apply/Revert scriptblocks (Custom only; generic kinds get them from the engine).
  Every scriptblock is invoked as  & $sb $tweak  (Revert: & $sb $tweak $state).
  Test returns @{ Status = 'Ok'|'NotOptimal'|'NotApplicable'|'Unknown'; Current; Desired }.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root        = Split-Path -Parent $PSScriptRoot
$script:DataDir     = Join-Path $env:ProgramData 'RTAudio'
$script:LedgerPath  = Join-Path $script:DataDir 'ledger.json'
$script:LogPath     = Join-Path $script:DataDir 'rtaudio.log'
$script:GuideState  = Join-Path $script:DataDir 'guide-state.json'
$script:StaticTweaks = New-Object System.Collections.ArrayList
$script:Providers    = New-Object System.Collections.ArrayList
$script:Detectors    = New-Object System.Collections.ArrayList
$script:Presets      = @('Safe', 'Recommended', 'Aggressive')
$script:Risks        = @('Safe', 'Moderate', 'Advanced')

#region Helpers ---------------------------------------------------------------

function Test-RTAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-RTLog {
    param([string]$Message)
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        Add-Content -Path $script:LogPath -Value ('{0:u}  {1}' -f (Get-Date), $Message) -Encoding UTF8
    } catch { }
}

function Get-RTRegValue {
    param([string]$Path, [string]$Name)
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -notcontains $Name) { return $null }
        [pscustomobject]@{
            Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            Kind  = $key.GetValueKind($Name).ToString()
        }
    } catch { $null }
}

function Set-RTRegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}

function Test-RTRegValueEqual {
    # DWORDs come back as Int32 (-1) or UInt32 (4294967295) depending on the API; compare the bit pattern.
    param($A, $B)
    $na = $A -as [int64]; $nb = $B -as [int64]
    $isDword = { param($n) $null -ne $n -and $n -ge [int32]::MinValue -and $n -le [uint32]::MaxValue }
    if ((& $isDword $na) -and (& $isDword $nb)) { return ($na -band 0xFFFFFFFFL) -eq ($nb -band 0xFFFFFFFFL) }
    "$A" -eq "$B"
}

function Remove-RTRegValue {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
}

# powercfg output is localized, so only rely on structure: the last two hex values are
# the current AC and DC index, in that order.
function ConvertFrom-RTPowercfgQuery {
    param([string[]]$Lines)
    $hex = @($Lines | ForEach-Object { if ($_ -match ':\s*0x([0-9a-fA-F]+)\s*$') { [Convert]::ToInt64($Matches[1], 16) } })
    if ($hex.Count -lt 2) { return $null }
    [pscustomobject]@{ AC = [int]$hex[-2]; DC = [int]$hex[-1] }
}

function Get-RTActiveSchemeGuid {
    $out = powercfg /getactivescheme 2>$null
    if ("$out" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLower() }
    $null
}

function Get-RTPowerSetting {
    param([string]$Scheme = 'SCHEME_CURRENT', [string]$Subgroup, [string]$Setting)
    $out = powercfg /qh $Scheme $Subgroup $Setting 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    ConvertFrom-RTPowercfgQuery -Lines $out
}

function Set-RTPowerSetting {
    param([string]$Scheme = 'SCHEME_CURRENT', [string]$Subgroup, [string]$Setting, [int]$AC, [int]$DC)
    powercfg /setacvalueindex $Scheme $Subgroup $Setting $AC | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg /setacvalueindex failed for $Setting" }
    powercfg /setdcvalueindex $Scheme $Subgroup $Setting $DC | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

function New-RTTestResult {
    param([string]$Status, $Current, $Desired)
    @{ Status = $Status; Current = "$Current"; Desired = "$Desired" }
}

function ConvertTo-RTHashtable {
    # ConvertFrom-Json yields PSCustomObjects; normalise ledger entries to hashtables recursively.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IList] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-RTHashtable $_ })
    }
    if ($InputObject -is [pscustomobject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-RTHashtable $p.Value }
        return $h
    }
    $InputObject
}

#endregion

#region Registration ----------------------------------------------------------

function Register-RTTweak {
    param([Parameter(Mandatory)][hashtable]$Tweak)
    [void]$script:StaticTweaks.Add((Complete-RTTweak $Tweak))
}

function Register-RTTweakProvider {
    # Provider: scriptblock receiving the scan context, returning tweak hashtables
    # (used for things that depend on the machine, e.g. one tweak per audio device).
    param([Parameter(Mandatory)][scriptblock]$Provider)
    [void]$script:Providers.Add($Provider)
}

function Register-RTDetector {
    # Detector: scriptblock receiving the context (+ -LatencySeconds), returning findings.
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][scriptblock]$Detect, [switch]$Slow)
    [void]$script:Detectors.Add(@{ Id = $Id; Detect = $Detect; Slow = [bool]$Slow })
}

function New-RTFinding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Info', 'Warning', 'Problem', 'Ok')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string]$Detail = '',
        [string]$Advice = '',
        [string]$GuideId = ''
    )
    [pscustomobject]@{ Id = $Id; Severity = $Severity; Category = $Category; Title = $Title; Detail = $Detail; Advice = $Advice; GuideId = $GuideId }
}

function Complete-RTTweak {
    param([hashtable]$Tweak)
    foreach ($k in 'Id', 'Category', 'Title', 'Why', 'Risk') {
        if (-not $Tweak.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$Tweak[$k])) { throw "Tweak is missing '$k': $($Tweak.Id)" }
    }
    if ($script:Risks -notcontains $Tweak.Risk) { throw "Tweak $($Tweak.Id) has invalid risk '$($Tweak.Risk)'" }
    if (-not $Tweak.ContainsKey('Presets')) { $Tweak.Presets = @() }
    foreach ($p in $Tweak.Presets) { if ($script:Presets -notcontains $p) { throw "Tweak $($Tweak.Id) has invalid preset '$p'" } }
    if (-not $Tweak.ContainsKey('Reboot')) { $Tweak.Reboot = $false }
    if (-not $Tweak.ContainsKey('Order')) { $Tweak.Order = 50 }
    if (-not $Tweak.ContainsKey('Kind')) { $Tweak.Kind = 'Custom' }
    if (-not $Tweak.ContainsKey('Params')) { $Tweak.Params = @{} }

    switch ($Tweak.Kind) {
        'Registry'     { $Tweak.Test = $script:RegTest;   $Tweak.Backup = $script:RegBackup;   $Tweak.Apply = $script:RegApply;   $Tweak.Revert = $script:RegRevert }
        'PowerSetting' { $Tweak.Test = $script:PowerTest; $Tweak.Backup = $script:PowerBackup; $Tweak.Apply = $script:PowerApply; $Tweak.Revert = $script:PowerRevert }
        'Custom'       { }
        default        { throw "Tweak $($Tweak.Id) has unknown kind '$($Tweak.Kind)'" }
    }
    foreach ($k in 'Test', 'Backup', 'Apply', 'Revert') {
        if ($Tweak[$k] -isnot [scriptblock]) { throw "Tweak $($Tweak.Id) is missing scriptblock '$k'" }
    }
    $Tweak
}

#endregion

#region Generic tweak kinds --------------------------------------------------

# Registry: Params.Values = @( @{ Path; Name; Value; Type = 'DWord' }, ... )
$script:RegTest = {
    param($t)
    $cur = @(); $des = @(); $ok = $true
    foreach ($v in $t.Params.Values) {
        $r = Get-RTRegValue $v.Path $v.Name
        $curVal = if ($r) { $r.Value } else { '(not set)' }
        $cur += "$($v.Name)=$curVal"; $des += "$($v.Name)=$($v.Value)"
        if (-not $r -or -not (Test-RTRegValueEqual $r.Value $v.Value)) { $ok = $false }
    }
    New-RTTestResult -Status $(if ($ok) { 'Ok' } else { 'NotOptimal' }) -Current ($cur -join '; ') -Desired ($des -join '; ')
}
$script:RegBackup = {
    param($t)
    @(foreach ($v in $t.Params.Values) {
        $r = Get-RTRegValue $v.Path $v.Name
        @{ Path = $v.Path; Name = $v.Name; Existed = [bool]$r; Value = $(if ($r) { $r.Value }); Kind = $(if ($r) { $r.Kind }) }
    })
}
$script:RegApply = {
    param($t)
    foreach ($v in $t.Params.Values) {
        $type = if ($v.ContainsKey('Type')) { $v.Type } else { 'DWord' }
        Set-RTRegValue $v.Path $v.Name $v.Value $type
    }
}
$script:RegRevert = {
    param($t, $state)
    foreach ($s in @($state)) {
        if ($s.Existed) { Set-RTRegValue $s.Path $s.Name $s.Value $s.Kind } else { Remove-RTRegValue $s.Path $s.Name }
    }
}

# PowerSetting: Params = @{ Subgroup; Setting; Value; Label }  (applied to AC and DC of the active scheme)
$script:PowerTest = {
    param($t)
    $p = $t.Params
    $cur = Get-RTPowerSetting -Subgroup $p.Subgroup -Setting $p.Setting
    if (-not $cur) { return New-RTTestResult 'NotApplicable' 'setting not available on this system' $p.Value }
    $ok = ($cur.AC -eq $p.Value)
    New-RTTestResult -Status $(if ($ok) { 'Ok' } else { 'NotOptimal' }) -Current "AC=$($cur.AC) DC=$($cur.DC)" -Desired "AC=$($p.Value)"
}
$script:PowerBackup = {
    param($t)
    $cur = Get-RTPowerSetting -Subgroup $t.Params.Subgroup -Setting $t.Params.Setting
    @{ Scheme = (Get-RTActiveSchemeGuid); AC = $cur.AC; DC = $cur.DC }
}
$script:PowerApply = {
    param($t)
    $p = $t.Params
    # Leave battery (DC) behaviour alone unless the tweak says otherwise: laptops need it.
    $dc = if ($p.ContainsKey('ApplyDC') -and $p.ApplyDC) { $p.Value } else { (Get-RTPowerSetting -Subgroup $p.Subgroup -Setting $p.Setting).DC }
    Set-RTPowerSetting -Subgroup $p.Subgroup -Setting $p.Setting -AC $p.Value -DC $dc
}
$script:PowerRevert = {
    param($t, $state)
    $scheme = if ($state.Scheme) { $state.Scheme } else { 'SCHEME_CURRENT' }
    powercfg /setacvalueindex $scheme $t.Params.Subgroup $t.Params.Setting $state.AC | Out-Null
    powercfg /setdcvalueindex $scheme $t.Params.Subgroup $t.Params.Setting $state.DC | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

#endregion

#region Context ---------------------------------------------------------------

function Get-RTContext {
    $ctx = @{
        IsAdmin    = Test-RTAdmin
        Os         = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
        Daws       = @()
        Interfaces = @()
        AudioDevices = @()
    }
    try { $ctx.Daws = @(Get-RTInstalledDaws) } catch { Write-RTLog "Context DAWs: $_" }
    try { $ctx.AudioDevices = @(Get-RTAudioDevices) } catch { Write-RTLog "Context audio devices: $_" }
    $ctx.Interfaces = @($ctx.AudioDevices | Where-Object { $_.Type -eq 'Interface' })
    $ctx
}

#endregion

#region Scan / apply / undo ---------------------------------------------------

function Get-RTTweaks {
    param([hashtable]$Context = (Get-RTContext))
    $all = New-Object System.Collections.ArrayList
    foreach ($t in $script:StaticTweaks) { [void]$all.Add($t) }
    foreach ($p in $script:Providers) {
        try { foreach ($t in @(& $p $Context)) { if ($t) { [void]$all.Add((Complete-RTTweak $t)) } } }
        catch { Write-RTLog "Tweak provider failed: $_" }
    }
    $dupes = $all | Group-Object { $_.Id } | Where-Object Count -gt 1
    if ($dupes) { throw "Duplicate tweak ids: $(($dupes | ForEach-Object Name) -join ', ')" }
    @($all | Sort-Object { $_.Order }, { $_.Category }, { $_.Title })
}

function Test-RTTweak {
    param([hashtable]$Tweak)
    try {
        $r = & $Tweak.Test $Tweak
        if (-not $r) { $r = New-RTTestResult 'Unknown' '' '' }
    } catch {
        $r = New-RTTestResult 'Unknown' "error: $($_.Exception.Message)" ''
    }
    $r
}

function Invoke-RTScan {
    <#
      .SYNOPSIS Read-only scan. Returns tweak states, findings and the context.
    #>
    param([int]$LatencySeconds = 20, [int]$ProbeSeconds = 0, [string]$ProbeLabel = 'scan', [hashtable]$Control,
          [scriptblock]$Progress = { param($msg) })
    & $Progress 'Collecting system information...'
    $ctx = Get-RTContext
    $tweaks = Get-RTTweaks -Context $ctx

    & $Progress 'Checking tweaks...'
    $tweakResults = foreach ($t in $tweaks) {
        $r = Test-RTTweak $t
        [pscustomobject]@{
            Id = $t.Id; Category = $t.Category; Title = $t.Title; Why = $t.Why; Risk = $t.Risk
            Reboot = [bool]$t.Reboot; Presets = @($t.Presets); Status = $r.Status; Current = $r.Current; Desired = $r.Desired
        }
    }

    $findings = New-Object System.Collections.ArrayList
    foreach ($d in $script:Detectors) {
        & $Progress $(if ($d.Slow -and $LatencySeconds -gt 0) { "Running $($d.Id) (about $LatencySeconds s)..." } else { "Running $($d.Id)..." })
        try { foreach ($f in @(& $d.Detect $ctx $LatencySeconds)) { if ($f) { [void]$findings.Add($f) } } }
        catch {
            [void]$findings.Add((New-RTFinding -Id "$($d.Id).error" -Severity Info -Category 'Tool' -Title "Check '$($d.Id)' could not run" -Detail $_.Exception.Message))
        }
    }

    # Runs after the other detectors, never alongside them, so the scan itself does not disturb it.
    $probe = $null
    if ($ProbeSeconds -gt 0) {
        & $Progress "Real-time audio probe (about $ProbeSeconds s, keep the PC idle)..."
        # With admin rights a kernel DPC/ISR trace runs alongside the probe and names the drivers behind stalls.
        $trace = $null; $traceError = ''
        if (Test-RTAdmin) { try { $trace = Start-RTDriverTrace } catch { $traceError = $_.Exception.Message } }
        else { $traceError = 'Run as administrator to name the drivers behind latency spikes.' }
        try { $probe = Invoke-RTRealtimeProbe -Seconds $ProbeSeconds -Progress $Progress -Control $Control }
        catch { $probe = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
        finally {
            $drivers = $null
            if ($trace) { try { $drivers = Stop-RTDriverTrace -Trace $trace } catch { $traceError = $_.Exception.Message } }
        }
        if (-not $drivers) { $drivers = [pscustomobject]@{ Ok = $false; Error = $traceError; Drivers = @() } }
        if ($probe.PSObject.Properties['Drivers']) { $probe.Drivers = $drivers }
        try { foreach ($f in @(Get-RTDriverTraceFindings -Result $drivers)) { if ($f) { [void]$findings.Add($f) } } }
        catch { Write-RTLog "Driver trace findings: $_" }
    }
    $comparison = $null
    if ($probe -and $probe.Ok) {
        $studio = $false; try { $studio = [bool](Get-RTStudioState) } catch { }
        $record = ConvertTo-RTProbeRecord -Probe $probe -Label $ProbeLabel -AppliedTweaks @(Get-RTAppliedTweaks).Count -StudioMode $studio
        $previous = Add-RTProbeHistory -Record $record
        if ($previous) { try { $comparison = Compare-RTProbe -Before $previous -After $record } catch { Write-RTLog "Probe compare: $_" } }
    }

    $sevOrder = @{ Problem = 0; Warning = 1; Info = 2; Ok = 3 }
    $scan = [pscustomobject]@{
        Timestamp = Get-Date
        Computer  = $env:COMPUTERNAME
        Context   = $ctx
        Tweaks    = @($tweakResults)
        Findings  = @($findings | Sort-Object { $sevOrder[$_.Severity] }, Category, Title)
        Readiness = $null
    }
    & $Progress 'Rating readiness...'
    try {
        $scan.Readiness = Get-RTReadinessForScan -Scan $scan -Probe $probe
        $scan.Readiness | Add-Member -NotePropertyName Comparison -NotePropertyValue $comparison -Force
    } catch { Write-RTLog "Readiness: $_" }
    $scan
}

function Get-RTPresetIds {
    param([Parameter(Mandatory)][ValidateSet('Safe', 'Recommended', 'Aggressive')][string]$Preset, [hashtable]$Context = (Get-RTContext))
    # Presets are cumulative: Aggressive includes Recommended includes Safe.
    $include = switch ($Preset) { 'Safe' { @('Safe') } 'Recommended' { @('Safe', 'Recommended') } 'Aggressive' { $script:Presets } }
    @(Get-RTTweaks -Context $Context | Where-Object { @($_.Presets | Where-Object { $include -contains $_ }).Count -gt 0 } | ForEach-Object { $_.Id })
}

function Read-RTLedger {
    if (-not (Test-Path $script:LedgerPath)) { return @{} }
    $raw = Get-Content -Raw -Path $script:LedgerPath -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $h = ConvertTo-RTHashtable (ConvertFrom-Json $raw)
    if ($h -isnot [hashtable]) { return @{} }
    $h
}

function Save-RTLedger {
    param([hashtable]$Ledger)
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $tmp = "$script:LedgerPath.tmp"
    ConvertTo-Json -InputObject $Ledger -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:LedgerPath -Force
}

function New-RTRestorePoint {
    # Windows only allows one restore point per 24h by default; lift that for this call.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = Get-RTRegValue $key 'SystemRestorePointCreationFrequency'
    try {
        Set-RTRegValue $key 'SystemRestorePointCreationFrequency' 0 'DWord'
        Checkpoint-Computer -Description 'RTAudio Setup' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        'Restore point created.'
    } catch {
        "Restore point NOT created ($($_.Exception.Message)). Is System Protection enabled for C:?"
    } finally {
        if ($old) { Set-RTRegValue $key 'SystemRestorePointCreationFrequency' $old.Value $old.Kind }
        else { Remove-RTRegValue $key 'SystemRestorePointCreationFrequency' }
    }
}

function Invoke-RTApply {
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [switch]$DryRun,
        [switch]$NoRestorePoint,
        [scriptblock]$Progress = { param($msg) }
    )
    if (-not $DryRun -and -not (Test-RTAdmin)) { throw 'Applying tweaks requires administrator rights.' }
    $ctx = Get-RTContext
    $byId = @{}; foreach ($t in Get-RTTweaks -Context $ctx) { $byId[$t.Id] = $t }
    $unknown = @($Ids | Where-Object { -not $byId.ContainsKey($_) })
    if ($unknown) { throw "Unknown tweak id(s): $($unknown -join ', ')" }
    $selected = @($Ids | Select-Object -Unique | ForEach-Object { $byId[$_] } | Sort-Object { $_.Order })

    $results = New-Object System.Collections.ArrayList
    if (-not $DryRun -and -not $NoRestorePoint) {
        & $Progress 'Creating System Restore point (this can take a minute)...'
        $msg = New-RTRestorePoint
        Write-RTLog $msg
        [void]$results.Add([pscustomobject]@{ Id = '(restore point)'; Title = 'System Restore point'; Outcome = 'Info'; Detail = $msg; Reboot = $false })
    }

    $ledger = if ($DryRun) { @{} } else { Read-RTLedger }
    foreach ($t in $selected) {
        & $Progress "Applying: $($t.Title)"
        $before = Test-RTTweak $t
        $row = [pscustomobject]@{ Id = $t.Id; Title = $t.Title; Outcome = ''; Detail = ''; Reboot = [bool]$t.Reboot }
        if ($before.Status -eq 'Ok') { $row.Outcome = 'AlreadyOk'; $row.Detail = $before.Current; [void]$results.Add($row); continue }
        if ($before.Status -eq 'NotApplicable') { $row.Outcome = 'Skipped'; $row.Detail = $before.Current; [void]$results.Add($row); continue }
        if ($DryRun) { $row.Outcome = 'WouldApply'; $row.Detail = "$($before.Current)  ->  $($before.Desired)"; [void]$results.Add($row); continue }
        try {
            $state = & $t.Backup $t
            # Keep the *original* state if this tweak was applied before, so undo goes back to pre-tool settings.
            if (-not $ledger.ContainsKey($t.Id)) {
                $ledger[$t.Id] = @{ Title = $t.Title; AppliedAt = (Get-Date).ToString('o'); State = $state }
                Save-RTLedger $ledger
            }
            & $t.Apply $t
            $after = Test-RTTweak $t
            $row.Outcome = if ($after.Status -eq 'Ok') { 'Applied' } else { 'AppliedUnverified' }
            $row.Detail = "$($before.Current)  ->  $($after.Current)"
            Write-RTLog "APPLY $($t.Id): $($row.Outcome) $($row.Detail)"
        } catch {
            $row.Outcome = 'Failed'; $row.Detail = $_.Exception.Message
            Write-RTLog "APPLY $($t.Id) FAILED: $($_.Exception.Message)"
        }
        [void]$results.Add($row)
    }
    @($results)
}

function Get-RTAppliedTweaks {
    $l = Read-RTLedger
    @($l.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; Title = $l[$_].Title; AppliedAt = $l[$_].AppliedAt } } | Sort-Object AppliedAt)
}

function Invoke-RTUndo {
    param([string[]]$Ids, [scriptblock]$Progress = { param($msg) })
    if (-not (Test-RTAdmin)) { throw 'Undo requires administrator rights.' }
    $ledger = Read-RTLedger
    if (-not $Ids) { $Ids = @($ledger.Keys) }
    $byId = @{}; foreach ($t in Get-RTTweaks) { $byId[$t.Id] = $t }
    $results = New-Object System.Collections.ArrayList
    $targets = @($Ids | Where-Object { $ledger.ContainsKey($_) } | Sort-Object { if ($byId.ContainsKey($_)) { -$byId[$_].Order } else { 0 } })
    foreach ($id in $targets) {
        $title = $ledger[$id].Title
        & $Progress "Reverting: $title"
        $row = [pscustomobject]@{ Id = $id; Title = $title; Outcome = ''; Detail = ''; Reboot = $false }
        if (-not $byId.ContainsKey($id)) {
            # e.g. a per-device tweak for hardware that is no longer present
            $row.Outcome = 'Failed'; $row.Detail = 'Tweak is not available on this system any more; entry kept.'
        } else {
            try {
                & $byId[$id].Revert $byId[$id] $ledger[$id].State
                $ledger.Remove($id); Save-RTLedger $ledger
                $row.Outcome = 'Reverted'; $row.Reboot = [bool]$byId[$id].Reboot
                Write-RTLog "UNDO ${id}: reverted"
            } catch {
                $row.Outcome = 'Failed'; $row.Detail = $_.Exception.Message
                Write-RTLog "UNDO $id FAILED: $($_.Exception.Message)"
            }
        }
        [void]$results.Add($row)
    }
    foreach ($id in @($Ids | Where-Object { -not $ledger.ContainsKey($_) -and $targets -notcontains $_ })) {
        [void]$results.Add([pscustomobject]@{ Id = $id; Title = $id; Outcome = 'NotApplied'; Detail = 'No backup recorded for this tweak.'; Reboot = $false })
    }
    @($results)
}

#endregion

#region Guide -----------------------------------------------------------------

function Get-RTGuide {
    <# Returns guide pages relevant to this machine (pages with a 'when' condition are filtered). #>
    param([hashtable]$Context = (Get-RTContext), [switch]$All)
    $pages = Get-Content -Raw -Encoding UTF8 -Path (Join-Path $script:Root 'src\Guide\guide.json') | ConvertFrom-Json
    $done = Get-RTGuideState
    foreach ($p in $pages) {
        $show = $true
        if (-not $All -and $p.PSObject.Properties['when']) {
            $show = switch -Regex ($p.when) {
                '^daw:(.+)$' { [bool]($Context.Daws | Where-Object { $_.Name -eq $Matches[1] }); break }
                '^gpu:nvidia$' { [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }); break }
                '^laptop$' { [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue); break }
                default { $true }
            }
        }
        if ($show) {
            $p | Add-Member -NotePropertyName Done -NotePropertyValue ([bool]($done -contains $p.id)) -Force
            $p
        }
    }
}

function Get-RTGuideState {
    if (-not (Test-Path $script:GuideState)) { return @() }
    try { @(Get-Content -Raw $script:GuideState | ConvertFrom-Json) } catch { @() }
}

function Set-RTGuideDone {
    param([string]$Id, [bool]$Done = $true)
    $state = [System.Collections.ArrayList]@(Get-RTGuideState)
    if ($Done -and $state -notcontains $Id) { [void]$state.Add($Id) }
    if (-not $Done) { $state.Remove($Id) }
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    ConvertTo-Json -InputObject @($state) | Set-Content -Path $script:GuideState -Encoding UTF8
}

# Guide actions are a fixed whitelist: guide.json can only reference these ids.
$script:GuideActions = [ordered]@{
    'sound-panel'      = @{ Label = 'Open Sound control panel';           Run = { Start-Process 'mmsys.cpl' } }
    'device-manager'   = @{ Label = 'Open Device Manager';                Run = { Start-Process 'devmgmt.msc' } }
    'core-isolation'   = @{ Label = 'Open Core isolation settings';       Run = { Start-Process 'windowsdefender://coreisolation' } }
    'startup-apps'     = @{ Label = 'Open Startup apps';                  Run = { Start-Process 'ms-settings:startupapps' } }
    'power-options'    = @{ Label = 'Open Power Options';                 Run = { Start-Process 'powercfg.cpl' } }
    'windows-update'   = @{ Label = 'Open Windows Update';                Run = { Start-Process 'ms-settings:windowsupdate' } }
    'latencymon'       = @{ Label = 'Open LatencyMon download page';      Run = { Start-Process 'https://www.resplendence.com/latencymon' } }
    'reboot-uefi'      = @{ Label = 'Reboot into BIOS/UEFI now';          Run = { shutdown.exe /r /fw /t 5 }; Confirm = 'Save your work. The PC restarts into the BIOS/UEFI setup in 5 seconds. Continue?' }
}

function Get-RTGuideAction { param([string]$Id) if ($script:GuideActions.Contains($Id)) { $script:GuideActions[$Id] } }

function Invoke-RTGuideAction {
    param([Parameter(Mandatory)][string]$Id)
    $a = Get-RTGuideAction $Id
    if (-not $a) { throw "Unknown guide action '$Id'" }
    & $a.Run
}

#endregion

#region Report ----------------------------------------------------------------

function Export-RTReport {
    param([Parameter(Mandatory)]$Scan, $ApplyResults, [Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Web
    $e = { param($s) [System.Web.HttpUtility]::HtmlEncode("$s") }
    $sb = New-Object System.Text.StringBuilder
    $os = $Scan.Context.Os
    [void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RTAudio Report</title><style>
:root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--ok:#1a7f37;--warn:#9a6700;--bad:#cf222e;--info:#0969da}
@media (prefers-color-scheme:dark){:root{--bg:#161618;--fg:#f2f2f7;--muted:#98989d;--line:#2c2c2e;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--info:#58a6ff}}
body{background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif;margin:0 auto;max-width:1100px;padding:24px 16px}
h1{margin:0 0 4px}h2{margin-top:32px;border-bottom:1px solid var(--line);padding-bottom:4px}.muted{color:var(--muted)}
table{border-collapse:collapse;width:100%;display:block;overflow-x:auto}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;color:var(--muted)}.b{font-weight:600}.Ok,.Applied,.Reverted,.AlreadyOk{color:var(--ok)}.Warning,.NotOptimal,.AppliedUnverified,.WouldApply{color:var(--warn)}
.Problem,.Failed{color:var(--bad)}.Info,.Unknown,.NotApplicable,.Skipped{color:var(--info)}
</style></head><body>
<h1>RTAudio report</h1>
<div class="muted">$(& $e $Scan.Computer) &middot; $(& $e $os.Caption) $(& $e $os.Version) &middot; $(& $e $Scan.Timestamp.ToString('yyyy-MM-dd HH:mm'))</div>
"@)
    $rd = $Scan.Readiness
    if ($rd) {
        $lvl = @{ Suitable = 'Ok'; Limited = 'Warning'; NotSuitable = 'Problem' }[$rd.Level]
        [void]$sb.Append("<h2>Audio readiness</h2><p><span class='b $lvl' style='font-size:18px'>$(& $e $rd.Headline)</span><br>$(& $e $rd.Summary)</p>")
        [void]$sb.Append('<table><tr><th>Rating</th><th>Area</th><th>Type</th><th>Result</th><th>Advice</th></tr>')
        foreach ($a in $rd.Areas) {
            $cls = @{ Good = 'Ok'; Fair = 'Warning'; Poor = 'Problem'; Unknown = 'Info' }[$a.Rating]
            [void]$sb.Append("<tr><td class='b $cls'>$($a.Rating)</td><td>$(& $e $a.Area)</td><td class='muted'>$($a.Kind)</td><td>$(& $e $a.Summary)</td><td>$(& $e $a.Advice)</td></tr>")
        }
        [void]$sb.Append('</table>')
        if ($rd.Probe -and $rd.Probe.Ok) {
            [void]$sb.Append("<p class='muted'>Probe: $($rd.Probe.Callbacks) callbacks in $($rd.Probe.Seconds) s; delay median $($rd.Probe.MedianMs) ms, 99.9% $($rd.Probe.P999Ms) ms, max $($rd.Probe.MaxMs) ms. Assumes 50% DSP load at 48 kHz.</p>")
            [void]$sb.Append('<table><tr><th>Buffer</th><th>Latency</th><th>Stalls</th><th>Per minute</th></tr>')
            foreach ($b in $rd.Probe.Buffers) {
                $cls = if ($b.Stalls -eq 0) { 'Ok' } else { 'Problem' }
                [void]$sb.Append("<tr><td>$($b.Buffer) samples</td><td>$($b.BufferMs) ms</td><td class='b $cls'>$($b.Stalls)</td><td>$($b.PerMinute)</td></tr>")
            }
            [void]$sb.Append('</table>')
        }
        if ($rd.PSObject.Properties['Comparison'] -and $rd.Comparison) {
            $cls = @{ Better = 'Ok'; Worse = 'Problem'; Unchanged = 'Info' }[$rd.Comparison.Verdict]
            [void]$sb.Append("<p class='b $cls'>$(& $e $rd.Comparison.Text)</p>")
        }
    }
    [void]$sb.Append('<h2>Findings</h2><table><tr><th>Severity</th><th>Category</th><th>Finding</th><th>Advice</th></tr>')
    foreach ($f in $Scan.Findings) {
        [void]$sb.Append("<tr><td class='b $($f.Severity)'>$($f.Severity)</td><td>$(& $e $f.Category)</td><td><div class='b'>$(& $e $f.Title)</div><div class='muted'>$(& $e $f.Detail)</div></td><td>$(& $e $f.Advice)</td></tr>")
    }
    [void]$sb.Append('</table><h2>Tweaks</h2><table><tr><th>Status</th><th>Category</th><th>Tweak</th><th>Risk</th><th>Current</th><th>Desired</th></tr>')
    foreach ($t in $Scan.Tweaks) {
        [void]$sb.Append("<tr><td class='b $($t.Status)'>$($t.Status)</td><td>$(& $e $t.Category)</td><td>$(& $e $t.Title)</td><td>$(& $e $t.Risk)</td><td>$(& $e $t.Current)</td><td>$(& $e $t.Desired)</td></tr>")
    }
    [void]$sb.Append('</table>')
    if ($ApplyResults) {
        [void]$sb.Append('<h2>Changes in this session</h2><table><tr><th>Outcome</th><th>Tweak</th><th>Detail</th></tr>')
        foreach ($r in $ApplyResults) { [void]$sb.Append("<tr><td class='b $($r.Outcome)'>$($r.Outcome)</td><td>$(& $e $r.Title)</td><td>$(& $e $r.Detail)</td></tr>") }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append('</body></html>')
    Set-Content -Path $Path -Value $sb.ToString() -Encoding UTF8
    $Path
}

#endregion

# Load tweak and detector definitions (dot-sourced so they share this module's scope).
foreach ($dir in 'Detect', 'Tweaks', 'Studio') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $dir) -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
}

Export-ModuleMember -Function Test-RTAdmin, Get-RTContext, Get-RTTweaks, Test-RTTweak, Invoke-RTScan, Get-RTPresetIds,
    Invoke-RTApply, Invoke-RTUndo, Get-RTAppliedTweaks, Get-RTGuide, Set-RTGuideDone, Get-RTGuideAction, Invoke-RTGuideAction,
    Export-RTReport, ConvertFrom-RTPowercfgQuery, Get-RTAudioDevices, Get-RTInstalledDaws, Get-RTLatencySample,
    Invoke-RTRealtimeProbe, Get-RTReadiness, Get-RTProbeHistory, Compare-RTProbe,
    Get-RTStudioActions, Get-RTStudioState, Enable-RTStudioMode, Disable-RTStudioMode,
    Start-RTDriverTrace, Stop-RTDriverTrace, Get-RTDriverExplanation
