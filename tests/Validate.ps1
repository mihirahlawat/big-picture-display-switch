[CmdletBinding()]
param(
    [string]$AutoHotkeyExe,
    [switch]$SkipAutoHotkey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)

    $failures.Add($Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
}

function Add-Success {
    param([string]$Message)

    Write-Host "PASS: $Message" -ForegroundColor Green
}

$requiredFiles = @(
    'SteamBigPictureDisplaySwitch.ahk',
    'Setup.ps1',
    'Start-Setup.cmd',
    'Install-LoginTask.ps1',
    'Config.example.ini',
    'README.md',
    'LICENSE',
    'THIRD_PARTY_NOTICES.md'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $root $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Add-Success "Required file exists: $relativePath"
    }
    else {
        Add-Failure "Required file is missing: $relativePath"
    }
}

$powershellFiles = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notmatch '[\\/]Tools[\\/]' }

foreach ($file in $powershellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -eq 0) {
        Add-Success "PowerShell syntax: $($file.FullName.Substring($root.Length + 1))"
    }
    else {
        foreach ($parseError in $parseErrors) {
            Add-Failure ("PowerShell syntax in {0} at line {1}: {2}" -f `
                $file.Name, $parseError.Extent.StartLineNumber, $parseError.Message)
        }
    }
}

$configExample = Join-Path $root 'Config.example.ini'
if (Test-Path -LiteralPath $configExample) {
    $configText = Get-Content -LiteralPath $configExample -Raw
    foreach ($requiredSetting in '[Audio]', 'Enabled=', 'TvDeviceId=', 'TvDeviceLabel=') {
        if ($configText.Contains($requiredSetting)) {
            Add-Success "Config example contains $requiredSetting"
        }
        else {
            Add-Failure "Config example is missing $requiredSetting"
        }
    }
}

if (-not $SkipAutoHotkey) {
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
        Add-Failure 'AutoHotkey v2 was not found. Pass -AutoHotkeyExe or use -SkipAutoHotkey.'
    }
    else {
        $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) `
            ("SteamBPM-Validation-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
        $stdoutPath = Join-Path $temporaryDirectory 'stdout.txt'
        $stderrPath = Join-Path $temporaryDirectory 'stderr.txt'
        $watcherPath = Join-Path $root 'SteamBigPictureDisplaySwitch.ahk'

        try {
            $arguments = @(
                '/ErrorStdOut=UTF-8',
                '/validate',
                ('"{0}"' -f $watcherPath)
            )
            $process = Start-Process `
                -FilePath $AutoHotkeyExe `
                -ArgumentList $arguments `
                -Wait `
                -PassThru `
                -NoNewWindow `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath

            if ($process.ExitCode -eq 0) {
                Add-Success 'AutoHotkey v2 syntax validation'
            }
            else {
                $details = if (Test-Path -LiteralPath $stderrPath) {
                    Get-Content -LiteralPath $stderrPath -Raw
                } else {
                    'No validator error text was produced.'
                }
                Add-Failure "AutoHotkey validation failed: $details"
            }
        }
        finally {
            $resolvedTemp = [IO.Path]::GetFullPath($temporaryDirectory)
            $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $resolvedTemp)) {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) validation failure(s)." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All validations passed.' -ForegroundColor Green

