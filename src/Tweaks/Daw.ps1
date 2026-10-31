# DAW-specific tweaks; only offered when the DAW is installed.

Register-RTTweakProvider {
    param($ctx)
    if (-not ($ctx.Daws | Where-Object { $_.Name -eq 'FL Studio' })) { return }
    @{
        Id = 'daw.flstudio-priority'; Category = 'DAW'; Risk = 'Moderate'; Presets = @(); Order = 70; Kind = 'Registry'
        Title = 'Always start FL Studio (FL64.exe) with high CPU priority'
        Why = 'Windows starts FL Studio at normal priority, so other programs compete with it for CPU time. High priority lets its threads win. Trade-off: when a project maxes out the CPU, the rest of the desktop can feel sluggish. Takes effect the next time FL Studio starts.'
        Params = @{ Values = @(@{
            Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FL64.exe\PerfOptions'
            Name = 'CpuPriorityClass'; Value = 3
        }) }
    }
}
