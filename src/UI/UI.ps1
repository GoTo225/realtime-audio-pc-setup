# WPF front-end. Long-running work (scan with latency sampling, apply, restore point) runs in a
# background runspace with the engine module loaded; a DispatcherTimer polls it from the UI thread.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

if (-not ('RTAudio.TweakRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace RTAudio {
    public class Notify : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void On(string name) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }
    }
    public class TweakRow : Notify {
        private bool _selected; private string _status, _current, _applied;
        public bool Selected { get { return _selected; } set { if (_selected != value) { _selected = value; On("Selected"); } } }
        public string Status { get { return _status; } set { _status = value; On("Status"); On("StatusText"); } }
        public string StatusText { get {
            switch (_status) { case "Ok": return "OK"; case "NotOptimal": return "Not optimal"; case "NotApplicable": return "n/a"; default: return _status; } } }
        public string Current { get { return _current; } set { _current = value; On("Current"); } }
        public string AppliedText { get { return _applied; } set { _applied = value; On("AppliedText"); } }
        public string Id { get; set; }
        public string Category { get; set; }
        public string Title { get; set; }
        public string Why { get; set; }
        public string Risk { get; set; }
        public string Desired { get; set; }
        public bool Reboot { get; set; }
        public string RebootText { get { return Reboot ? "yes" : ""; } }
        public string[] Presets { get; set; }
    }
    public class GuideRow : Notify {
        private bool _done;
        public string Id { get; set; }
        public string Title { get; set; }
        public string Category { get; set; }
        public string Summary { get; set; }
        public string[] Steps { get; set; }
        public string[] Actions { get; set; }
        public bool Done { get { return _done; } set { _done = value; On("Done"); On("DisplayTitle"); } }
        public string DisplayTitle { get { return (_done ? ((char)0x2713).ToString() + "  " : "") + Title; } }
    }
}
'@
}

function Show-RTAudioWindow {
    param([Parameter(Mandatory)][string]$EnginePath)

    $script:IsAdmin = Test-RTAdmin
    $script:LastScan = $null
    $script:SessionResults = New-Object System.Collections.ArrayList
    $script:Sync = [hashtable]::Synchronized(@{ Status = '' })
    $script:Job = $null
    $script:Suppress = $false

    [xml]$xaml = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'MainWindow.xaml')
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $script:C = @{ Window = $window }
    $xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
        $name = $_.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -First 1 -ExpandProperty Value
        $script:C[$name] = $window.FindName($name)
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = 'Bypass'
    $iss.ImportPSModule(@($EnginePath))
    $script:Runspace = [runspacefactory]::CreateRunspace($iss)
    $script:Runspace.Open()

    if (-not $script:IsAdmin) {
        $C.AdminBanner.Visibility = 'Visible'
        foreach ($b in 'ApplyButton', 'UndoSelectedButton', 'UndoAllButton') { $C[$b].IsEnabled = $false }
        $C.RestorePointBox.IsEnabled = $false
    }

    $C.ScanButton.Add_Click({ Start-RTScanJob })
    $C.ReportButton.Add_Click({ Export-RTReportFromUi })
    $C.FindingsGrid.Add_SelectionChanged({ Show-RTFinding $C.FindingsGrid.SelectedItem })
    $C.FindingsGrid.Add_MouseDoubleClick({ $f = $C.FindingsGrid.SelectedItem; if ($f -and $f.GuideId) { Open-RTGuidePage $f.GuideId } })
    $C.FindingGuideButton.Add_Click({ $f = $C.FindingsGrid.SelectedItem; if ($f) { Open-RTGuidePage $f.GuideId } })
    $C.TweaksGrid.Add_SelectionChanged({ Show-RTTweak $C.TweaksGrid.SelectedItem })
    $C.PresetBox.Add_SelectionChanged({ if (-not $script:Suppress) { Set-RTPresetSelection $C.PresetBox.SelectedItem.Content } })
    $C.OnlyOpenBox.Add_Click({ if ($script:TweakView) { $script:TweakView.Refresh() } })
    $C.ApplyButton.Add_Click({ Start-RTApplyJob -DryRun:$false })
    $C.DryRunButton.Add_Click({ Start-RTApplyJob -DryRun:$true })
    $C.UndoSelectedButton.Add_Click({ Start-RTUndoJob -All:$false })
    $C.UndoAllButton.Add_Click({ Start-RTUndoJob -All:$true })
    $C.GuideList.Add_SelectionChanged({ Show-RTGuidePage $C.GuideList.SelectedItem })
    $C.GuideDoneBox.Add_Click({
        $p = $C.GuideList.SelectedItem
        if ($p) { $p.Done = [bool]$C.GuideDoneBox.IsChecked; Set-RTGuideDone -Id $p.Id -Done $p.Done }
    })

    Update-RTGuideList (Get-RTGuide -Context @{ Daws = @() } -All)
    $window.Add_ContentRendered({ Start-RTScanJob })
    $window.Add_Closed({ try { $script:Runspace.Close() } catch { } })
    [void]$window.ShowDialog()
}

#region Background jobs -------------------------------------------------------

function Set-RTBusy {
    param([bool]$Busy, [string]$Text)
    $C.Busy.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    foreach ($b in 'ScanButton', 'ApplyButton', 'DryRunButton', 'UndoSelectedButton', 'UndoAllButton', 'ReportButton') {
        $enable = -not $Busy
        if ($b -in 'ApplyButton', 'UndoSelectedButton', 'UndoAllButton') { $enable = $enable -and $script:IsAdmin }
        if ($b -eq 'ReportButton') { $enable = $enable -and [bool]$script:LastScan }
        $C[$b].IsEnabled = $enable
    }
    if ($Text) { $C.StatusText.Text = $Text }
}

function Start-RTJob {
    param([string]$Label, [scriptblock]$Work, [hashtable]$Parameters, [scriptblock]$OnDone)
    if ($script:Job) { return }
    Set-RTBusy $true $Label
    $script:Sync.Status = $Label
    $ps = [powershell]::Create()
    $ps.Runspace = $script:Runspace
    [void]$ps.AddScript($Work.ToString()).AddParameter('Sync', $script:Sync)
    foreach ($k in $Parameters.Keys) { [void]$ps.AddParameter($k, $Parameters[$k]) }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Timer = $timer; OnDone = $OnDone }
    $timer.Add_Tick({
        $j = $script:Job
        $C.StatusText.Text = $script:Sync.Status
        if (-not $j.Handle.IsCompleted) { return }
        $j.Timer.Stop()
        $out = $null; $err = $null
        try { $out = $j.PS.EndInvoke($j.Handle) } catch { $err = $_.Exception.InnerException; if (-not $err) { $err = $_.Exception } }
        if (-not $err -and $j.PS.Streams.Error.Count) { $err = $j.PS.Streams.Error[0].Exception }
        $j.PS.Dispose()
        $script:Job = $null
        Set-RTBusy $false 'Ready.'
        if ($err) {
            Write-RTUiLog "ERROR: $($err.Message)"
            [System.Windows.MessageBox]::Show($err.Message, 'RTAudio Setup', 'OK', 'Error') | Out-Null
        }
        if ($out -and $out.Count) { & $j.OnDone $out[0] }
    })
    $timer.Start()
}

function Start-RTScanJob {
    $secs = [int]$C.LatencyBox.SelectedItem.Content
    Start-RTJob -Label 'Scanning...' -Parameters @{ LatencySeconds = $secs } -Work {
        param($Sync, $LatencySeconds)
        $global:RTSync = $Sync
        Invoke-RTScan -LatencySeconds $LatencySeconds -Progress { param($m) $global:RTSync.Status = $m }
    } -OnDone {
        param($scan)
        Update-RTView $scan
        $C.StatusText.Text = "Scan finished at $(Get-Date -Format 'HH:mm:ss')."
    }
}

function Get-RTSelectedRows { @($script:TweakRows | Where-Object Selected) }

function Start-RTApplyJob {
    param([switch]$DryRun)
    $rows = Get-RTSelectedRows
    if (-not $rows) { [System.Windows.MessageBox]::Show('No tweaks selected.', 'RTAudio Setup') | Out-Null; return }
    if (-not $DryRun) {
        $risky = @($rows | Where-Object Risk -ne 'Safe')
        $msg = "Apply $($rows.Count) tweak(s)?`n`nThe original values are backed up and can be restored with 'Undo'."
        if ($risky) { $msg += "`n`nNot marked Safe:`n  - " + (($risky | ForEach-Object { "$($_.Title) [$($_.Risk)]" }) -join "`n  - ") }
        if ($rows | Where-Object Reboot) { $msg += "`n`nSome changes take effect only after a reboot." }
        if ([System.Windows.MessageBox]::Show($msg, 'Confirm changes', 'YesNo', 'Question') -ne 'Yes') { return }
    }
    Start-RTJob -Label $(if ($DryRun) { 'Dry run...' } else { 'Applying...' }) `
        -Parameters @{ Ids = [string[]]@($rows | ForEach-Object Id); DryRun = [bool]$DryRun; NoRestorePoint = -not $C.RestorePointBox.IsChecked } -Work {
        param($Sync, $Ids, $DryRun, $NoRestorePoint)
        $global:RTSync = $Sync
        $p = { param($m) $global:RTSync.Status = $m }
        $results = @(Invoke-RTApply -Ids $Ids -DryRun:$DryRun -NoRestorePoint:$NoRestorePoint -Progress $p)
        $global:RTSync.Status = 'Re-checking...'
        [pscustomobject]@{ Results = $results; Scan = $(if (-not $DryRun) { Invoke-RTScan -LatencySeconds 0 -Progress $p }) }
    } -OnDone {
        param($r)
        Complete-RTChange -Results $r.Results -Scan $r.Scan -Verb $(if ($r.Scan) { 'Apply' } else { 'Dry run' })
    }
}

function Start-RTUndoJob {
    param([switch]$All)
    $applied = @(Get-RTAppliedTweaks)
    if (-not $applied) { [System.Windows.MessageBox]::Show('Nothing to undo: no tweaks have been applied by this tool.', 'RTAudio Setup') | Out-Null; return }
    if ($All) {
        $ids = @($applied | ForEach-Object Id)
        $msg = "Restore the original values of all $($ids.Count) tweak(s) applied by this tool?"
    } else {
        $appliedIds = @($applied | ForEach-Object Id)
        $ids = @(Get-RTSelectedRows | Where-Object { $appliedIds -contains $_.Id } | ForEach-Object Id)
        if (-not $ids) { [System.Windows.MessageBox]::Show("None of the selected tweaks has a backup. Tick tweaks marked 'saved' in the Backup column.", 'RTAudio Setup') | Out-Null; return }
        $msg = "Restore the original values of $($ids.Count) selected tweak(s)?"
    }
    if ([System.Windows.MessageBox]::Show($msg, 'Confirm undo', 'YesNo', 'Question') -ne 'Yes') { return }
    Start-RTJob -Label 'Reverting...' -Parameters @{ Ids = [string[]]$ids } -Work {
        param($Sync, $Ids)
        $global:RTSync = $Sync
        $p = { param($m) $global:RTSync.Status = $m }
        $results = @(Invoke-RTUndo -Ids $Ids -Progress $p)
        [pscustomobject]@{ Results = $results; Scan = (Invoke-RTScan -LatencySeconds 0 -Progress $p) }
    } -OnDone {
        param($r)
        Complete-RTChange -Results $r.Results -Scan $r.Scan -Verb 'Undo'
    }
}

function Complete-RTChange {
    param($Results, $Scan, [string]$Verb)
    Write-RTUiLog "--- $Verb ---"
    foreach ($x in $Results) { Write-RTUiLog ("{0,-18} {1}  {2}" -f $x.Outcome, $x.Title, $x.Detail) }
    if ($Verb -ne 'Dry run') { foreach ($x in $Results) { [void]$script:SessionResults.Add($x) } }
    if ($Scan) { Update-RTView $Scan -KeepSelection }

    $groups = $Results | Where-Object Outcome -ne 'Info' | Group-Object Outcome | ForEach-Object { "$($_.Count) $($_.Name)" }
    $summary = "$Verb finished: $($groups -join ', ')."
    $failed = @($Results | Where-Object Outcome -eq 'Failed')
    if ($failed) { $summary += "`n`nFailed:`n  - " + (($failed | ForEach-Object { "$($_.Title): $($_.Detail)" }) -join "`n  - ") }
    $info = $Results | Where-Object Outcome -eq 'Info' | ForEach-Object Detail
    if ($info) { $summary += "`n`n$($info -join "`n")" }
    $needsReboot = $Verb -ne 'Dry run' -and ($Results | Where-Object { $_.Reboot -and $_.Outcome -in 'Applied', 'AppliedUnverified', 'Reverted' })
    if ($Verb -eq 'Dry run') { $C.Tabs.SelectedIndex = 3 }
    if ($needsReboot) {
        $summary += "`n`nSome changes need a reboot. Reboot now?"
        if ([System.Windows.MessageBox]::Show($summary, 'RTAudio Setup', 'YesNo', 'Information') -eq 'Yes') { Restart-Computer -Force }
    } else {
        [System.Windows.MessageBox]::Show($summary, 'RTAudio Setup', 'OK', $(if ($failed) { 'Warning' } else { 'Information' })) | Out-Null
    }
    $C.StatusText.Text = $summary.Split("`n")[0]
}

#endregion

#region View updates -----------------------------------------------------------

function Write-RTUiLog {
    param([string]$Line)
    $C.LogBox.AppendText("$(Get-Date -Format 'HH:mm:ss')  $Line`r`n")
    $C.LogBox.ScrollToEnd()
}

function Update-RTView {
    param($Scan, [switch]$KeepSelection)
    $script:LastScan = $Scan
    $C.ReportButton.IsEnabled = $true
    $C.FindingsGrid.ItemsSource = @($Scan.Findings)

    $previous = @{}
    if ($KeepSelection -and $script:TweakRows) { foreach ($r in $script:TweakRows) { $previous[$r.Id] = $r.Selected } }
    $applied = @(Get-RTAppliedTweaks | ForEach-Object Id)
    $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[RTAudio.TweakRow]'
    foreach ($t in $Scan.Tweaks) {
        $row = New-Object RTAudio.TweakRow -Property @{
            Id = $t.Id; Category = $t.Category; Title = $t.Title; Why = $t.Why; Risk = $t.Risk; Desired = $t.Desired
            Reboot = $t.Reboot; Presets = [string[]]@($t.Presets); Status = $t.Status; Current = $t.Current
            AppliedText = $(if ($applied -contains $t.Id) { 'saved' } else { '' })
        }
        $row.Selected = $previous.ContainsKey($t.Id) -and $previous[$t.Id] -and $t.Status -ne 'Ok'
        $row.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'Selected') { Update-RTSelectionText; if (-not $script:Suppress) { Set-RTPresetBox 'Custom' } } })
        $rows.Add($row)
    }
    $script:TweakRows = $rows
    $C.TweaksGrid.ItemsSource = $rows
    $script:TweakView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($rows)
    $script:TweakView.Filter = [Predicate[object]] { param($r) -not $C.OnlyOpenBox.IsChecked -or $r.Status -ne 'Ok' }
    if (-not $KeepSelection) { Set-RTPresetSelection $C.PresetBox.SelectedItem.Content }
    Update-RTSelectionText

    $count = { param($sev) @($Scan.Findings | Where-Object Severity -eq $sev).Count }
    $open = @($Scan.Tweaks | Where-Object Status -eq 'NotOptimal').Count
    $dot = " $([char]0xB7) "
    $C.SubtitleText.Text = "$(& $count 'Problem') problem(s)$dot$(& $count 'Warning') warning(s)$dot$open tweak(s) not optimal${dot}scanned $($Scan.Timestamp.ToString('HH:mm'))"

    Update-RTGuideList (Get-RTGuide -Context $Scan.Context)
}

function Set-RTPresetBox {
    param([string]$Name)
    $script:Suppress = $true
    try { foreach ($i in $C.PresetBox.Items) { if ($i.Content -eq $Name) { $C.PresetBox.SelectedItem = $i } } } finally { $script:Suppress = $false }
}

function Set-RTPresetSelection {
    param([string]$Preset)
    if (-not $script:TweakRows -or $Preset -eq 'Custom') { return }
    $include = switch ($Preset) { 'Safe' { @('Safe') } 'Recommended' { @('Safe', 'Recommended') } default { @('Safe', 'Recommended', 'Aggressive') } }
    $script:Suppress = $true
    try {
        foreach ($r in $script:TweakRows) {
            $r.Selected = $r.Status -eq 'NotOptimal' -and @($r.Presets | Where-Object { $include -contains $_ }).Count -gt 0
        }
    } finally { $script:Suppress = $false }
    Update-RTSelectionText
}

function Update-RTSelectionText {
    $sel = @(Get-RTSelectedRows)
    $C.SelectionText.Text = "$($sel.Count) selected" + $(if ($sel | Where-Object Reboot) { ' (reboot needed)' } else { '' })
}

function Show-RTFinding {
    param($f)
    if (-not $f) { return }
    $C.FindingTitle.Text = "[$($f.Severity)] $($f.Title)"
    $C.FindingDetail.Text = $f.Detail
    $C.FindingAdvice.Text = $f.Advice
    $C.FindingGuideButton.Visibility = if ($f.GuideId -and ($script:GuideRows | Where-Object Id -eq $f.GuideId)) { 'Visible' } else { 'Collapsed' }
}

function Show-RTTweak {
    param($t)
    if (-not $t) { return }
    $C.TweakTitle.Text = $t.Title
    $C.TweakWhy.Text = $t.Why
    $C.TweakState.Text = "Current: $($t.Current)    Desired: $($t.Desired)    Risk: $($t.Risk)" + $(if ($t.Reboot) { '    Needs reboot' } else { '' }) + $(if ($t.AppliedText) { '    Original value backed up' } else { '' })
}

function Update-RTGuideList {
    param($Pages)
    $selectedId = if ($C.GuideList.SelectedItem) { $C.GuideList.SelectedItem.Id } else { $null }
    $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[RTAudio.GuideRow]'
    foreach ($p in $Pages) {
        $rows.Add((New-Object RTAudio.GuideRow -Property @{
            Id = $p.id; Title = $p.title; Category = $p.category; Summary = $p.summary; Done = [bool]$p.Done
            Steps = [string[]]@($p.steps); Actions = [string[]]@($(if ($p.PSObject.Properties['actions']) { $p.actions }))
        }))
    }
    $script:GuideRows = $rows
    $C.GuideList.ItemsSource = $rows
    if ($selectedId) { Open-RTGuidePage $selectedId -NoSwitch }
}

function Open-RTGuidePage {
    param([string]$Id, [switch]$NoSwitch)
    $row = $script:GuideRows | Where-Object Id -eq $Id | Select-Object -First 1
    if (-not $row) { return }
    $C.GuideList.SelectedItem = $row
    $C.GuideList.ScrollIntoView($row)
    if (-not $NoSwitch) { $C.Tabs.SelectedIndex = 2 }
}

function Show-RTGuidePage {
    param($p)
    $C.GuideActions.Children.Clear()
    if (-not $p) { return }
    $C.GuideTitle.Text = $p.Title
    $C.GuideSummary.Text = $p.Summary
    $i = 0
    $C.GuideSteps.ItemsSource = @($p.Steps | ForEach-Object { $i++; "$i.  $_" })
    $C.GuideDoneBox.IsChecked = $p.Done
    foreach ($a in $p.Actions) {
        $def = Get-RTGuideAction $a
        if (-not $def) { continue }
        $btn = New-Object System.Windows.Controls.Button -Property @{ Content = $def.Label; Tag = $a; Margin = (New-Object System.Windows.Thickness 0, 0, 8, 8) }
        $btn.Add_Click({
            param($s)
            $d = Get-RTGuideAction $s.Tag
            if ($d.ContainsKey('Confirm') -and [System.Windows.MessageBox]::Show($d.Confirm, 'RTAudio Setup', 'YesNo', 'Warning') -ne 'Yes') { return }
            try { Invoke-RTGuideAction $s.Tag } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'RTAudio Setup') | Out-Null }
        })
        [void]$C.GuideActions.Children.Add($btn)
    }
}

function Export-RTReportFromUi {
    if (-not $script:LastScan) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog -Property @{
        FileName = "RTAudio-Report-$(Get-Date -Format 'yyyyMMdd-HHmm').html"; Filter = 'HTML report|*.html'
        InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    }
    if (-not $dlg.ShowDialog()) { return }
    $path = Export-RTReport -Scan $script:LastScan -ApplyResults @($script:SessionResults) -Path $dlg.FileName
    Start-Process $path
}

#endregion
