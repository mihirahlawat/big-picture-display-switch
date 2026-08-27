# Contributing

Thanks for helping improve the project.

## Before opening an issue

1. Use current Steam stable and current versions of the two NirSoft tools.
2. Reproduce the issue with manually loaded `Desktop.cfg` and `TV.cfg` first.
3. Use the tray menu's **Log Steam windows** command if detection is involved.
4. Include the relevant portion of `Logs\SteamDisplaySwitch.log`.

Do not upload `Config.ini` or the complete log without reviewing it. They can
contain local device labels, endpoint IDs, usernames, and paths.

## Pull requests

- Keep the project compatible with Windows PowerShell 5.1 and AutoHotkey v2.
- Preserve transition-only behavior; watchdog checks must not reapply profiles.
- Do not add bundled third-party binaries.
- Keep display and audio identifiers configurable and machine-local.
- Update README instructions when behavior or setup changes.
- Run `powershell -NoProfile -File tests\Validate.ps1` before opening the PR.

Changes that affect display application should be tested in both directions and
with a simulated Steam crash. Changes that affect audio should test different
Console and Communications defaults as well as an unavailable saved endpoint.

