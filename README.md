# Steam Big Picture Display & Audio Switch

A small Windows 11 automation that switches to a TV-only display profile when
Steam enters Big Picture, sends audio to the TV, and restores the previous
desktop display and audio choices when Big Picture closes or Steam crashes.

The project is hardware-agnostic: it does not hard-code `Display 1`, monitor
names, resolutions, refresh rates, or a desktop audio device. Each user captures
two local display profiles and chooses their own TV playback endpoint during
setup.

## What it does

- Detects Steam's real Big Picture window, not merely a running `steam.exe`.
- Enables exactly the displays stored in the user's TV or Desktop profile.
- Restores resolution, refresh rate, topology, and primary-display state through
  MultiMonitorTool.
- Saves the current Windows playback defaults before entering Big Picture.
- Makes the selected TV endpoint the Console, Multimedia, and Communications
  default while Big Picture is active.
- Restores the previously saved endpoints on exit, so desktop audio can be
  headphones one day and laptop speakers the next.
- Debounces transitions and never reapplies a profile on every watchdog check.
- Recovers after Steam crashes and after missed Windows shell events.
- Logs every confirmed transition and profile/audio action.
- Runs as the signed-in user without administrator privileges.

## Quick start

1. Download or clone this repository.
2. Connect and power on the desktop monitor, TV, and any laptop/internal panel.
3. Double-click [`Start-Setup.cmd`](Start-Setup.cmd).
4. Follow the guided setup. It will:

   - download MultiMonitorTool and SoundVolumeView directly from NirSoft;
   - offer to install AutoHotkey v2 through `winget`;
   - walk through capturing the Desktop and TV display profiles;
   - list Windows playback endpoints and ask which one belongs to the TV;
   - restore the desktop layout;
   - offer to install the per-user login task and start the watcher.

5. Enter and exit Big Picture once, then inspect
   `Logs\SteamDisplaySwitch.log`.

The wizard intentionally cannot guess which physical monitor or audio endpoint a
user means. Those two choices are the only genuinely machine-specific setup.

To run a particular setup section again:

```powershell
.\Setup.ps1 -Mode Dependencies
.\Setup.ps1 -Mode Profiles
.\Setup.ps1 -Mode Audio
.\Setup.ps1 -Mode LoginTask
```

Use `-ForceDownload` to replace the two downloaded NirSoft executables.

## Big Picture detection

Current Steam for Windows creates a dedicated top-level Big Picture window with
all three of these properties:

- executable: `steamwebhelper.exe`
- Win32 class: `SDL_app`
- exact title: `Steam Big Picture Mode`

The watcher requires the complete triple. Ordinary Steam windows and background
web-helper processes therefore do not trigger a display switch.

Windows shell create/destroy events provide quick detection. A two-second
watchdog catches missed events and process crashes. Entry must remain true for
750 ms and exit must remain true for 2.5 seconds before changing anything.
Hidden windows count as active because Big Picture may be hidden behind a game.

If Valve changes the identity or localizes the window title, right-click the
watcher's tray icon while Big Picture is open and select **Log Steam windows**.
Copy the reported EXE, class, and title into the settings near the top of
`SteamBigPictureDisplaySwitch.ahk`.

## How audio restoration works

Immediately before the TV profile is loaded, the watcher queries and stores the
current endpoint ID for each Windows playback role:

- Console
- Multimedia
- Communications

It does not store a fixed "desktop speaker" setting. After the TV display is
enabled, the watcher waits up to ten seconds for its HDMI/DisplayPort audio
endpoint to become Active, then assigns it to all three roles.

On a normal exit or Steam crash, the saved endpoints are restored before the TV
display is disabled. If a saved endpoint is no longer available—for example,
Bluetooth headphones were turned off—Windows keeps its available fallback and
the watcher logs a warning. The stale snapshot is then discarded so it cannot
unexpectedly override a newer desktop choice days later.

The snapshot lives in `State\DesktopAudio.ini`. It survives a watcher crash, so
starting the watcher while Big Picture is no longer open restores the interrupted
desktop audio state.

SoundVolumeView's stable Windows **Item ID** is used instead of an ambiguous name
such as `TV` or `NVIDIA High Definition Audio`.

## Display profile guidance

The wizard opens Windows Display Settings and MultiMonitorTool for each profile.
For the Desktop profile:

1. Enable only the normal desktop display.
2. Disable the TV and laptop/internal display.
3. Make the desktop display primary.
4. Select its intended resolution and refresh rate.

For the TV profile:

1. Enable only the TV.
2. Disable the desktop and laptop/internal displays.
3. Make the TV primary.
4. Select its intended resolution and refresh rate.

Leave MultiMonitorTool's **Use Monitor ID In Load Config** option enabled. If
every display reports a unique, nonblank EDID serial, serial-number matching can
also be enabled. The watcher never references `DISPLAY1`, `DISPLAY2`, or
`DISPLAY3` itself.

Before testing, set **Steam Big Picture > Settings > Display > Preferred
Display** to **None**. Steam's own preferred-display feature changes the Windows
primary display and can race with the saved profiles.

## Manual profile test

Do not enable login startup until both commands independently produce the correct
single-display topology:

```powershell
& '.\Tools\MultiMonitorTool.exe' /LoadConfig '.\Profiles\TV.cfg'
& '.\Tools\MultiMonitorTool.exe' /LoadConfig '.\Profiles\Desktop.cfg'
```

Then run `SteamBigPictureDisplaySwitch.ahk` and test:

1. Normal Steam background operation causes no switch.
2. Entering Big Picture loads the TV profile once and selects TV audio.
3. Launching a game does not restore the desktop while Big Picture is hidden.
4. Exiting Big Picture restores the display profile and the audio endpoint that
   was default immediately before entry.
5. Ending Steam from Task Manager while Big Picture is open restores the desktop
   after the exit debounce.

## Files and local state

```text
Steam Big Picture Display Switch\
  SteamBigPictureDisplaySwitch.ahk   watcher
  Setup.ps1                          guided setup
  Start-Setup.cmd                    double-click setup entry point
  Install-LoginTask.ps1              Task Scheduler installer/remover
  Config.example.ini                 documented config shape
  Config.ini                         local TV audio ID; ignored by Git
  Profiles\
    Desktop.cfg                      local; ignored by Git
    TV.cfg                           local; ignored by Git
  Tools\
    MultiMonitorTool.exe             downloaded; ignored by Git
    SoundVolumeView.exe              downloaded; ignored by Git
  State\DesktopAudio.ini             temporary crash-recovery state
  Logs\SteamDisplaySwitch.log        runtime log
```

Machine-specific profiles, endpoint IDs, downloaded binaries, state, and logs
are excluded by `.gitignore`.

## Login startup and removal

The setup wizard can install a per-user Task Scheduler task named **Steam Big
Picture Display Switch**. It runs only in the interactive user session, at normal
privilege, and is configured to restart after an unexpected failure.

Install or update it manually:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-LoginTask.ps1
```

Remove it without deleting profiles or logs:

```powershell
.\Install-LoginTask.ps1 -Remove
```

## Tray commands

- **Reapply current profile** — manually reruns the appropriate display/audio
  transition.
- **Restore saved desktop audio** — consumes a crash-recovery audio snapshot.
- **Log Steam windows** — records Steam top-level EXE/class/title identities.
- **Open log** — opens the troubleshooting log in Notepad.

## MultiMonitorTool limitations

MultiMonitorTool configurations store Windows display topology, primary state,
resolution, position, orientation, color depth, and an integer
`DisplayFrequency`. That is normally sufficient for high-refresh desktop
monitors and 4K 60 Hz TVs.

It does not explicitly profile G-SYNC/VRR, HDR, per-output color format/bit
depth, or every NVIDIA Control Panel option. Windows and the GPU driver often
retain those settings per monitor, but test several round trips and retest after
GPU-driver updates. If those settings do not survive, use
[DisplayMagician](https://github.com/terrymacdonald/DisplayMagician) as a more
comprehensive profile backend; the Big Picture state machine can stay the same.

MultiMonitorTool 2.15 and newer internally applies configurations multiple times
to work around Windows 11 24H2 failures. This watcher still invokes it only once
per transition. If switching is reliable but flickers excessively, carefully
reduce `MonitorsConfigNumOfCalls` in `Tools\MultiMonitorTool.cfg` from the default
5 to 3 and retest both directions.

## Troubleshooting

- **No switch:** Check the exact paths in the file layout and open the watcher
  log.
- **Big Picture not detected:** Use **Log Steam windows** and update the three
  selectors in the watcher.
- **Wrong monitor:** Re-enable Monitor ID matching and recreate both profiles.
- **TV audio missing from setup:** Load the TV profile first. Windows often does
  not expose HDMI audio while that display is disconnected.
- **TV audio selection fails:** Rerun `Setup.ps1 -Mode Audio` after a driver or
  HDMI-port change; Windows endpoint IDs can change when drivers are rebuilt.
- **Antivirus warns about NirSoft:** The setup downloads from NirSoft's HTTPS
  URLs and prints each executable's SHA-256. NirSoft tools are unsigned and are
  sometimes classified as administrative utilities. Review the download URLs
  and source documentation before allowing them.
- **Windows 11 profile APIs stop working:** Change one display setting manually
  or reconnect the affected display, then retry, as noted by NirSoft.

## Third-party tools

The repository does not redistribute third-party executables. `Setup.ps1`
downloads current x64 archives directly from their authors:

- [NirSoft MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html)
- [NirSoft SoundVolumeView](https://www.nirsoft.net/utils/sound_volume_view.html)
- [AutoHotkey v2](https://www.autohotkey.com/), optionally installed from the
  `AutoHotkey.AutoHotkey` winget package

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Development

The project targets Windows 11, Windows PowerShell 5.1+, and AutoHotkey v2. The
GitHub Actions workflow parses every PowerShell file and validates the AHK script
with a temporary official AutoHotkey v2 runtime. It never applies a display or
audio profile in CI.

Contributions are welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md).

