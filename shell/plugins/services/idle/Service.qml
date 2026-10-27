import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "IdleModel.js" as IdleModel
import qs.Commons

Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stayAwakeStateDir: home + "/.local/state/omarchy/indicators"
  readonly property string stayAwakeStatePath: stayAwakeStateDir + "/stay-awake"
  readonly property int defaultScreensaverSeconds: 150
  readonly property int defaultLockSeconds: 300
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle
    ? shell.shellConfig.idle : (shell && shell.idleConfig ? shell.idleConfig : ({}))
  readonly property int screensaverTimeoutSeconds: secondsFromConfig(idleConfig.screensaver, defaultScreensaverSeconds)
  readonly property int lockTimeoutSeconds: secondsFromConfig(idleConfig.lock, defaultLockSeconds)
  readonly property bool screensaverEnabled: screensaverTimeoutSeconds > 0
  readonly property bool lockEnabled: lockTimeoutSeconds > 0
  readonly property bool idleTimersEnabled: screensaverEnabled || lockEnabled
  readonly property int firstIdleTimeoutSeconds: IdleModel.firstIdleTimeout(screensaverTimeoutSeconds, lockTimeoutSeconds)
  readonly property int screensaverDelaySeconds: IdleModel.delayAfterFirstIdle(screensaverTimeoutSeconds, firstIdleTimeoutSeconds)
  readonly property int lockDelaySeconds: IdleModel.delayAfterFirstIdle(lockTimeoutSeconds, firstIdleTimeoutSeconds)
  readonly property bool idleEnabled: stayAwakeStateLoaded && !stayAwake
  readonly property string screensaverClass: "org.omarchy.screensaver"

  property bool stayAwake: false
  property bool stayAwakeStateLoaded: false
  property bool hasPendingStayAwakePersist: false
  property bool pendingStayAwakePersist: false
  property bool idledThisCycle: false
  property bool screensaverStartedThisCycle: false
  property string lastEvent: "starting"
  property string lastEventAt: ""
  // Counted from the live toplevel list, so a missed event or a shell restart cannot leave it stale.
  readonly property int screensaverWindowCount: {
    var count = 0
    var toplevels = ToplevelManager.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      if (toplevels[i].appId === screensaverClass) count++
    }
    return count
  }
  property int previousScreensaverWindowCount: 0
  property bool screensaverLaunching: false
  property bool screensaverInputReady: false

  function secondsFromConfig(value, fallback) {
    return IdleModel.secondsFromConfig(value, fallback)
  }

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = nowIso()
    root.lastEvent = event + suffix
    console.log("omarchy idle " + root.lastEventAt + " " + root.lastEvent)
  }

  function runProcess(process, label, command) {
    if (process.running) {
      logEvent("process-skip", label + " already running")
      return false
    }
    logEvent("process-start", label + " " + command)
    process.command = ["bash", "-lc", command]
    process.running = true
    return true
  }

  function launchScreensaver() {
    root.screensaverStartedThisCycle = true
    screensaverLaunchGraceTimer.restart()
    runProcess(screensaverProcess, "screensaver", "[[ $(omarchy-shell lock isLocked 2>/dev/null) == \"true\" ]] || omarchy-launch-screensaver")
  }

  function lockSystem(reason) {
    logEvent("lock-system", reason || "requested")
    screensaverTimer.stop()
    lockTimer.stop()
    screensaverLaunchGraceTimer.stop()
    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
    runProcess(lockProcess, "lock", "omarchy-system-lock")
  }

  function startIdleCycle() {
    if (root.idledThisCycle) {
      logEvent("idle-cycle-already-running")
      return
    }

    logEvent("idle-cycle-start", "screensaver=" + root.screensaverTimeoutSeconds + " lock=" + root.lockTimeoutSeconds)
    root.idledThisCycle = true
    root.screensaverStartedThisCycle = false

    // Set this cycle's deadlines once: a bound interval would restart a pending
    // timer from the moment shell.json changes, locking early or late.
    if (root.screensaverEnabled) {
      if (root.screensaverDelaySeconds === 0) launchScreensaver()
      else {
        screensaverTimer.interval = root.screensaverDelaySeconds * 1000
        screensaverTimer.restart()
      }
    }

    if (root.lockEnabled) {
      if (root.lockDelaySeconds === 0) lockSystem("lock-timeout-immediate")
      else {
        lockTimer.interval = root.lockDelaySeconds * 1000
        lockTimer.restart()
      }
    }
  }

  function cancelIdleCycle(reason) {
    logEvent("idle-cycle-cancel", reason || "requested")
    screensaverTimer.stop()
    lockTimer.stop()
    screensaverLaunchGraceTimer.stop()

    if (root.idledThisCycle) runProcess(wakeProcess, "wake", "omarchy-system-wake")

    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
  }

  function handleScreensaverWindowsChanged() {
    var opened = root.screensaverWindowCount > root.previousScreensaverWindowCount
    root.previousScreensaverWindowCount = root.screensaverWindowCount

    if (opened) {
      screensaverLaunchGraceTimer.stop()
      // Outside a launch (a late map, or a screensaver already up when the shell starts) there is no screensaverReady to wait for.
      if (!root.screensaverInputReady && !root.screensaverLaunching) screensaverInputArmTimer.restart()
      return
    }

    if (root.screensaverWindowCount > 0) return
    screensaverInputArmTimer.stop()
    screensaverLaunchDeadlineTimer.stop()
    root.screensaverInputReady = false
    root.screensaverLaunching = false

    if (!root.idleEnabled || !root.idledThisCycle || !root.screensaverStartedThisCycle) return

    // The user dismissed the screensaver before the lock deadline. Treat that
    // as activity and cancel the pending lock; the lock timer is only allowed
    // to fire while the screensaver remains up.
    root.cancelIdleCycle("screensaver-dismissed")
  }

  function screensaverLaunchStarted() {
    root.screensaverLaunching = true
    screensaverLaunchDeadlineTimer.restart()
  }

  function screensaverLaunchFinished() {
    screensaverLaunchDeadlineTimer.stop()
    root.screensaverLaunching = false
    screensaverInputArmTimer.restart()
  }

  function dismissScreensaver() {
    logEvent("screensaver-dismiss", "input")
    root.screensaverInputReady = false
    screensaverDismissProcess.running = true
  }

  function handleActiveSignal() {
    if (!root.idledThisCycle) return

    // Starting the screensaver can make the compositor report activity. Keep
    // the lock timer running once the screensaver exists (or during its short
    // launch grace); the window closing cancels the cycle if it exits before
    // the normal lock deadline.
    if (root.screensaverStartedThisCycle && (root.screensaverWindowCount > 0 || screensaverLaunchGraceTimer.running)) {
      logEvent("idle-monitor-active", "screensaver cycle remains armed")
      return
    }

    cancelIdleCycle("activity")
  }

  function handleIdleChanged() {
    logEvent("idle-monitor", idleMonitor.isIdle ? "idle" : "active")
    if (!root.idleEnabled || !root.idleTimersEnabled) return

    if (idleMonitor.isIdle) startIdleCycle()
    else handleActiveSignal()
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.idleEnabled,
      stayAwake: root.stayAwake,
      stayAwakeStateLoaded: root.stayAwakeStateLoaded,
      stayAwakeStatePath: root.stayAwakeStatePath,
      idle: idleMonitor.isIdle,
      inIdleCycle: root.idledThisCycle,
      screensaverStarted: root.screensaverStartedThisCycle,
      screensaver: root.screensaverTimeoutSeconds,
      lock: root.lockTimeoutSeconds,
      screensaverDelay: root.screensaverDelaySeconds,
      lockDelay: root.lockDelaySeconds,
      screensaverWindows: root.screensaverWindowCount,
      screensaverInputReady: root.screensaverInputReady,
      screensaverLaunching: root.screensaverLaunching,
      timers: {
        screensaver: screensaverTimer.running,
        lock: lockTimer.running,
        screensaverLaunchGrace: screensaverLaunchGraceTimer.running,
        screensaverInputArm: screensaverInputArmTimer.running,
        screensaverLaunchDeadline: screensaverLaunchDeadlineTimer.running
      },
      processes: {
        screensaver: screensaverProcess.running,
        screensaverDismiss: screensaverDismissProcess.running,
        lock: lockProcess.running,
        wake: wakeProcess.running
      },
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  function persistStayAwake(value) {
    var command = value
      ? "mkdir -p \"$HOME/.local/state/omarchy/indicators\" && touch \"$HOME/.local/state/omarchy/indicators/stay-awake\""
      : "rm -f \"$HOME/.local/state/omarchy/indicators/stay-awake\""

    if (stayAwakeStateWriter.running) {
      root.pendingStayAwakePersist = !!value
      root.hasPendingStayAwakePersist = true
      return
    }

    stayAwakeStateWriter.command = ["bash", "-lc", command]
    stayAwakeStateWriter.running = true
  }

  function refreshStayAwakeState() {
    if (!stayAwakeStateProbe.running) stayAwakeStateProbe.running = true
  }

  function applyStayAwake(value, persist, reason) {
    var enabled = !!value
    var changed = !root.stayAwakeStateLoaded || root.stayAwake !== enabled

    if (persist) persistStayAwake(enabled)

    root.stayAwake = enabled
    root.stayAwakeStateLoaded = true

    if (!changed) return enabled ? "disabled" : "enabled"

    logEvent("stay-awake", (enabled ? "enabled" : "disabled") + (reason ? " " + reason : ""))
    if (enabled) cancelIdleCycle("stay-awake")
    else Qt.callLater(root.handleIdleChanged)

    return enabled ? "disabled" : "enabled"
  }

  function setIdleEnabled(value) {
    return applyStayAwake(!value, true, "ipc")
  }

  // With both timeouts at 0 the monitor stops reporting, so nothing else would end a running cycle.
  onIdleTimersEnabledChanged: if (!idleTimersEnabled) cancelIdleCycle("idle-timers-disabled")

  IdleMonitor {
    id: idleMonitor
    enabled: root.idleEnabled && root.idleTimersEnabled
    timeout: Math.max(1, root.firstIdleTimeoutSeconds)
    respectInhibitors: true
    onIsIdleChanged: root.handleIdleChanged()
  }

  // Ignore trailing input from the gesture that launched the screensaver.
  Timer {
    id: screensaverInputArmTimer
    interval: 500
    repeat: false
    onTriggered: {
      root.screensaverInputReady = root.screensaverWindowCount > 0
      if (root.screensaverInputReady) root.logEvent("screensaver-input-armed")
      if (root.screensaverInputReady && !screensaverInput.isIdle) root.dismissScreensaver()
    }
  }

  // A launcher killed mid-launch never sends screensaverReady. It reports each monitor and waits at
  // most 5s on one, so 15s without a report means it has stopped.
  Timer {
    id: screensaverLaunchDeadlineTimer
    interval: 15000
    repeat: false
    onTriggered: {
      root.logEvent("screensaver-launch-deadline")
      root.screensaverLaunchFinished()
    }
  }

  // Hyprland never resumes a zero-timeout notification; use one millisecond.
  IdleMonitor {
    id: screensaverInput
    enabled: root.screensaverWindowCount > 0
    timeout: 0.001
    respectInhibitors: false
    onIsIdleChanged: {
      if (enabled && !isIdle && root.screensaverInputReady) root.dismissScreensaver()
    }
  }

  Process {
    id: screensaverDismissProcess
    command: ["pkill", "-f", "[o]rg.omarchy.screensaver"]
  }

  Timer {
    id: screensaverTimer
    repeat: false
    onTriggered: if (root.screensaverEnabled) root.launchScreensaver()
  }

  Timer {
    id: lockTimer
    repeat: false
    onTriggered: if (root.idleEnabled && root.idledThisCycle && root.lockEnabled) root.lockSystem("lock-timeout")
  }

  Timer {
    id: screensaverLaunchGraceTimer
    interval: 3000
    repeat: false
    onTriggered: {
      if (root.idleEnabled && root.idledThisCycle && root.screensaverStartedThisCycle && root.screensaverWindowCount === 0 && !idleMonitor.isIdle) {
        root.cancelIdleCycle("screensaver-not-running")
      }
    }
  }

  onScreensaverWindowCountChanged: handleScreensaverWindowsChanged()

  Process {
    id: screensaverProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "screensaver exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: lockProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "lock exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: wakeProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "wake exitCode=" + exitCode + " status=" + exitStatus) }
  }

  Process {
    id: stayAwakeStateProbe
    command: ["bash", "-c", "mkdir -p \"$HOME/.local/state/omarchy/indicators\"; if [[ -f $HOME/.local/state/omarchy/indicators/stay-awake ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.applyStayAwake(String(line).trim() === "yes", false, "state-file") }
    }
    onExited: function() { stayAwakeStateDirWatcher.reload() }
  }

  Process {
    id: stayAwakeStateWriter
    onExited: function() {
      if (root.hasPendingStayAwakePersist) {
        var pending = root.pendingStayAwakePersist
        root.hasPendingStayAwakePersist = false
        root.persistStayAwake(pending)
        return
      }

      root.refreshStayAwakeState()
    }
  }

  FileView {
    id: stayAwakeStateDirWatcher
    path: root.stayAwakeStateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStayAwakeState()
  }

  Component.onCompleted: {
    logEvent("service-ready")
    refreshStayAwakeState()
  }

  ShellIpc {
    target: "idle"

    function status(): string {
      return root.statusJson()
    }

    function debug(): string {
      return root.statusJson()
    }

    function screensaverLaunching(): void {
      root.screensaverLaunchStarted()
    }

    function screensaverReady(): void {
      root.screensaverLaunchFinished()
    }

    function enable(): string {
      return root.setIdleEnabled(true)
    }

    function disable(): string {
      return root.setIdleEnabled(false)
    }

    function toggle(): string {
      return root.setIdleEnabled(!root.idleEnabled)
    }
  }
}
