# Vendor control/mixer software for connected audio interfaces. Read-only, no admin needed.
#
# Keyed by the same vendor names as $script:VendorProfiles (Inventory.ps1). Per connected interface the
# FIRST entry whose Vendor matches its KnownVendor, whose Device pattern matches its name ('' = any)
# and whose Exclude pattern does not, applies. Pattern is matched against uninstall DisplayNames
# (product names set by the vendor, not localized). Required = routing does not work without it.
# Deliberately left out (the app ships with the driver, or not sure enough which models need what):
#   RME (TotalMix FX is part of the driver), MOTU (Pro Audio installer = driver), Native Instruments
#   (control panel is part of the driver; Native Access is not needed), Behringer (driver includes the
#   control panel), Audient EVO / ORIA, Antelope, Apogee, Elektron (Overbridge = driver, see ASIO check).
$script:VendorApps = @(
    @{ Vendor = 'Focusrite'; Device = 'Vocaster'; Exclude = ''; App = 'Vocaster Hub'; Pattern = 'Vocaster Hub'; Required = $false }
    @{ Vendor = 'Focusrite'; Device = 'Saffire'; Exclude = ''; App = 'Saffire MixControl'; Pattern = 'Saffire MixControl'; Required = $false }
    @{ Vendor = 'Focusrite'; Device = ''; Exclude = ''; App = 'Focusrite Control'; Pattern = '^Focusrite Control'; Required = $false }
    @{ Vendor = 'Universal Audio'; Device = 'Apollo|Arrow|Thunderbolt|Satellite'; Exclude = ''; App = 'UAD Console (UAD Software / UA Connect)'; Pattern = 'Universal Audio|\bUAD\b|UA Connect'; Required = $true }
    @{ Vendor = 'Universal Audio'; Device = ''; Exclude = ''; App = 'UA Connect'; Pattern = 'UA Connect|Universal Audio|\bUAD\b'; Required = $false }
    @{ Vendor = 'PreSonus'; Device = ''; Exclude = ''; App = 'Universal Control'; Pattern = 'Universal Control'; Required = $false }
    @{ Vendor = 'Yamaha / Steinberg'; Device = '\bUR\d{2,3}C\b|\bUR-RT|\bUR242\b|\bUR44\b|\bUR824\b'; Exclude = ''; App = 'dspMixFx'; Pattern = 'dspMixFx'; Required = $false }
    @{ Vendor = 'Audient'; Device = '\biD\d{1,2}\b'; Exclude = ''; App = 'Audient iD'; Pattern = 'Audient iD|^iD\b'; Required = $false }
    @{ Vendor = 'Arturia'; Device = 'MiniFuse'; Exclude = ''; App = 'MiniFuse Control Center'; Pattern = 'MiniFuse Control Center'; Required = $false }
    @{ Vendor = 'Arturia'; Device = 'AudioFuse'; Exclude = ''; App = 'AudioFuse Control Center'; Pattern = 'AudioFuse Control Center'; Required = $false }
    @{ Vendor = 'Solid State Logic'; Device = '\bSSL ?12\b'; Exclude = ''; App = 'SSL 360'; Pattern = 'SSL ?360'; Required = $false }
)

function Get-RTUninstallDisplayNames {
    # DisplayNames from HKLM (64/32-bit views) and HKCU. The .NET registry API is ~30x faster than
    # Get-ItemProperty over the Uninstall keys.
    $names = New-Object System.Collections.ArrayList
    foreach ($hive in @([Microsoft.Win32.Registry]::LocalMachine, [Microsoft.Win32.Registry]::CurrentUser)) {
        foreach ($sub in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            $k = $null
            try { $k = $hive.OpenSubKey($sub) } catch { }
            if (-not $k) { continue }
            foreach ($n in $k.GetSubKeyNames()) {
                try {
                    $s = $k.OpenSubKey($n)
                    if ($s) { $v = $s.GetValue('DisplayName'); if ($v) { [void]$names.Add("$v") }; $s.Close() }
                } catch { }
            }
            $k.Close()
        }
    }
    @($names | Sort-Object -Unique)
}

function Get-RTVendorAppEntry {
    # Pure: the VendorApps entry that applies to one interface, or $null.
    param($Interface, [object[]]$Table = $script:VendorApps)
    $v = "$($Interface.KnownVendor)"
    if (-not $v) { return $null }
    foreach ($e in $Table) {
        if ($e.Vendor -ne $v) { continue }
        if ($e.Device -and "$($Interface.Name)" -notmatch $e.Device) { continue }
        if ($e.Exclude -and "$($Interface.Name)" -match $e.Exclude) { continue }
        return $e
    }
    $null
}

function Get-RTVendorAppFindings {
    <#
      Pure: Interfaces = objects with Name, KnownVendor, Enabled; Installed = uninstall DisplayNames.
      One finding per app (several interfaces of the same vendor share it).
    #>
    param([object[]]$Interfaces, [string[]]$Installed, [object[]]$Table = $script:VendorApps)
    $byApp = [ordered]@{}
    foreach ($i in @($Interfaces | Where-Object { $_ -and $_.Enabled })) {
        $e = Get-RTVendorAppEntry -Interface $i -Table $Table
        if (-not $e) { continue }
        if (-not $byApp.Contains($e.App)) { $byApp[$e.App] = @{ Entry = $e; Devices = New-Object System.Collections.ArrayList } }
        if ($byApp[$e.App].Devices -notcontains $i.Name) { [void]$byApp[$e.App].Devices.Add("$($i.Name)") }
    }
    foreach ($app in $byApp.Keys) {
        $e = $byApp[$app].Entry
        $devices = $byApp[$app].Devices -join ', '
        $hit = @($Installed | Where-Object { $_ -match $e.Pattern })
        if ($hit) {
            New-RTFinding -Id "vendorapp.ok.$app" -Severity Ok -Category 'Audio driver' -Title "$($e.Vendor) software installed: $($hit -join ', ')" -Detail "For: $devices"
        } elseif ($e.Required) {
            New-RTFinding -Id "vendorapp.missing.$app" -Severity Warning -Category 'Audio driver' -Title "$app not found" `
                -Detail "For: $devices" -Advice "$($e.Vendor) interfaces of this type need it for input/output routing, monitoring and DSP. Install it from the $($e.Vendor) website." -GuideId 'asio-driver'
        } else {
            New-RTFinding -Id "vendorapp.missing.$app" -Severity Info -Category 'Audio driver' -Title "$app not found" `
                -Detail "For: $devices" -Advice "Many $($e.Vendor) interfaces need it for routing, direct monitoring or firmware updates. Not every model does; check the product page for yours." -GuideId 'asio-driver'
        }
    }
}

Register-RTDetector -Id 'vendor-apps' -Detect {
    param($ctx)
    $ifaces = @($ctx.Interfaces | Where-Object { $_ -and $_.Enabled -and (Get-RTVendorAppEntry -Interface $_) })
    if (-not $ifaces) { return }                         # skip the registry read when nothing applies
    Get-RTVendorAppFindings -Interfaces $ifaces -Installed (Get-RTUninstallDisplayNames)
}
