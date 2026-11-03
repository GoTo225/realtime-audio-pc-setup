# Plugin hygiene: 32-bit plugins and plugin/sample library folders on slow or removable drives.
# Read-only, no admin needed. Only counts file names; never loads, hashes or opens plugins.
# Folder names come from environment variables (ProgramW6432 etc.), never from localized text.

function Get-RTPluginFolderSpecs {
    # Candidate folders: @{ Path; Kind = 'VST3'|'VST2'; Bits = 64|32 }. 64-bit paths come first.
    $pf64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { [Environment]::GetFolderPath('ProgramFiles') }
    $cf64 = if ($env:CommonProgramW6432) { $env:CommonProgramW6432 } else { [Environment]::GetFolderPath('CommonProgramFiles') }
    $pf86 = ${env:ProgramFiles(x86)}
    $cf86 = ${env:CommonProgramFiles(x86)}
    $specs = New-Object System.Collections.ArrayList
    $add = { param($p, $k, $b) if ($p) { [void]$specs.Add(@{ Path = "$p"; Kind = $k; Bits = $b }) } }
    & $add (Join-Path $cf64 'VST3') 'VST3' 64
    foreach ($view in @(@{ Key = 'SOFTWARE\VST'; Bits = 64 }, @{ Key = 'SOFTWARE\WOW6432Node\VST'; Bits = 32 })) {
        try {
            $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($view.Key)
            if ($k) { $v = $k.GetValue('VSTPluginsPath'); $k.Close(); if ($v) { & $add ([Environment]::ExpandEnvironmentVariables("$v").Trim('"')) 'VST2' $view.Bits } }
        } catch { }
    }
    foreach ($p in @((Join-Path $pf64 'VSTPlugins'), (Join-Path $pf64 'Steinberg\VSTPlugins'), (Join-Path $cf64 'Steinberg\VST2'), (Join-Path $cf64 'VST2'))) { & $add $p 'VST2' 64 }
    if ($cf86) { & $add (Join-Path $cf86 'VST3') 'VST3' 32 }
    if ($pf86) { foreach ($p in @((Join-Path $pf86 'VSTPlugins'), (Join-Path $pf86 'Steinberg\VSTPlugins'))) { & $add $p 'VST2' 32 } }
    if ($cf86) { & $add (Join-Path $cf86 'Steinberg\VST2') 'VST2' 32 }
    @($specs)
}

function Get-RTPluginCount {
    # Counts entries ending in $Extension below $Path (depth-limited). A .vst3 bundle folder counts
    # once and is not descended into. Unreadable folders are skipped.
    param([string]$Path, [string]$Extension, [int]$MaxDepth = 4, [int]$MaxDirs = 3000)
    $count = 0; $dirs = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Path, 0))
    while ($stack.Count -and $dirs -lt $MaxDirs) {
        $item = $stack.Pop(); $dirs++
        $entries = $null
        try { $entries = (New-Object IO.DirectoryInfo $item[0]).GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($e.Name.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { $count++; continue }
            if (($e.Attributes -band [IO.FileAttributes]::Directory) -and $item[1] -lt $MaxDepth) { $stack.Push(@($e.FullName, ($item[1] + 1))) }
        }
    }
    $count
}

function Resolve-RTFolderTarget {
    # Follows a junction/symlink at the folder itself (people move plugin folders to other drives that way).
    param([string]$Path)
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $i.PSObject.Properties['Target'] -and @($i.Target)[0]) { return "$(@($i.Target)[0])" }
    } catch { }
    $Path
}

function Get-RTNativeInstrumentsLibraries {
    # NI products register their content folder as ContentDir under HKLM\SOFTWARE\Native Instruments\<product>.
    $libs = New-Object System.Collections.ArrayList
    foreach ($root in 'SOFTWARE\Native Instruments', 'SOFTWARE\WOW6432Node\Native Instruments') {
        $k = $null
        try { $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($root) } catch { }
        if (-not $k) { continue }
        foreach ($n in $k.GetSubKeyNames()) {
            try {
                $s = $k.OpenSubKey($n)
                if ($s) { $v = $s.GetValue('ContentDir'); $s.Close(); if ($v) { [void]$libs.Add(@{ Name = $n; Path = "$v".Trim('"').TrimEnd('\') }) } }
            } catch { }
        }
        $k.Close()
    }
    @($libs)
}

$script:StorageMediaTypes = @{ 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
$script:StorageBusTypes = @{ 1 = 'SCSI'; 3 = 'ATA'; 6 = 'Fibre Channel'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 14 = 'Virtual'; 15 = 'File Backed Virtual'; 16 = 'Storage Spaces'; 17 = 'NVMe' }

function Get-RTDriveInfo {
    <#
      Drive letters -> @{ <letter> = @{ MediaType; BusType; Name } }. Uses the storage CIM classes directly:
      the Get-Partition/Get-PhysicalDisk cmdlets load the Storage module (~2 s cold).
    #>
    param([string[]]$Letters)
    $out = @{}
    $Letters = @($Letters | Where-Object { $_ } | ForEach-Object { $_.ToUpper() } | Sort-Object -Unique)
    if (-not $Letters) { return $out }
    $ns = 'root/Microsoft/Windows/Storage'
    $disks = @{}
    foreach ($l in $Letters) {
        $dt = ''
        try { $dt = "$((New-Object IO.DriveInfo $l).DriveType)" } catch { }
        if ($dt -eq 'Network') { $out[$l] = @{ MediaType = 'Network'; BusType = 'Network'; Name = 'Network drive' }; continue }
        $part = Get-CimInstance -Namespace $ns -ClassName MSFT_Partition -Filter "DriveLetter='$l'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $part) { continue }
        if (-not $disks.Count) {
            foreach ($d in @(Get-CimInstance -Namespace $ns -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue)) { $disks["$($d.DeviceId)"] = $d }
        }
        $pd = $disks["$($part.DiskNumber)"]
        if (-not $pd) { continue }
        $mt = [int]$pd.MediaType; $bt = [int]$pd.BusType
        $out[$l] = @{
            MediaType = $(if ($script:StorageMediaTypes.ContainsKey($mt)) { $script:StorageMediaTypes[$mt] } else { 'Unspecified' })
            BusType   = $(if ($script:StorageBusTypes.ContainsKey($bt)) { $script:StorageBusTypes[$bt] } else { 'Unknown' })
            Name      = "$($pd.FriendlyName)"
        }
    }
    $out
}

function Get-RTPluginFacts {
    # Folders: @{ Path; Target; Kind = VST3|VST2|Library; Bits; Count; Name }; Drives: see Get-RTDriveInfo.
    $folders = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($s in Get-RTPluginFolderSpecs) {
        $key = $s.Path.TrimEnd('\').ToLower()
        if ($seen.ContainsKey($key)) { continue }      # same folder registered for both views: keep the first (64-bit)
        $seen[$key] = $true
        if (-not [IO.Directory]::Exists($s.Path)) { continue }
        $ext = if ($s.Kind -eq 'VST3') { '.vst3' } else { '.dll' }
        $depth = if ($s.Kind -eq 'VST3') { 4 } else { 3 }
        [void]$folders.Add(@{ Path = $s.Path; Target = (Resolve-RTFolderTarget $s.Path); Kind = $s.Kind; Bits = $s.Bits; Count = (Get-RTPluginCount -Path $s.Path -Extension $ext -MaxDepth $depth); Name = '' })
    }
    foreach ($l in Get-RTNativeInstrumentsLibraries) {
        [void]$folders.Add(@{ Path = $l.Path; Target = $l.Path; Kind = 'Library'; Bits = 0; Count = 0; Name = $l.Name })
    }
    $letters = @($folders | ForEach-Object { Get-RTDriveLetter $_.Target } | Where-Object { $_ })
    @{ Folders = @($folders); Drives = (Get-RTDriveInfo -Letters $letters) }
}

function Get-RTDriveLetter {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):') { return $Matches[1].ToUpper() }
    ''
}

function Get-RTPluginFindings {
    <#
      Pure: Folders = @{ Path; Target; Kind; Bits; Count; Name } (Count = plugins found, unused for libraries);
      Drives = @{ <letter> = @{ MediaType; BusType; Name } }.
    #>
    param([object[]]$Folders, [hashtable]$Drives = @{})
    $Folders = @($Folders | Where-Object { $_ })

    # 32-bit plugins. A folder registered for both 32 and 64 bit was de-duplicated as 64-bit by the collector.
    $x86 = @($Folders | Where-Object { $_['Bits'] -eq 32 -and $_['Count'] -gt 0 })
    if ($x86) {
        $n = [int](($x86 | ForEach-Object { $_['Count'] } | Measure-Object -Sum).Sum)
        New-RTFinding -Id 'plugins.32bit' -Severity Info -Category 'Plugins' -Title "$n 32-bit plugin file(s) found" `
            -Detail (($x86 | ForEach-Object { "$($_['Path']) ($($_['Count']) $($_['Kind']))" }) -join '; ') `
            -Advice '64-bit DAWs can only use 32-bit plugins through a bridge (jBridge, Bitwig/REAPER/FL Studio built-in bridging), which costs CPU and can crash. Replace them with 64-bit versions, or remove ones you no longer use. A 32-bit VST2 folder may also hold non-plugin DLLs, so treat the count as an upper bound.' -GuideId 'plugins'
    }

    # Plugin folders / sample libraries on HDD, USB or network drives, grouped per drive.
    $byDrive = [ordered]@{}
    foreach ($f in $Folders) {
        $isPlugin = $f['Kind'] -ne 'Library'
        if ($isPlugin -and $f['Count'] -le 0) { continue }
        $target = if ($f['Target']) { "$($f['Target'])" } else { "$($f['Path'])" }
        $letter = Get-RTDriveLetter $target
        $d = if ($target -match '^\\\\') { @{ MediaType = 'Network'; BusType = 'Network'; Name = 'Network share' } } elseif ($letter -and $Drives.ContainsKey($letter)) { $Drives[$letter] } else { $null }
        if (-not $d) { continue }
        $slow = $d['MediaType'] -eq 'HDD'
        $usb = $d['BusType'] -eq 'USB'
        $network = $d['MediaType'] -eq 'Network'
        if (-not ($slow -or $usb -or $network)) { continue }
        $key = if ($letter) { $letter } else { 'UNC' }
        if (-not $byDrive.Contains($key)) { $byDrive[$key] = @{ Drive = $d; Slow = $slow; Usb = $usb; Network = $network; Plugins = New-Object System.Collections.ArrayList; Libraries = New-Object System.Collections.ArrayList } }
        if ($isPlugin) { [void]$byDrive[$key].Plugins.Add($target) } else { [void]$byDrive[$key].Libraries.Add("$($f['Name'])") }
    }
    foreach ($key in $byDrive.Keys) {
        $g = $byDrive[$key]
        $what = if ($g.Plugins.Count -and $g.Libraries.Count) { 'Plugin folders and sample libraries' } elseif ($g.Plugins.Count) { 'Plugin folders' } else { 'Sample libraries' }
        $kind = if ($g.Network) { 'a network drive' } elseif ($g.Slow -and $g.Usb) { 'an external USB hard disk' } elseif ($g.Slow) { 'a hard disk (HDD)' } else { 'a USB drive' }
        $where = if ($key -eq 'UNC') { 'network share' } else { "drive $($key):" }
        $libs = @($g.Libraries | Sort-Object -Unique)
        $detailParts = @()
        if ($g.Plugins.Count) { $detailParts += "Plugins: $(($g.Plugins | Sort-Object -Unique) -join ', ')" }
        if ($libs) { $detailParts += "Libraries ($($libs.Count)): $(($libs | Select-Object -First 8) -join ', ')$(if ($libs.Count -gt 8) { ', ...' } else { '' })" }
        $detailParts += "$($g.Drive['Name']) ($($g.Drive['BusType']), $($g.Drive['MediaType']))"
        $severity = if ($g.Network -or ($g.Slow -and $g.Usb) -or ($g.Usb -and $g.Plugins.Count)) { 'Warning' } else { 'Info' }
        $advice = @()
        if ($g.Slow -or $g.Network) { $advice += 'Projects load slowly and disk streaming limits the number of sampled voices; a dropout-free session needs the samples on an SSD (NVMe or SATA).' }
        if ($g.Usb -or $g.Network) { $advice += 'If the drive is not connected when the DAW starts, plugins or samples go missing; external drives also share the USB bus with the audio interface.' }
        if ($g.Plugins.Count) { $advice += 'Keep plugin DLL/VST3 folders on the internal system SSD; only large sample content belongs on a second drive.' }
        New-RTFinding -Id "plugins.drive.$key" -Severity $severity -Category 'Plugins' -Title "$what on $kind ($where)" `
            -Detail ($detailParts -join '. ') -Advice ($advice -join ' ') -GuideId 'plugins'
    }
}

Register-RTDetector -Id 'plugins' -Detect {
    param($ctx)
    $f = Get-RTPluginFacts
    Get-RTPluginFindings -Folders $f.Folders -Drives $f.Drives
}
