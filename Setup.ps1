[CmdletBinding()]
param(
    [ValidateSet('Full', 'Dependencies', 'Profiles', 'Audio', 'LoginTask')]
    [string]$Mode = 'Full',

    [switch]$ForceDownload,
    [switch]$NoLoginTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$toolsDirectory = Join-Path $root 'Tools'
$profilesDirectory = Join-Path $root 'Profiles'
$stateDirectory = Join-Path $root 'State'
$multiMonitorTool = Join-Path $toolsDirectory 'MultiMonitorTool.exe'
$soundVolumeView = Join-Path $toolsDirectory 'SoundVolumeView.exe'
$desktopProfile = Join-Path $profilesDirectory 'Desktop.cfg'
$tvProfile = Join-Path $profilesDirectory 'TV.cfg'
$configFile = Join-Path $root 'Config.ini'
$watcher = Join-Path $root 'SteamBigPictureDisplaySwitch.ahk'

$multiMonitorToolUrl = 'https://www.nirsoft.net/utils/multimonitortool-x64.zip'
$soundVolumeViewUrl = 'https://www.nirsoft.net/utils/soundvolumeview-x64.zip'

function Write-Section {
    param([string]$Title)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        if ($answer -match '^(y|yes)$') {
            return $true
        }
        if ($answer -match '^(n|no)$') {
            return $false
        }
    }
}

function Get-IniValue {
    param(
        [string]$Section,
        [string]$Key,
        [string]$Default = ''
    )

    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        return $Default
    }

    $inRequestedSection = $false
    $sectionPattern = '^\s*\[{0}\]\s*$' -f [regex]::Escape($Section)
    $keyPattern = '^\s*{0}\s*=\s*(.*)$' -f [regex]::Escape($Key)
    foreach ($line in Get-Content -LiteralPath $configFile) {
        if ($line -match '^\s*\[.*\]\s*$') {
            $inRequestedSection = $line -match $sectionPattern
            continue
        }
        if ($inRequestedSection -and $line -match $keyPattern) {
            return $Matches[1]
        }
    }
    return $Default
}

function Write-Configuration {
    param(
        [ValidateSet('External', 'Extend', 'None')]
        [string]$WakeMode,
        [ValidateSet(0, 1)]
        [int]$AudioEnabled,
        [string]$TvDeviceId,
        [string]$TvDeviceLabel
    )

    $contents = @(
        '[Display]',
        ('WakeMode={0}' -f $WakeMode),
        '',
        '[Audio]',
        ('Enabled={0}' -f $AudioEnabled),
        ('TvDeviceId={0}' -f $TvDeviceId),
        ('TvDeviceLabel={0}' -f $TvDeviceLabel)
    )
    Set-Content -LiteralPath $configFile -Value $contents -Encoding UTF8
    Write-Host "Configuration saved: $configFile" -ForegroundColor Green
}

function Get-AutoHotkeyPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\UX\AutoHotkeyUX.exe')
    )

    $command = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $candidates += $command.Source
    }

    return $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

function Install-AutoHotkeyIfRequested {
    $existing = Get-AutoHotkeyPath
    if ($null -ne $existing) {
        Write-Host "AutoHotkey v2 found: $existing" -ForegroundColor Green
        return $existing
    }

    Write-Warning 'AutoHotkey v2 is not installed.'
    if (-not (Read-YesNo 'Install AutoHotkey v2 with winget now?')) {
        return $null
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        Write-Warning 'winget is unavailable. Install AutoHotkey v2 manually from https://www.autohotkey.com/'
        return $null
    }

    & $winget.Source install `
        --id AutoHotkey.AutoHotkey `
        --exact `
        --source winget `
        --accept-package-agreements `
        --accept-source-agreements | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget returned exit code $LASTEXITCODE. Install AutoHotkey manually and rerun Setup.ps1 -Mode LoginTask."
        return $null
    }

    $installed = Get-AutoHotkeyPath
    if ($null -eq $installed) {
        Write-Warning 'AutoHotkey installed, but its executable was not found yet. Sign out/in or rerun setup.'
    }
    return $installed
}

function Install-NirSoftTool {
    param(
        [string]$Name,
        [string]$Url,
        [string]$ExecutableName
    )

    $destination = Join-Path $toolsDirectory $ExecutableName
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not $ForceDownload) {
        Write-Host "$Name already present: $destination" -ForegroundColor Green
        return
    }

    Write-Host "Downloading $Name from its official NirSoft URL..."
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("SteamBPMDisplaySwitch-{0}" -f [guid]::NewGuid().ToString('N'))
    $archive = Join-Path $temporaryRoot "$Name.zip"
    $expanded = Join-Path $temporaryRoot 'expanded'

    try {
        New-Item -ItemType Directory -Path $expanded -Force | Out-Null
        Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force

        $downloadedExecutable = Get-ChildItem -LiteralPath $expanded -Recurse -Filter $ExecutableName |
            Select-Object -First 1
        if ($null -eq $downloadedExecutable) {
            throw "$ExecutableName was not present in the archive downloaded from $Url"
        }

        Copy-Item -LiteralPath $downloadedExecutable.FullName -Destination $destination -Force
        $sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        Write-Host "$Name installed. SHA-256: $sha256" -ForegroundColor Green
    }
    finally {
        $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedTemp)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}

function Install-Dependencies {
    Write-Section 'Install dependencies'
    New-Item -ItemType Directory -Path $toolsDirectory, $profilesDirectory, $stateDirectory -Force | Out-Null

    Install-NirSoftTool `
        -Name 'MultiMonitorTool' `
        -Url $multiMonitorToolUrl `
        -ExecutableName 'MultiMonitorTool.exe'
    Install-NirSoftTool `
        -Name 'SoundVolumeView' `
        -Url $soundVolumeViewUrl `
        -ExecutableName 'SoundVolumeView.exe'

    return Install-AutoHotkeyIfRequested
}

function Save-CurrentDisplayProfile {
    param(
        [string]$Name,
        [string]$Path,
        [string[]]$Instructions
    )

    Write-Section "Configure the $Name display profile"
    $Instructions | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
    Write-Host 'Windows Display Settings and MultiMonitorTool will now open.'
    Write-Host 'Make the requested changes, verify them in both windows, then return here.'

    Start-Process 'ms-settings:display'
    Start-Process -FilePath $multiMonitorTool
    [void](Read-Host "Press Enter only when the $Name layout is correct")

    $arguments = '/SaveConfig "{0}"' -f $Path
    $process = Start-Process -FilePath $multiMonitorTool -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "MultiMonitorTool did not save the $Name profile to: $Path"
    }
    Write-Host "$Name profile saved: $Path" -ForegroundColor Green
}

function Capture-DisplayProfiles {
    if (-not (Test-Path -LiteralPath $multiMonitorTool -PathType Leaf)) {
        throw 'MultiMonitorTool is missing. Run Setup.ps1 -Mode Dependencies first.'
    }

    Write-Section 'Before profile capture'
    Write-Host 'Connect and power on every display, including the TV.'
    Write-Host 'In MultiMonitorTool Options, keep "Use Monitor ID In Load Config" enabled.'
    Write-Host 'Enable serial-number matching only when every display reports a unique, nonblank serial.'
    [void](Read-Host 'Press Enter to continue')

    Save-CurrentDisplayProfile `
        -Name 'Desktop' `
        -Path $desktopProfile `
        -Instructions @(
            'Enable only the normal desktop monitor.',
            'Disable the TV and laptop/internal panel.',
            'Make the desktop monitor primary.',
            'Set its native resolution and intended high refresh rate.'
        )

    Save-CurrentDisplayProfile `
        -Name 'TV' `
        -Path $tvProfile `
        -Instructions @(
            'Enable only the TV.',
            'Disable the desktop monitor and laptop/internal panel.',
            'Make the TV primary.',
            'Set the TV native resolution and intended refresh rate.'
        )
}

function Configure-DisplayRecovery {
    Write-Section 'Choose the display recovery topology'
    Write-Host 'This is used only if Windows ignores a MultiMonitorTool profile load.'
    Write-Host '  [1] External - briefly enable external displays only; keeps the laptop panel off.'
    Write-Host '  [2] Extend   - briefly enable every connected display, including an internal panel.'
    Write-Host '  [3] None     - disable the native Windows recovery fallback.'

    while ($true) {
        $selection = (Read-Host 'Choose 1, 2, or 3 [1]').Trim()
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = '1'
        }
        if ($selection -in @('1', '2', '3')) {
            break
        }
    }

    $wakeMode = switch ($selection) {
        '1' { 'External' }
        '2' { 'Extend' }
        '3' { 'None' }
    }
    $audioEnabled = if ((Get-IniValue -Section 'Audio' -Key 'Enabled' -Default '0') -eq '1') { 1 } else { 0 }
    $tvDeviceId = Get-IniValue -Section 'Audio' -Key 'TvDeviceId'
    $tvDeviceLabel = Get-IniValue -Section 'Audio' -Key 'TvDeviceLabel' -Default 'TV audio'
    Write-Configuration `
        -WakeMode $wakeMode `
        -AudioEnabled $audioEnabled `
        -TvDeviceId $tvDeviceId `
        -TvDeviceLabel $tvDeviceLabel
}

function Get-RenderAudioDevices {
    if (-not (Test-Path -LiteralPath $soundVolumeView -PathType Leaf)) {
        throw 'SoundVolumeView is missing. Run Setup.ps1 -Mode Dependencies first.'
    }

    $jsonPath = Join-Path ([IO.Path]::GetTempPath()) `
        ("SteamBPM-AudioDevices-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $columns = 'Name,Type,Direction,Device State,Default,Default Multimedia,Default Communications,Item ID,Command-Line Friendly ID,Device Name'
    $arguments = '/SaveFileEncoding 3 /ShowUnpluggedDevices 1 /ShowDisabledDevices 1 /sjson "{0}" /Columns "{1}"' -f $jsonPath, $columns

    try {
        $process = Start-Process -FilePath $soundVolumeView -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $jsonPath)) {
            throw 'SoundVolumeView could not export the audio endpoint list.'
        }

        $allItems = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        return @($allItems |
            Where-Object { $_.Type -eq 'Device' -and $_.Direction -eq 'Render' } |
            Sort-Object @{ Expression = { if ($_.'Device State' -eq 'Active') { 0 } else { 1 } } }, Name, 'Device Name')
    }
    finally {
        if (Test-Path -LiteralPath $jsonPath) {
            Remove-Item -LiteralPath $jsonPath -Force
        }
    }
}

function Write-AudioConfiguration {
    param([AllowNull()]$Device)

    $wakeMode = Get-IniValue -Section 'Display' -Key 'WakeMode' -Default 'External'
    if ($wakeMode -notin @('External', 'Extend', 'None')) {
        $wakeMode = 'External'
    }
    if ($null -eq $Device) {
        Write-Configuration `
            -WakeMode $wakeMode `
            -AudioEnabled 0 `
            -TvDeviceId '' `
            -TvDeviceLabel 'TV audio'
    }
    else {
        $label = ('{0} ({1})' -f $Device.Name, $Device.'Device Name').Replace("`r", ' ').Replace("`n", ' ')
        Write-Configuration `
            -WakeMode $wakeMode `
            -AudioEnabled 1 `
            -TvDeviceId $Device.'Item ID' `
            -TvDeviceLabel $label
    }
}

function Configure-TVAudio {
    Write-Section 'Choose the TV playback endpoint'
    Write-Host 'The TV display should be the only active display during this step.'
    Write-Host 'That allows its HDMI/DisplayPort audio endpoint to become active.'

    $devices = Get-RenderAudioDevices
    if ($devices.Count -eq 0) {
        throw 'No Windows render audio endpoints were found.'
    }

    Write-Host ''
    Write-Host '  [0] Disable automatic audio switching'
    for ($index = 0; $index -lt $devices.Count; $index++) {
        $device = $devices[$index]
        $stateColor = if ($device.'Device State' -eq 'Active') { 'Green' } else { 'DarkGray' }
        Write-Host ('  [{0}] {1} - {2} [{3}]' -f `
            ($index + 1), $device.Name, $device.'Device Name', $device.'Device State') `
            -ForegroundColor $stateColor
    }

    while ($true) {
        $selectionText = Read-Host 'Enter the number for the TV audio endpoint'
        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and
            $selection -ge 0 -and $selection -le $devices.Count) {
            break
        }
    }

    if ($selection -eq 0) {
        Write-AudioConfiguration -Device $null
        return
    }

    $selected = $devices[$selection - 1]
    if ($selected.'Device State' -ne 'Active') {
        Write-Warning 'The selected endpoint is not currently Active. The watcher will wait and retry, but selecting the active TV endpoint is more reliable.'
        if (-not (Read-YesNo 'Keep this selection?' $false)) {
            Configure-TVAudio
            return
        }
    }

    Write-AudioConfiguration -Device $selected
    Write-Host ('Selected stable endpoint ID: {0}' -f $selected.'Item ID')
}

function Load-DisplayProfile {
    param(
        [string]$Name,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name profile is missing: $Path"
    }
    $arguments = '/LoadConfig "{0}"' -f $Path
    $process = Start-Process -FilePath $multiMonitorTool -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "MultiMonitorTool failed to load the $Name profile (exit code $($process.ExitCode))."
    }
}

function Install-LoginTask {
    param([AllowNull()][string]$AutoHotkeyPath)

    if ($NoLoginTask) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($AutoHotkeyPath)) {
        $AutoHotkeyPath = Get-AutoHotkeyPath
    }
    if ([string]::IsNullOrWhiteSpace($AutoHotkeyPath)) {
        Write-Warning 'Skipping the login task because AutoHotkey v2 was not found.'
        return
    }

    & (Join-Path $root 'Install-LoginTask.ps1') -AutoHotkeyExe $AutoHotkeyPath
}

Write-Host 'Steam Big Picture Display & Audio Switch setup' -ForegroundColor Cyan
Write-Host "Mode: $Mode"

$autoHotkeyPath = Get-AutoHotkeyPath
$tvProfileIsActive = $false

if ($Mode -in @('Full', 'Dependencies')) {
    $autoHotkeyPath = Install-Dependencies
}

try {
    if ($Mode -in @('Full', 'Profiles')) {
        Capture-DisplayProfiles
        Configure-DisplayRecovery
        $tvProfileIsActive = $true
    }

    if ($Mode -in @('Full', 'Audio')) {
        if (-not $tvProfileIsActive) {
            if ((Test-Path -LiteralPath $tvProfile) -and (Test-Path -LiteralPath $multiMonitorTool)) {
                if (Read-YesNo 'Temporarily load the saved TV profile so its audio endpoint is available?') {
                    Load-DisplayProfile -Name 'TV' -Path $tvProfile
                    $tvProfileIsActive = $true
                }
            }
            if (-not $tvProfileIsActive) {
                Write-Host 'Manually enable the TV display before selecting its audio endpoint.'
                [void](Read-Host 'Press Enter when the TV display and its audio endpoint are active')
                $tvProfileIsActive = $true
            }
        }

        Configure-TVAudio
    }
}
finally {
    if ($tvProfileIsActive -and (Test-Path -LiteralPath $desktopProfile)) {
        Write-Section 'Restore the desktop profile'
        try {
            Load-DisplayProfile -Name 'Desktop' -Path $desktopProfile
            Write-Host 'Desktop display profile restored.' -ForegroundColor Green
        }
        catch {
            Write-Warning "Automatic desktop-profile restoration failed: $($_.Exception.Message)"
        }
    }
}

if ($Mode -eq 'Full') {
    Write-Section 'Steam setting'
    Write-Host 'Open Big Picture > Settings > Display and set Preferred Display to None.'
    Write-Host 'This prevents Steam and this watcher from racing to change the primary display.'
    [void](Read-Host 'Press Enter after checking that setting')

    if (-not $NoLoginTask -and (Read-YesNo 'Install/update the watcher login task?')) {
        Install-LoginTask -AutoHotkeyPath $autoHotkeyPath
    }

    if ($null -ne $autoHotkeyPath -and (Read-YesNo 'Start the watcher now?')) {
        Start-Process -FilePath $autoHotkeyPath -ArgumentList ('"{0}"' -f $watcher)
        Write-Host 'Watcher started. Use its tray icon to inspect the log or reapply the current profile.' -ForegroundColor Green
    }
}
elseif ($Mode -eq 'LoginTask') {
    Install-LoginTask -AutoHotkeyPath $autoHotkeyPath
}

Write-Section 'Setup complete'
Write-Host 'Detailed testing and troubleshooting instructions are in README.md.'
Write-Host 'Machine-specific Config.ini and display profiles are intentionally excluded from Git.'
