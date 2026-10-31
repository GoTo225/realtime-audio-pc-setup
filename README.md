# RTAudio Setup

Tunes Windows 10/11 for real-time audio (FL Studio, Cubase, Ableton Live, REAPER, Bitwig, Studio One, Pro Tools).
It **scans** for problems, lets you **choose** which fixes to apply, **backs up** every original value so it can **undo** them,
and **guides** you through the steps it cannot do itself (BIOS, DAW settings, drivers, cabling).

No installation needed: plain Windows PowerShell 5.1 + WPF.

## Use it

Double-click **`Start-RTAudio.cmd`** (asks for administrator rights). Then:

1. **Findings**: what the scan found (ASIO drivers, audio interface, USB hubs, DPC/interrupt load, CPU throttling, Memory Integrity, background apps, storage, pending reboots, ...). Double-click a finding to open the matching guide page.
2. **Tweaks**: pick a preset (*Safe*, *Recommended*, *Aggressive*) or tick tweaks yourself. *Dry run* shows what would change; *Apply selected* creates a System Restore point, backs up the current values and applies them. *Undo selected* or *Undo everything* restores the originals.
3. **Manual steps**: a checklist for what has to be done by hand, with buttons that open the right Windows panel (or reboot into the BIOS). Pages are filtered to your machine (installed DAWs, NVIDIA GPU, laptop).
4. **Export report**: HTML summary of findings, tweak states and the changes made in this session.

Without admin rights (`RTAudio.ps1 -NoElevate`) the GUI is scan-only.

### Command line

```powershell
.\RTAudio.ps1 -Scan -LatencySeconds 20 -Report .\report.html   # read-only
.\RTAudio.ps1 -List                                            # all tweak ids + status
.\RTAudio.ps1 -Preset Recommended -DryRun                      # preview
.\RTAudio.ps1 -Preset Recommended                              # apply (elevated prompt)
.\RTAudio.ps1 -Apply power.usb-suspend,bg.system-sounds        # apply specific tweaks
.\RTAudio.ps1 -Undo                                            # restore everything
.\RTAudio.ps1 -Undo -UndoIds power.plan                        # restore one
.\RTAudio.ps1 -Guide                                           # print manual steps
```

## Presets

Presets are cumulative: *Aggressive* includes *Recommended*, which includes *Safe*. Tweaks without a preset (Defender exclusions, disabling individual audio devices) are never selected automatically.

| Preset | Contains |
|---|---|
| Safe | High/Ultimate Performance plan, USB selective suspend off, MMCSS SystemResponsiveness 10, Game DVR off |
| Recommended | + PCIe ASPM off, no core parking, disks never sleep, Fast Startup off, "Background services" scheduling, no system sounds, no toast notifications, remove forced HPET, disable GPU/HDMI audio *if a dedicated interface is present* |
| Aggressive | + minimum CPU state 100%, network throttling off, Windows Search off, transparency off, NIC Energy-Efficient Ethernet / interrupt moderation off, `disabledynamictick` |

Never changed automatically: BIOS settings, Memory Integrity/VBS, drivers, DAW settings. They are in the guide.

## Safety

- Every apply records the **original** value in `%ProgramData%\RTAudio\ledger.json` (re-applying keeps the first backup), so undo always returns to the state before the tool touched it.
- A System Restore point is created before applying (optional in the GUI, `-NoRestorePoint` on the CLI).
- Log: `%ProgramData%\RTAudio\rtaudio.log`.
- Power settings are only changed for AC (mains) power; battery behaviour stays as it was.

## Layout

```
RTAudio.ps1            entry point (GUI or CLI)
Start-RTAudio.cmd      double-click launcher
src/Engine.psm1        tweak registry, scan, apply/backup/undo, guide, report
src/Detect/            inventory (DAWs, audio devices, ASIO, latency sampling) and read-only checks
src/Tweaks/            tweak definitions by category; Devices.ps1 generates per-device tweaks
src/Guide/guide.json   manual step pages
src/UI/                WPF window (XAML) and its logic
tests/                 Pester 3.4 tests (Invoke-Pester .\tests)
```

### Adding a tweak

Registry and power settings need no code, just data:

```powershell
Register-RTTweak @{
    Id = 'bg.example'; Category = 'Background'; Risk = 'Safe'; Presets = @('Recommended'); Kind = 'Registry'
    Title = 'Short imperative title'
    Why = 'One or two sentences on why this helps real-time audio, and the trade-off.'
    Params = @{ Values = @(@{ Path = 'HKCU:\Some\Key'; Name = 'Value'; Value = 0 }) }
}
```

Anything else uses `Kind = 'Custom'` with `Test`, `Backup`, `Apply` and `Revert` scriptblocks (see `src/Tweaks/Power.ps1`).
Checks use `Register-RTDetector` and return `New-RTFinding` objects.

### Conventions

- Must work on any Windows display language: match on GUIDs, hardware IDs, registry values and WMI classes, never on localized text.
- Scripts stay ASCII-only (a test enforces this): Windows PowerShell 5.1 reads BOM-less files as ANSI.
