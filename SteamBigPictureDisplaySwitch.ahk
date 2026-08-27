#Requires AutoHotkey v2.0+
#SingleInstance Force

; Steam Big Picture display and playback-audio watcher.
; Edit only the settings in this first section if your paths or Steam's window
; identity ever change.

MULTI_MONITOR_TOOL := A_ScriptDir "\Tools\MultiMonitorTool.exe"
SOUND_VOLUME_VIEW  := A_ScriptDir "\Tools\SoundVolumeView.exe"
DESKTOP_PROFILE    := A_ScriptDir "\Profiles\Desktop.cfg"
TV_PROFILE         := A_ScriptDir "\Profiles\TV.cfg"
CONFIG_FILE        := A_ScriptDir "\Config.ini"
LOG_FILE           := A_ScriptDir "\Logs\SteamDisplaySwitch.log"
AUDIO_STATE_FILE   := A_ScriptDir "\State\DesktopAudio.ini"

AUDIO_ENABLED      := IniRead(CONFIG_FILE, "Audio", "Enabled", "0") = "1"
TV_AUDIO_DEVICE_ID := IniRead(CONFIG_FILE, "Audio", "TvDeviceId", "")
TV_AUDIO_LABEL     := IniRead(CONFIG_FILE, "Audio", "TvDeviceLabel", "TV audio")

BIG_PICTURE_EXE    := "steamwebhelper.exe"
BIG_PICTURE_CLASS  := "SDL_app"
BIG_PICTURE_TITLE  := "Steam Big Picture Mode"

STARTUP_DELAY_MS   := 4000
WATCHDOG_MS        := 2000
SHELL_SETTLE_MS    := 300
ENTER_DEBOUNCE_MS  := 750
EXIT_DEBOUNCE_MS   := 2500
RETRY_DELAY_MS     := 5000
MAX_RETRIES        := 2
AUDIO_DEVICE_WAIT_MS := 10000

; Runtime state. -1 means that the initial state has not been established yet.
StableBigPicture := -1
CandidateState := -1
CandidateSince := 0
AppliedProfile := ""
SwitchInProgress := false
RetryCount := 0
AudioRetryCount := 0
ShellHookRegistered := false
ShellMessageNumber := 0

Persistent
DetectHiddenWindows True
SetWorkingDir A_ScriptDir

DirCreate A_ScriptDir "\Logs"
DirCreate A_ScriptDir "\Profiles"
DirCreate A_ScriptDir "\Tools"
DirCreate A_ScriptDir "\State"

ConfigureTrayMenu()
Log("Watcher starting. Waiting for Steam's initial state.")
if (AUDIO_ENABLED)
    Log(Format("TV audio switching enabled for: {1}.", TV_AUDIO_LABEL))
else
    Log("TV audio switching is disabled in Config.ini.")

; Shell events give fast transition detection. The watchdog below catches any
; event missed while Windows, Steam, or this script was temporarily busy.
ShellMessageNumber := DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt")
if (ShellMessageNumber != 0
    && DllCall("RegisterShellHookWindow", "Ptr", A_ScriptHwnd, "Int")) {
    ShellHookRegistered := true
    OnMessage ShellMessageNumber, ShellMessage, 1
    Log("Windows shell hook registered.")
} else {
    Log("Could not register the Windows shell hook; watchdog detection remains active.", "WARN")
}

OnExit Cleanup
SetTimer InitializeWatcher, -STARTUP_DELAY_MS

InitializeWatcher(*) {
    global StableBigPicture, CandidateState, CandidateSince, RetryCount
    global WATCHDOG_MS

    StableBigPicture := IsBigPictureOpen() ? 1 : 0
    CandidateState := -1
    CandidateSince := 0
    RetryCount := 0

    stateName := StableBigPicture ? "Big Picture" : "desktop"
    Log(Format("Initial Steam state: {1}.", stateName))
    ApplyProfileForCurrentState("startup")
    SetTimer WatchdogCheck, WATCHDOG_MS
}

ShellMessage(wParam, lParam, msg, hwnd) {
    global StableBigPicture, SHELL_SETTLE_MS

    ; HSHELL_WINDOWCREATED = 1, HSHELL_WINDOWDESTROYED = 2.
    ; Delay briefly because Steam may still be assigning title/class metadata.
    if (StableBigPicture != -1 && (wParam = 1 || wParam = 2))
        SetTimer ShellCheck, -SHELL_SETTLE_MS
}

ShellCheck(*) {
    EvaluateState("shell event")
}

WatchdogCheck(*) {
    EvaluateState("watchdog")
}

ConfirmCandidate(*) {
    EvaluateState("debounce confirmation")
}

EvaluateState(trigger) {
    global StableBigPicture, CandidateState, CandidateSince
    global ENTER_DEBOUNCE_MS, EXIT_DEBOUNCE_MS, SwitchInProgress, RetryCount

    if (StableBigPicture = -1 || SwitchInProgress)
        return

    observed := IsBigPictureOpen() ? 1 : 0

    if (observed = StableBigPicture) {
        if (CandidateState != -1) {
            Log(Format("Unconfirmed {1} transition cleared.",
                CandidateState ? "Big Picture entry" : "Big Picture exit"))
        }
        CandidateState := -1
        CandidateSince := 0
        SetTimer ConfirmCandidate, 0
        return
    }

    if (CandidateState != observed) {
        CandidateState := observed
        CandidateSince := A_TickCount
        debounceMs := observed ? ENTER_DEBOUNCE_MS : EXIT_DEBOUNCE_MS
        transitionName := observed ? "Big Picture entry" : "Big Picture exit"
        Log(Format("Candidate {1} detected by {2}; confirming for {3} ms.",
            transitionName, trigger, debounceMs))
        SetTimer ConfirmCandidate, -debounceMs
        return
    }

    debounceMs := observed ? ENTER_DEBOUNCE_MS : EXIT_DEBOUNCE_MS
    if (ElapsedMilliseconds(CandidateSince) < debounceMs)
        return

    oldState := StableBigPicture
    StableBigPicture := observed
    CandidateState := -1
    CandidateSince := 0
    RetryCount := 0

    transitionName := observed ? "entered Big Picture" : "left Big Picture"
    Log(Format("Confirmed transition: Steam {1}.", transitionName))
    ApplyProfileForCurrentState(Format("transition {1}->{2}", oldState, observed))
}

IsBigPictureOpen() {
    global BIG_PICTURE_EXE, BIG_PICTURE_CLASS, BIG_PICTURE_TITLE

    ; DetectHiddenWindows is intentionally on: the Big Picture window can be
    ; hidden/minimized while a game is running and that is not an exit.
    for windowHandle in WinGetList() {
        windowSelector := "ahk_id " windowHandle
        try {
            if (StrLower(WinGetProcessName(windowSelector)) != StrLower(BIG_PICTURE_EXE))
                continue
            if (WinGetClass(windowSelector) != BIG_PICTURE_CLASS)
                continue
            if (WinGetTitle(windowSelector) != BIG_PICTURE_TITLE)
                continue
            return true
        } catch {
            ; A window may disappear between enumeration and inspection.
            continue
        }
    }
    return false
}

ApplyProfileForCurrentState(reason, force := false) {
    global StableBigPicture, AudioRetryCount

    if (StableBigPicture) {
        ; Snapshot before the display switch can make Windows automatically pick
        ; the HDMI endpoint. An existing snapshot is never overwritten.
        audioSnapshotReady := CaptureDesktopAudioDefaults()
        displayApplied := ApplyProfile("TV", reason, force)
        if (displayApplied && audioSnapshotReady && !SwitchAudioToTV())
            ScheduleTvAudioRetry()
        else if (displayApplied && !audioSnapshotReady)
            Log("TV audio was not changed because the previous desktop defaults could not be saved.",
                "WARN")
        return displayApplied
    }

    SetTimer RetryTvAudio, 0
    AudioRetryCount := 0
    ; Restore while the TV endpoint still exists, then disable the TV display.
    RestoreDesktopAudioDefaults()
    return ApplyProfile("Desktop", reason, force)
}

ApplyProfile(profileKey, reason, force := false) {
    global MULTI_MONITOR_TOOL, DESKTOP_PROFILE, TV_PROFILE, LOG_FILE
    global AppliedProfile, SwitchInProgress, RetryCount
    global MAX_RETRIES, RETRY_DELAY_MS

    if (!force && profileKey = AppliedProfile) {
        Log(Format("Skipped {1} profile; it is already the last successfully applied profile.",
            profileKey))
        return true
    }

    if (SwitchInProgress) {
        Log(Format("Skipped overlapping request for {1} profile.", profileKey), "WARN")
        return false
    }

    profilePath := profileKey = "TV" ? TV_PROFILE : DESKTOP_PROFILE

    if (!FileExist(MULTI_MONITOR_TOOL)) {
        HandleApplyFailure(profileKey,
            Format("MultiMonitorTool was not found at: {1}", MULTI_MONITOR_TOOL))
        return false
    }
    if (!FileExist(profilePath)) {
        HandleApplyFailure(profileKey,
            Format("The {1} profile was not found at: {2}", profileKey, profilePath))
        return false
    }

    SwitchInProgress := true
    try {
        Log(Format("Applying {1} profile ({2}).", profileKey, reason))
        commandLine := Format('"{1}" /LoadConfig "{2}"', MULTI_MONITOR_TOOL, profilePath)
        exitCode := RunWait(commandLine, A_ScriptDir, "Hide")
        if (exitCode != 0)
            throw Error(Format("MultiMonitorTool exited with code {1}.", exitCode))

        AppliedProfile := profileKey
        RetryCount := 0
        SetTimer RetryCurrentProfile, 0
        Log(Format("{1} profile applied successfully.", profileKey))
        return true
    } catch as errorObject {
        HandleApplyFailure(profileKey, errorObject.Message)
        return false
    } finally {
        SwitchInProgress := false
    }
}

HandleApplyFailure(profileKey, detail) {
    global RetryCount, MAX_RETRIES, RETRY_DELAY_MS, LOG_FILE

    RetryCount += 1
    Log(Format("Failed to apply {1} profile: {2}", profileKey, detail), "ERROR")

    if (RetryCount <= MAX_RETRIES) {
        Log(Format("A retry will run in {1} ms (attempt {2} of {3}).",
            RETRY_DELAY_MS, RetryCount, MAX_RETRIES))
        SetTimer RetryCurrentProfile, -RETRY_DELAY_MS
    } else {
        Log("Retry limit reached; use the tray menu after fixing the problem.", "ERROR")
        TrayTip "Display switch failed. See the log and use the tray menu to retry.",
            "Steam Display Switch", "Iconx"
    }
}

RetryCurrentProfile(*) {
    ApplyProfileForCurrentState("automatic retry")
}

ScheduleTvAudioRetry() {
    global AudioRetryCount, MAX_RETRIES, RETRY_DELAY_MS

    AudioRetryCount += 1
    if (AudioRetryCount <= MAX_RETRIES) {
        Log(Format("TV audio retry scheduled in {1} ms (attempt {2} of {3}).",
            RETRY_DELAY_MS, AudioRetryCount, MAX_RETRIES))
        SetTimer RetryTvAudio, -RETRY_DELAY_MS
    } else {
        Log("TV audio retry limit reached; use Reapply current profile from the tray menu.",
            "ERROR")
    }
}

RetryTvAudio(*) {
    global StableBigPicture, AudioRetryCount

    if (StableBigPicture = 1) {
        if (SwitchAudioToTV())
            AudioRetryCount := 0
        else
            ScheduleTvAudioRetry()
    }
}

CaptureDesktopAudioDefaults() {
    global AUDIO_ENABLED, SOUND_VOLUME_VIEW, AUDIO_STATE_FILE

    if (!AUDIO_ENABLED)
        return true

    if (FileExist(AUDIO_STATE_FILE)) {
        Log("Preserving the existing desktop-audio snapshot (likely crash recovery).")
        return true
    }

    if (!FileExist(SOUND_VOLUME_VIEW)) {
        Log(Format("Cannot snapshot desktop audio; SoundVolumeView was not found at: {1}",
            SOUND_VOLUME_VIEW), "ERROR")
        return false
    }

    consoleId := QueryDefaultAudioId("DefaultRenderDevice")
    multimediaId := QueryDefaultAudioId("DefaultRenderDeviceMulti")
    communicationsId := QueryDefaultAudioId("DefaultRenderDeviceComm")

    if (consoleId = "") {
        Log("Cannot snapshot desktop audio; the default Console render endpoint was empty.",
            "ERROR")
        return false
    }
    if (multimediaId = "")
        multimediaId := consoleId
    if (communicationsId = "")
        communicationsId := consoleId

    temporaryState := AUDIO_STATE_FILE ".tmp"
    try {
        if (FileExist(temporaryState))
            FileDelete temporaryState
        IniWrite consoleId, temporaryState, "DesktopDefaults", "Console"
        IniWrite multimediaId, temporaryState, "DesktopDefaults", "Multimedia"
        IniWrite communicationsId, temporaryState, "DesktopDefaults", "Communications"
        IniWrite FormatTime(, "yyyy-MM-dd HH:mm:ss"), temporaryState,
            "DesktopDefaults", "CapturedAt"
        FileMove temporaryState, AUDIO_STATE_FILE, 1
        Log("Saved the current desktop playback defaults for later restoration.")
        return true
    } catch as errorObject {
        Log(Format("Could not save the desktop-audio snapshot: {1}", errorObject.Message),
            "ERROR")
        return false
    }
}

SwitchAudioToTV() {
    global AUDIO_ENABLED, SOUND_VOLUME_VIEW, TV_AUDIO_DEVICE_ID, TV_AUDIO_LABEL
    global AUDIO_DEVICE_WAIT_MS, AudioRetryCount

    if (!AUDIO_ENABLED)
        return true
    if (!FileExist(SOUND_VOLUME_VIEW)) {
        Log(Format("Cannot switch TV audio; SoundVolumeView was not found at: {1}",
            SOUND_VOLUME_VIEW), "ERROR")
        return false
    }
    if (TV_AUDIO_DEVICE_ID = "") {
        Log("Cannot switch TV audio; Config.ini has no TvDeviceId. Rerun Setup.ps1 -Mode Audio.",
            "ERROR")
        return false
    }

    if (!WaitForAudioDevice(TV_AUDIO_DEVICE_ID, AUDIO_DEVICE_WAIT_MS)) {
        Log(Format("TV audio endpoint did not become active within {1} ms: {2}",
            AUDIO_DEVICE_WAIT_MS, TV_AUDIO_LABEL), "ERROR")
        return false
    }

    commandLine := Format('"{1}" /SetDefault "{2}" all',
        SOUND_VOLUME_VIEW, TV_AUDIO_DEVICE_ID)
    try RunWait commandLine, A_ScriptDir, "Hide"
    catch as errorObject {
        Log(Format("SoundVolumeView could not set TV audio: {1}", errorObject.Message),
            "ERROR")
        return false
    }

    Sleep 250
    if (!AudioRolesMatch(TV_AUDIO_DEVICE_ID)) {
        Log(Format("Windows did not accept {1} as every default playback role.",
            TV_AUDIO_LABEL), "ERROR")
        return false
    }

    AudioRetryCount := 0
    Log(Format("TV audio is now the default for Console, Multimedia, and Communications: {1}.",
        TV_AUDIO_LABEL))
    return true
}

RestoreDesktopAudioDefaults(*) {
    global SOUND_VOLUME_VIEW, AUDIO_STATE_FILE

    if (!FileExist(AUDIO_STATE_FILE))
        return true
    if (!FileExist(SOUND_VOLUME_VIEW)) {
        Log(Format("Cannot restore desktop audio; SoundVolumeView was not found at: {1}",
            SOUND_VOLUME_VIEW), "ERROR")
        return false
    }

    roles := [
        ["Console", "0", "DefaultRenderDevice"],
        ["Multimedia", "1", "DefaultRenderDeviceMulti"],
        ["Communications", "2", "DefaultRenderDeviceComm"]
    ]
    restoredAll := true

    for role in roles {
        savedId := IniRead(AUDIO_STATE_FILE, "DesktopDefaults", role[1], "")
        if (savedId = "") {
            restoredAll := false
            Log(Format("Desktop-audio snapshot has no {1} endpoint.", role[1]), "WARN")
            continue
        }

        commandLine := Format('"{1}" /SetDefault "{2}" {3}',
            SOUND_VOLUME_VIEW, savedId, role[2])
        try RunWait commandLine, A_ScriptDir, "Hide"
        catch as errorObject {
            restoredAll := false
            Log(Format("Could not restore the {1} audio role: {2}",
                role[1], errorObject.Message), "WARN")
            continue
        }

        Sleep 150
        if (QueryDefaultAudioId(role[3]) != savedId) {
            restoredAll := false
            Log(Format("The saved {1} audio endpoint is currently unavailable.", role[1]),
                "WARN")
        }
    }

    ; Do not keep a stale snapshot that could unexpectedly override a deliberate
    ; desktop audio choice days later if disconnected headphones reconnect.
    try FileDelete AUDIO_STATE_FILE

    if (restoredAll)
        Log("Restored the desktop playback defaults captured before Big Picture.")
    else
        Log("Desktop audio was only partially restorable; Windows will use its available fallback endpoint.",
            "WARN")
    return restoredAll
}

WaitForAudioDevice(deviceId, timeoutMs) {
    startTick := A_TickCount
    loop {
        if (StrLower(QueryAudioDeviceState(deviceId)) = "active")
            return true
        if (ElapsedMilliseconds(startTick) >= timeoutMs)
            return false
        Sleep 500
    }
}

AudioRolesMatch(deviceId) {
    return QueryDefaultAudioId("DefaultRenderDevice") = deviceId
        && QueryDefaultAudioId("DefaultRenderDeviceMulti") = deviceId
        && QueryDefaultAudioId("DefaultRenderDeviceComm") = deviceId
}

QueryDefaultAudioId(defaultSelector) {
    defaultColumn := ""
    switch defaultSelector {
        case "DefaultRenderDevice":
            defaultColumn := "Default"
        case "DefaultRenderDeviceMulti":
            defaultColumn := "Default Multimedia"
        case "DefaultRenderDeviceComm":
            defaultColumn := "Default Communications"
        default:
            return ""
    }

    for device in ReadAudioDeviceRows() {
        if (device[defaultColumn] = "Render")
            return device["Item ID"]
    }
    return ""
}

QueryAudioDeviceState(deviceId) {
    for device in ReadAudioDeviceRows() {
        if (device["Item ID"] = deviceId)
            return device["Device State"]
    }
    return ""
}

ReadAudioDeviceRows() {
    global SOUND_VOLUME_VIEW

    devices := []
    if (!FileExist(SOUND_VOLUME_VIEW))
        return devices

    processId := DllCall("GetCurrentProcessId", "UInt")
    exportPath := Format("{1}\SteamBPM-Audio-{2}-{3}.tsv", A_Temp, processId, A_TickCount)
    columns := "Type,Direction,Device State,Default,Default Multimedia,Default Communications,Item ID"
    commandLine := Format('"{1}" /SaveFileEncoding 2 /ShowUnpluggedDevices 1 /ShowDisabledDevices 1 /stab "{2}" /Columns "{3}"',
        SOUND_VOLUME_VIEW, exportPath, columns)

    try {
        exitCode := RunWait(commandLine, A_ScriptDir, "Hide")
        if (exitCode != 0 || !FileExist(exportPath))
            return devices

        lines := StrSplit(FileRead(exportPath), "`n", "`r")
        if (lines.Length < 2)
            return devices
        headers := StrSplit(lines[1], "`t")

        loop lines.Length - 1 {
            line := lines[A_Index + 1]
            if (line = "")
                continue
            values := StrSplit(line, "`t")
            row := Map()
            for index, header in headers
                row[header] := index <= values.Length ? values[index] : ""
            if (row["Type"] = "Device" && row["Direction"] = "Render")
                devices.Push(row)
        }
        return devices
    } catch as errorObject {
        Log(Format("Could not query Windows audio endpoints: {1}", errorObject.Message),
            "WARN")
        return devices
    } finally {
        if (FileExist(exportPath))
            try FileDelete exportPath
    }
}

ForceCurrentProfile(*) {
    global AppliedProfile, RetryCount, AudioRetryCount
    AppliedProfile := ""
    RetryCount := 0
    AudioRetryCount := 0
    SetTimer RetryCurrentProfile, 0
    SetTimer RetryTvAudio, 0
    ApplyProfileForCurrentState("manual tray command", true)
}

LogSteamWindows(*) {
    global BIG_PICTURE_EXE

    count := 0
    for windowHandle in WinGetList() {
        windowSelector := "ahk_id " windowHandle
        try {
            processName := WinGetProcessName(windowSelector)
            if (StrLower(processName) != "steam.exe"
                && StrLower(processName) != StrLower(BIG_PICTURE_EXE))
                continue

            count += 1
            Log(Format("Steam window HWND=0x{1:X}, EXE={2}, Class={3}, Title={4}",
                windowHandle, processName, WinGetClass(windowSelector),
                WinGetTitle(windowSelector)))
        } catch {
            continue
        }
    }
    Log(Format("Steam window diagnostic completed; {1} top-level window(s) logged.", count))
    TrayTip Format("Logged {1} Steam window(s).", count), "Steam Display Switch"
}

OpenLog(*) {
    global LOG_FILE
    if (!FileExist(LOG_FILE))
        Log("Log file created.")
    Run Format('notepad.exe "{1}"', LOG_FILE)
}

ConfigureTrayMenu() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Reapply current profile", ForceCurrentProfile)
    A_TrayMenu.Add("Restore saved desktop audio", RestoreDesktopAudioDefaults)
    A_TrayMenu.Add("Log Steam windows", LogSteamWindows)
    A_TrayMenu.Add("Open log", OpenLog)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Open log"
    A_IconTip := "Steam Big Picture Display Switch"
}

ElapsedMilliseconds(startTick) {
    elapsed := A_TickCount - startTick
    return elapsed >= 0 ? elapsed : elapsed + 0x100000000
}

Log(message, level := "INFO") {
    global LOG_FILE

    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := Format("[{1}] [{2}] {3}`r`n", timestamp, level, message)
    try FileAppend line, LOG_FILE, "UTF-8"
    OutputDebug RTrim(line, "`r`n")
}

Cleanup(*) {
    global ShellHookRegistered

    if (ShellHookRegistered)
        DllCall("DeregisterShellHookWindow", "Ptr", A_ScriptHwnd)
    Log("Watcher stopped.")
}
