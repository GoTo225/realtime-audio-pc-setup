# Studio mode: temporary settings for a recording/production session, restored when the session ends.
# Unlike tweaks (permanent, with a backup ledger), studio mode is meant to be switched on and off.
# Its state lives in %ProgramData%\RTAudio\studio.json, so ending it still works after a crash or reboot.
#
# Action contract: Id, Title, Why, Default (bool), Check ($null = something to do, else a reason to skip),
# Start (returns the state needed to undo it), Stop (param $state).

$script:StudioPath = Join-Path $script:DataDir 'studio.json'
$script:StudioActions = New-Object System.Collections.ArrayList

function Register-RTStudioAction { param([Parameter(Mandatory)][hashtable]$Action) [void]$script:StudioActions.Add($Action) }

function Get-RTStudioActions {
    foreach ($a in $script:StudioActions) {
        $skip = $null
        try { $skip = & $a.Check } catch { $skip = "check failed: $($_.Exception.Message)" }
        [pscustomobject]@{ Id = $a.Id; Title = $a.Title; Why = $a.Why; Default = [bool]$a.Default; Available = -not $skip; Note = "$skip" }
    }
}

function Get-RTStudioState {
    if (-not (Test-Path $script:StudioPath)) { return $null }
    try {
        $s = ConvertTo-RTHashtable (Get-Content -Raw -Path $script:StudioPath -Encoding UTF8 | ConvertFrom-Json)
        if ($s -is [hashtable] -and $s.ContainsKey('Actions')) { return $s }
    } catch { Write-RTLog "Studio state unreadable: $_" }
    $null
}

function Save-RTStudioState {
    param([hashtable]$State)
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    ConvertTo-Json -InputObject $State -Depth 10 | Set-Content -Path $script:StudioPath -Encoding UTF8
}

function Enable-RTStudioMode {
    param([string[]]$Ids, [scriptblock]$Progress = { param($m) })
    if (-not (Test-RTAdmin)) { throw 'Studio mode needs administrator rights.' }
    if (Get-RTStudioState) { throw 'Studio mode is already on. End it first.' }
    if (-not $Ids) { $Ids = @($script:StudioActions | Where-Object { $_.Default } | ForEach-Object { $_.Id }) }
    $state = @{ StartedAt = (Get-Date).ToString('o'); Actions = [ordered]@{} }
    $results = New-Object System.Collections.ArrayList
    foreach ($a in $script:StudioActions | Where-Object { $Ids -contains $_.Id }) {
        & $Progress "Studio mode: $($a.Title)"
        $row = [pscustomobject]@{ Id = $a.Id; Title = $a.Title; Outcome = ''; Detail = ''; Reboot = $false }
        $skip = $null; try { $skip = & $a.Check } catch { $skip = $_.Exception.Message }
        if ($skip) { $row.Outcome = 'Skipped'; $row.Detail = "$skip"; [void]$results.Add($row); continue }
        try {
            $st = & $a.Start
            $state.Actions[$a.Id] = $st
            Save-RTStudioState $state          # after every step, so a crash mid-way can still be undone
            $row.Outcome = 'Applied'; $row.Detail = $(if ($st -is [hashtable] -and $st.ContainsKey('Summary')) { $st['Summary'] } else { '' })
            Write-RTLog "STUDIO ON $($a.Id): $($row.Detail)"
        } catch {
            $row.Outcome = 'Failed'; $row.Detail = $_.Exception.Message
            Write-RTLog "STUDIO ON $($a.Id) FAILED: $($_.Exception.Message)"
        }
        [void]$results.Add($row)
    }
    Save-RTStudioState $state
    @($results)
}

function Disable-RTStudioMode {
    param([scriptblock]$Progress = { param($m) })
    if (-not (Test-RTAdmin)) { throw 'Ending studio mode needs administrator rights.' }
    $state = Get-RTStudioState
    if (-not $state) { return @() }
    $results = New-Object System.Collections.ArrayList
    $ids = @($state.Actions.Keys)
    [array]::Reverse($ids)
    $failed = [ordered]@{}
    foreach ($id in $ids) {
        $a = $script:StudioActions | Where-Object Id -eq $id | Select-Object -First 1
        $row = [pscustomobject]@{ Id = $id; Title = $(if ($a) { $a.Title } else { $id }); Outcome = ''; Detail = ''; Reboot = $false }
        & $Progress "Restoring: $($row.Title)"
        try {
            if (-not $a) { throw 'unknown action' }
            & $a.Stop $state.Actions[$id]
            $row.Outcome = 'Reverted'
            Write-RTLog "STUDIO OFF ${id}: restored"
        } catch {
            $row.Outcome = 'Failed'; $row.Detail = $_.Exception.Message
            $failed[$id] = $state.Actions[$id]
            Write-RTLog "STUDIO OFF $id FAILED: $($_.Exception.Message)"
        }
        [void]$results.Add($row)
    }
    # Keep only what could not be restored, so the user can retry.
    if ($failed.Count) { $state.Actions = $failed; Save-RTStudioState $state } else { Remove-Item $script:StudioPath -Force -ErrorAction SilentlyContinue }
    @($results)
}

#region Actions ---------------------------------------------------------------------

function Get-RTPowerPlanTweak { $script:StaticTweaks | Where-Object { $_.Id -eq 'power.plan' } | Select-Object -First 1 }

Register-RTStudioAction @{
    Id = 'studio.apps'; Default = $true
    Title = 'Quit background apps (sync, chat, launchers, RGB tools)'
    Why = 'They poll hardware, sync files or show pop-ups. They are started again (without administrator rights) when studio mode ends.'
    Check = {
        $running = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
        if (-not @($script:BackgroundApps.Keys | Where-Object { $running -contains $_ })) { 'none of the known background apps is running' }
    }
    Start = {
        $stopped = New-Object System.Collections.ArrayList
        foreach ($name in $script:BackgroundApps.Keys) {
            $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
            if (-not $procs) { continue }
            $path = @($procs | ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ }) | Select-Object -First 1
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            [void]$stopped.Add(@{ Name = $name; Label = $script:BackgroundApps[$name]; Path = "$path" })
        }
        @{ Apps = @($stopped); Summary = "quit: $(($stopped | ForEach-Object { $_.Label }) -join ', ')" }
    }
    Stop = {
        param($state)
        foreach ($app in @($state.Apps)) {
            if (-not $app -or -not $app.Path -or -not (Test-Path -LiteralPath $app.Path)) { continue }
            if (Get-Process -Name $app.Name -ErrorAction SilentlyContinue) { continue }   # already back (e.g. after a reboot)
            # Started through Explorer so the app runs as the normal user, not elevated like this tool.
            Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "`"$($app.Path)`""
        }
    }
}

$script:WuPauseKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$script:WuPauseValues = 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime'

Register-RTStudioAction @{
    Id = 'studio.updates'; Default = $true
    Title = 'Pause Windows Update for 24 hours'
    Why = 'Stops downloads and installs from starting mid-session. The previous pause settings are restored when studio mode ends. Ignored on PCs whose updates are managed by an organisation.'
    Check = { }
    Start = {
        $backup = @(foreach ($n in $script:WuPauseValues) { $r = Get-RTRegValue $script:WuPauseKey $n; @{ Name = $n; Existed = [bool]$r; Value = $(if ($r) { "$($r.Value)" }) } })
        $now = (Get-Date).ToUniversalTime(); $end = $now.AddHours(24)
        $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
        foreach ($n in $script:WuPauseValues) {
            $v = if ($n -match 'StartTime$') { $now.ToString($fmt) } else { $end.ToString($fmt) }
            Set-RTRegValue $script:WuPauseKey $n $v 'String'
        }
        @{ Values = $backup; Summary = "paused until $($end.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" }
    }
    Stop = {
        param($state)
        foreach ($b in @($state.Values)) {
            if ($b.Existed) { Set-RTRegValue $script:WuPauseKey $b.Name $b.Value 'String' } else { Remove-RTRegValue $script:WuPauseKey $b.Name }
        }
    }
}

Register-RTStudioAction @{
    Id = 'studio.indexing'; Default = $true
    Title = 'Pause Windows Search indexing'
    Why = 'The indexer reads new recordings and sample packs as they appear. The service is started again when studio mode ends.'
    Check = {
        $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if (-not $svc) { 'Windows Search is not installed' } elseif ($svc.Status -ne 'Running') { 'Windows Search is not running' }
    }
    Start = { Stop-Service -Name WSearch -Force -ErrorAction Stop; @{ WasRunning = $true; Summary = 'Windows Search stopped' } }
    Stop = {
        param($state)
        $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if ($state.WasRunning -and $svc -and $svc.Status -ne 'Running' -and $svc.StartType -ne 'Disabled') { Start-Service -Name WSearch }
    }
}

Register-RTStudioAction @{
    Id = 'studio.power'; Default = $true
    Title = 'Switch to the High/Ultimate Performance power plan for the session'
    Why = 'Full CPU performance while you record, your usual plan afterwards. Useful on laptops where you do not want the performance plan permanently.'
    Check = {
        $t = Get-RTPowerPlanTweak
        if (-not $t) { 'power plan tweak not available' } elseif ((Test-RTTweak $t).Status -ne 'NotOptimal') { 'a performance plan is already active' }
    }
    Start = {
        $t = Get-RTPowerPlanTweak
        $st = & $t.Backup $t
        & $t.Apply $t
        @{ Plan = $st; Summary = 'performance plan active' }
    }
    Stop = {
        param($state)
        $t = Get-RTPowerPlanTweak
        & $t.Revert $t $state.Plan
    }
}

function Get-RTWifiAdapters {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' -and ($_.NdisPhysicalMedium -eq 9 -or $_.PhysicalMediaType -match '802\.11') })
}

Register-RTStudioAction @{
    Id = 'studio.wifi'; Default = $false
    Title = 'Turn off Wi-Fi'
    Why = 'Wi-Fi drivers are a frequent source of latency spikes. You lose network access (cloud plugins, licence checks, streaming) until studio mode ends.'
    Check = { if (-not (Get-RTWifiAdapters)) { 'no enabled Wi-Fi adapter' } }
    Start = {
        $names = @(Get-RTWifiAdapters | ForEach-Object Name)
        foreach ($n in $names) { Disable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop }
        @{ Adapters = $names; Summary = "disabled: $($names -join ', ')" }
    }
    Stop = { param($state) foreach ($n in @($state.Adapters)) { if ($n) { Enable-NetAdapter -Name $n -Confirm:$false } } }
}

function Get-RTBluetoothRadios {
    @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Bluetooth'" -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -match '^(USB|PCI)\\' -and -not (Test-RTDeviceDisabled $_) })
}

Register-RTStudioAction @{
    Id = 'studio.bluetooth'; Default = $false
    Title = 'Turn off Bluetooth'
    Why = 'Bluetooth drivers cause latency spikes on some systems. Bluetooth keyboards, mice and headphones stop working until studio mode ends.'
    Check = { if (-not (Get-RTBluetoothRadios)) { 'no enabled Bluetooth radio' } }
    Start = {
        $ids = @(Get-RTBluetoothRadios | ForEach-Object DeviceID)
        foreach ($id in $ids) { Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop }
        @{ Devices = $ids; Summary = "disabled $($ids.Count) Bluetooth radio(s)" }
    }
    Stop = { param($state) foreach ($id in @($state.Devices)) { if ($id) { Enable-PnpDevice -InstanceId $id -Confirm:$false } } }
}

#endregion
