# RTAudio Setup

Tunes Windows 10/11 for real-time audio (FL Studio, Cubase, Ableton Live, REAPER, Bitwig, Studio One, Pro Tools).
It **scans** for problems, lets you **choose** which fixes to apply, **backs up** every original value so it can **undo** them,
and **guides** you through the steps it cannot do itself (BIOS, DAW settings, drivers, cabling).

No installation needed: plain Windows PowerShell 5.1 + WPF.

## Quick check: is this PC suitable for audio?

Double-click **`Check-Audio.cmd`** (read-only, no administrator rights, about 25 seconds; works from a USB stick, e.g. to check a laptop before buying it). It opens the tool without elevation and shows the verdict at the top of the Findings tab; hover an area for details:

- **Verdict**: *Suitable*, *Suitable with limits* or *Not well suited*, and the smallest buffer size that ran without dropouts.
- **Areas**: CPU, memory, storage, audio interface, audio driver, power, Windows tuning, real-time performance. Each is marked **Hardware** (a limit of the machine), **Setup** (fixable with this tool, a driver or a manual step) or **Measured**.
- **Real-time probe**: an MMCSS "Pro Audio" thread (the scheduling class DAWs use) simulates an audio callback every 64 samples at 48 kHz for 10 s and records how late each one finishes (DPC/interrupt load, scheduling delays, CPU throttling). From that it predicts the stalls per minute at 64-1024 samples, assuming the DAW uses 50% of each buffer period. It measures the PC, not the audio interface's driver: confirm with LatencyMon and your DAW.

- **Which driver**: when the tool runs as administrator, a kernel DPC/ISR trace (ETW, like LatencyMon) runs alongside the probe and names the drivers with the longest interruptions, e.g. *ndis.sys (network)*, with what to do about them. The quick check runs without administrator rights and skips this.
- **Before/after**: every probe run is saved (`%LOCALAPPDATA%\RTAudio\probe-history.json`, newest 50) and compared with the previous one, e.g. *"stable buffer 256 -> 128 samples; stalls/min 128: 24 -> 0"*. After applying or undoing tweaks the GUI measures again automatically, so you see whether a change helped. Short runs vary from run to run; confirm a change with a longer run.
- **Soak test**: choose *1 min*, *3 min* or *5 min* next to *Real-time probe* and use the PC normally while it runs, to catch rare spikes a 10 s idle run misses. *Stop probe* ends it early and keeps what was measured.

The full GUI (`Start-RTAudio.cmd`) shows the same verdict after every scan. Console variant: `.\RTAudio.ps1 -Check [-ProbeSeconds 180]`.

## Use it

Double-click **`Start-RTAudio.cmd`** (asks for administrator rights). Then:

1. **Findings**: the audio readiness verdict, and what the scan found (whether the interface's own ASIO driver is installed, drivers for other brands or disconnected devices, broken or 32-bit-only ASIO registrations, audio interface, USB hubs, devices sharing the interface's USB controller, add-on USB controllers, Windows sample rate and enhancements of the interface, default playback device, DPC/interrupt load and the drivers causing it (as administrator), memory channels and speed (XMP/EXPO), BIOS/GPU/network driver age, the interface vendor's control software, 32-bit plugins and plugins or sample libraries on slow or external drives, CPU throttling, Memory Integrity, background apps, storage, pending reboots, ...). Double-click a finding to open the matching guide page.
2. **Tweaks**: pick a preset (*Safe*, *Recommended*, *Aggressive*) or tick tweaks yourself. *Dry run* shows what would change; *Apply selected* creates a System Restore point, backs up the current values and applies them. *Undo selected* or *Undo everything* restores the originals.
3. **Manual steps**: a checklist for what has to be done by hand, with buttons that open the right Windows panel (or reboot into the BIOS). Pages are filtered to your machine (installed DAWs, NVIDIA GPU, laptop).
4. **Studio mode**: temporary settings for a session, switched on before recording and off afterwards: quit background apps (sync, chat, launchers, RGB tools; restarted afterwards), pause Windows Update for 24 h, pause search indexing, switch to the performance power plan, and optionally turn off Wi-Fi and Bluetooth. Its state is kept in `%ProgramData%\RTAudio\studio.json`, so ending it works even after a crash or reboot.
5. **Export report**: HTML summary of findings, tweak states and the changes made in this session.

Without admin rights (`RTAudio.ps1 -NoElevate`) the GUI is scan-only.

### Command line

```powershell
.\RTAudio.ps1 -Check                                           # quick suitability check, read-only
.\RTAudio.ps1 -Scan -LatencySeconds 20 -Report .\report.html   # full read-only scan (incl. probe)
.\RTAudio.ps1 -List                                            # all tweak ids + status
.\RTAudio.ps1 -Preset Recommended -DryRun                      # preview
.\RTAudio.ps1 -Preset Recommended                              # apply (elevated prompt)
.\RTAudio.ps1 -Apply power.usb-suspend,bg.system-sounds        # apply specific tweaks
.\RTAudio.ps1 -Undo                                            # restore everything
.\RTAudio.ps1 -Undo -UndoIds power.plan                        # restore one
.\RTAudio.ps1 -Guide                                           # print manual steps
.\RTAudio.ps1 -Studio Status                                   # studio mode actions and state
.\RTAudio.ps1 -Studio On -StudioActions studio.apps,studio.wifi  # start (default actions if omitted)
.\RTAudio.ps1 -Studio Off                                      # end and restore
```

## Presets

Presets are cumulative: *Aggressive* includes *Recommended*, which includes *Safe*. Tweaks without a preset (Defender exclusions, FL Studio high priority, disabling individual audio devices) are never selected automatically. DAW-specific tweaks only appear when that DAW is installed.

| Preset | Contains |
|---|---|
| Safe | High/Ultimate Performance plan, USB selective suspend off, MMCSS SystemResponsiveness 10, Game DVR off |
| Recommended | + PCIe ASPM off, no core parking, disks never sleep, Fast Startup off, "Background services" scheduling, no system sounds, no toast notifications, remove forced HPET, disable GPU/HDMI audio *if a dedicated interface is present*, stop Windows from powering down the USB path of the interface (per device: interface, hubs, root hub, controller) |
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
Start-RTAudio.cmd      double-click launcher (GUI)
Check-Audio.cmd        double-click quick check (GUI, read-only, no elevation)
src/Engine.psm1        tweak registry, scan, apply/backup/undo, guide, report
src/Detect/            inventory (DAWs, audio devices, ASIO, latency sampling), read-only checks,
                       real-time probe (Probe.ps1), kernel DPC/ISR trace (DriverTrace.ps1), USB topology (Usb.ps1),
                       audio endpoints (Endpoints.ps1) and the readiness verdict (Readiness.ps1)
src/Tweaks/            tweak definitions by category; Devices.ps1 / UsbPower.ps1 generate per-device tweaks, Daw.ps1 per-DAW tweaks
src/Studio/            studio mode (temporary session settings, restored on exit)
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

## License

MIT, see [LICENSE](LICENSE).
