# CPU scheduling / MMCSS (Multimedia Class Scheduler Service) tweaks.

$script:MmcssKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

Register-RTTweak @{
    Id = 'sched.system-responsiveness'; Category = 'Scheduler'; Risk = 'Safe'; Presets = @('Safe'); Kind = 'Registry'; Reboot = $true
    Title = 'Reserve less CPU for background tasks (MMCSS SystemResponsiveness = 10)'
    Why = 'By default MMCSS keeps 20% of CPU time for low-priority work. 10 is the lowest effective value and gives audio threads more room.'
    Params = @{ Values = @(@{ Path = $script:MmcssKey; Name = 'SystemResponsiveness'; Value = 10 }) }
}

Register-RTTweak @{
    Id = 'sched.background-services'; Category = 'Scheduler'; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'Registry'
    Title = 'Processor scheduling: "Background services"'
    Why = 'Steinberg recommends this for ASIO: the audio driver runs as a background service, and this gives it fixed, longer time slices instead of favouring the foreground window.'
    Params = @{ Values = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; Name = 'Win32PrioritySeparation'; Value = 24 }) }
}

Register-RTTweak @{
    Id = 'sched.network-throttling'; Category = 'Scheduler'; Risk = 'Moderate'; Presets = @('Aggressive'); Kind = 'Registry'; Reboot = $true
    Title = 'Disable MMCSS network throttling'
    Why = 'Stops Windows from throttling network packet processing while multimedia is playing. Mainly helps network audio (Dante, AVB) and streaming setups.'
    # 0xFFFFFFFF as a signed DWORD
    Params = @{ Values = @(@{ Path = $script:MmcssKey; Name = 'NetworkThrottlingIndex'; Value = -1 }) }
}
