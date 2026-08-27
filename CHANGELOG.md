# Changelog

## Unreleased

- Verify the live display topology after every MultiMonitorTool profile load.
- Recover from false-success loads by waking outputs with Windows DisplaySwitch
  and retrying the requested profile.
- Add configurable External, Extend, and None recovery modes; External keeps a
  laptop panel off when switching between two external displays.
- Preserve and restore the normal Steam desktop window rectangle around Big
  Picture transitions, clamped to the desktop monitor's work area.

## 0.2.0 - 2026-08-27

- Added dynamic desktop audio snapshot and restoration.
- Added TV playback endpoint selection using stable Windows Item IDs.
- Added SoundVolumeView endpoint activation waits, verification, and retries.
- Added guided dependency download, display-profile capture, audio selection,
  login-task installation, and watcher launch.
- Added public-repository documentation, third-party notices, validation tests,
  and GitHub issue/workflow metadata.

## 0.1.0 - 2026-08-27

- Added event-driven Steam Big Picture detection with watchdog fallback.
- Added transition debouncing, MultiMonitorTool profiles, logging, retries, and
  Task Scheduler startup.
