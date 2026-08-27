[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AutoHotkeyExe,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$taskName = 'Steam Big Picture Display Switch'
$watcherPath = Join-Path $PSScriptRoot 'SteamBigPictureDisplaySwitch.ahk'

if ($Remove) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        if ($PSCmdlet.ShouldProcess($taskName, 'Remove scheduled task')) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "Removed scheduled task: $taskName"
        }
    }
    else {
        Write-Host "Scheduled task does not exist: $taskName"
    }
    return
}

if (-not (Test-Path -LiteralPath $watcherPath -PathType Leaf)) {
    throw "Watcher script was not found: $watcherPath"
}

if ([string]::IsNullOrWhiteSpace($AutoHotkeyExe)) {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\UX\AutoHotkeyUX.exe')
    )

    $AutoHotkeyExe = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($AutoHotkeyExe) -or
    -not (Test-Path -LiteralPath $AutoHotkeyExe -PathType Leaf)) {
    throw @'
AutoHotkey v2 was not found. Install it, or rerun with its full path:
  .\Install-LoginTask.ps1 -AutoHotkeyExe 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
'@
}

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$quotedWatcherPath = '"{0}"' -f $watcherPath

$action = New-ScheduledTaskAction `
    -Execute $AutoHotkeyExe `
    -Argument $quotedWatcherPath `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Switches display and playback-audio profiles when Steam enters or leaves Big Picture.'

if ($PSCmdlet.ShouldProcess($taskName, 'Install or update scheduled task')) {
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
    Write-Host "Installed scheduled task: $taskName"
    Write-Host "The watcher will start at the next login. To test now, double-click the .ahk file."
}
