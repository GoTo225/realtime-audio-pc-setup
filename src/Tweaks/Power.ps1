# Power tweaks. The plan switch runs first (Order 10) because the setting tweaks below
# change the *active* scheme.

$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:OwnSchemeName = 'RTAudio Ultimate Performance'
# Localized names of the built-in performance plans (scheme GUIDs of duplicated plans differ per machine).
# Kept ASCII ('.' for umlauts/accents): PS 5.1 reads BOM-less scripts as ANSI and powercfg output uses the OEM codepage.
$script:PerfPlanNamePattern = 'RTAudio|Ultimate|High performance|H.chstleistung|Ultimative Leistung|Hautes performances|Performances optimales|Prestazioni elevate|Alto rendimiento|M.ximo rendimiento'

function Get-RTPowerSchemes {
    foreach ($line in (powercfg /list 2>$null)) {
        if ($line -match '([0-9a-fA-F-]{36})\s+\((.+)\)(\s*\*)?\s*$') {
            [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2]; Active = [bool]$Matches[3] }
        }
    }
}

Register-RTTweak @{
    Id = 'power.plan'; Category = 'Power'; Order = 10; Risk = 'Safe'; Presets = @('Safe')
    Title = 'Use the Ultimate (or High) Performance power plan'
    Why = 'Balanced lets the CPU drop to low clocks and deep sleep states between audio buffers; waking up takes longer than a small ASIO buffer allows. Creates "RTAudio Ultimate Performance" (or falls back to High performance).'
    Test = {
        param($t)
        $active = Get-RTPowerSchemes | Where-Object Active | Select-Object -First 1
        if (-not $active) { return New-RTTestResult 'Unknown' 'could not read power plan' 'High/Ultimate Performance' }
        $ok = ($active.Guid -in @($script:HighPerfGuid, $script:UltimateGuid)) -or ($active.Name -match $script:PerfPlanNamePattern)
        New-RTTestResult -Status $(if ($ok) { 'Ok' } else { 'NotOptimal' }) -Current $active.Name -Desired 'High/Ultimate Performance'
    }
    Backup = { param($t) @{ Scheme = (Get-RTActiveSchemeGuid) } }
    Apply = {
        param($t)
        $own = Get-RTPowerSchemes | Where-Object Name -eq $script:OwnSchemeName | Select-Object -First 1
        $guid = if ($own) { $own.Guid } else { $null }
        if (-not $guid) {
            foreach ($src in $script:UltimateGuid, $script:HighPerfGuid) {
                $out = powercfg -duplicatescheme $src 2>$null
                if ($LASTEXITCODE -eq 0 -and "$out" -match '([0-9a-fA-F-]{36})') { $guid = $Matches[1]; break }
            }
            if (-not $guid) { throw 'This system does not offer a High/Ultimate Performance plan (typical for Modern Standby laptops). The individual power tweaks still work.' }
            powercfg /changename $guid $script:OwnSchemeName | Out-Null
        }
        powercfg /setactive $guid | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive $guid failed" }
    }
    Revert = {
        param($t, $state)
        if ($state.Scheme) { powercfg /setactive $state.Scheme | Out-Null }
        foreach ($s in Get-RTPowerSchemes | Where-Object { $_.Name -eq $script:OwnSchemeName -and -not $_.Active }) { powercfg /delete $s.Guid | Out-Null }
    }
}

Register-RTTweak @{
    Id = 'power.usb-suspend'; Category = 'Power'; Order = 20; Risk = 'Safe'; Presets = @('Safe'); Kind = 'PowerSetting'
    Title = 'Disable USB selective suspend'
    Why = 'Windows may power down USB ports it thinks are idle; USB audio interfaces then drop out or click.'
    Params = @{ Subgroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Value = 0 }
}

Register-RTTweak @{
    Id = 'power.pcie-aspm'; Category = 'Power'; Order = 20; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'PowerSetting'
    Title = 'Turn off PCI Express link state power management'
    Why = 'Waking a PCIe link from a power-saving state adds latency to USB controllers, GPUs and PCIe audio cards.'
    Params = @{ Subgroup = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Value = 0 }
}

Register-RTTweak @{
    Id = 'power.core-parking'; Category = 'Power'; Order = 20; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'PowerSetting'
    Title = 'Disable CPU core parking (on AC power)'
    Why = 'Parked cores have to be woken up when the audio engine spreads work over threads, which causes spikes in DAW CPU meters.'
    Params = @{ Subgroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '0cc5b647-c1df-4637-891a-dec35c318583'; Value = 100 }
}

Register-RTTweak @{
    Id = 'power.disk-idle'; Category = 'Power'; Order = 20; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'PowerSetting'
    Title = 'Never turn off hard disks (on AC power)'
    Why = 'A drive spinning up while streaming samples causes dropouts.'
    Params = @{ Subgroup = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Value = 0 }
}

Register-RTTweak @{
    Id = 'power.min-cpu'; Category = 'Power'; Order = 20; Risk = 'Moderate'; Presets = @('Aggressive'); Kind = 'PowerSetting'
    Title = 'Minimum processor state 100% (on AC power)'
    Why = 'Keeps the CPU at full clock. Lowest latency, but more heat, fan noise and power draw.'
    Params = @{ Subgroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Value = 100 }
}

Register-RTTweak @{
    Id = 'power.fast-startup'; Category = 'Power'; Order = 30; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'Registry'
    Title = 'Disable Fast Startup'
    Why = 'Fast Startup hibernates the kernel and drivers instead of shutting down, so driver problems survive a "shutdown" and USB devices are not reinitialised cleanly.'
    Params = @{ Values = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Value = 0 }) }
}
