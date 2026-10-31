# Things running in the background that interrupt audio. HKCU values apply to the user running the tool.

Register-RTTweak @{
    Id = 'bg.game-dvr'; Category = 'Background'; Risk = 'Safe'; Presets = @('Safe'); Kind = 'Registry'
    Title = 'Disable Xbox Game Bar background recording'
    Why = 'Game DVR keeps a capture pipeline (and GPU encoder) ready in the background, which hooks into the audio stack.'
    Params = @{ Values = @(
        @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 }
    ) }
}

Register-RTTweak @{
    Id = 'bg.notifications'; Category = 'Background'; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'Registry'
    Title = 'Turn off toast notifications'
    Why = 'Notification popups play sounds through the default device and can steal the audio device or focus mid-take. Takes effect after signing out.'
    Params = @{ Values = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0 }) }
}

function Get-RTSoundEventKeys {
    Get-ChildItem -Path 'HKCU:\AppEvents\Schemes\Apps' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq '.Current' }
}

Register-RTTweak @{
    Id = 'bg.system-sounds'; Category = 'Background'; Risk = 'Safe'; Presets = @('Recommended')
    Title = 'Set the sound scheme to "No Sounds"'
    Why = 'System sounds open the Windows audio engine on your interface at their own sample rate. With a shared device that can cause clicks or a sample-rate switch while the DAW is running.'
    Test = {
        param($t)
        $active = @(Get-RTSoundEventKeys | Where-Object { "$($_.GetValue(''))" -ne '' }).Count
        New-RTTestResult -Status $(if ($active -eq 0) { 'Ok' } else { 'NotOptimal' }) -Current "$active event sound(s) active" -Desired 'none'
    }
    Backup = {
        param($t)
        @{
            Scheme = "$((Get-Item 'HKCU:\AppEvents\Schemes').GetValue(''))"
            Events = @(Get-RTSoundEventKeys | Where-Object { "$($_.GetValue(''))" -ne '' } | ForEach-Object { @{ Path = $_.PSPath; Value = "$($_.GetValue('', $null, 'DoNotExpandEnvironmentNames'))" } })
        }
    }
    Apply = {
        param($t)
        foreach ($k in Get-RTSoundEventKeys) { if ("$($k.GetValue(''))" -ne '') { Set-ItemProperty -LiteralPath $k.PSPath -Name '(default)' -Value '' } }
        Set-ItemProperty -LiteralPath 'HKCU:\AppEvents\Schemes' -Name '(default)' -Value '.None'
    }
    Revert = {
        param($t, $state)
        foreach ($e in @($state.Events)) { if ($e -and (Test-Path -LiteralPath $e.Path)) { Set-ItemProperty -LiteralPath $e.Path -Name '(default)' -Value $e.Value } }
        if ($state.Scheme) { Set-ItemProperty -LiteralPath 'HKCU:\AppEvents\Schemes' -Name '(default)' -Value $state.Scheme }
    }
}

Register-RTTweak @{
    Id = 'bg.transparency'; Category = 'Background'; Risk = 'Safe'; Presets = @('Aggressive'); Kind = 'Registry'
    Title = 'Turn off transparency effects'
    Why = 'Slightly reduces GPU/compositor work; mostly relevant on integrated graphics.'
    Params = @{ Values = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 0 }) }
}

Register-RTTweak @{
    Id = 'bg.windows-search'; Category = 'Background'; Risk = 'Moderate'; Presets = @('Aggressive'); Kind = 'Registry'; Reboot = $true
    Title = 'Disable the Windows Search indexing service'
    Why = 'The indexer crawls new files (e.g. freshly recorded audio, sample packs) and causes disk and CPU bursts. Start-menu and Explorer search become slower without it.'
    Params = @{ Values = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch'; Name = 'Start'; Value = 4 }) }
}
