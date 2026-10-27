import QtQuick
import Quickshell
import Quickshell.Io
import "idle" as Idle

// Runs the real idle service against real screensaver-class windows: one the
// test opened before this shell started, then one opened here mid-launch.
ShellRoot {
  id: test
  property bool failed: false

  function check(ok, message) {
    if (!ok) {
      failed = true
      console.log("RESULT fail " + message)
    }
  }

  Idle.Service { id: service }

  Process {
    id: launchedWindow
    command: ["foot", "--app-id=org.omarchy.screensaver", "-e", "sleep", "30"]
  }

  Process {
    id: closeEarlyWindow
    command: ["kill", Quickshell.env("SCREENSAVER_PID")]
  }

  SequentialAnimation {
    running: true

    PauseAnimation { duration: 1500 }
    ScriptAction {
      script: {
        test.check(service.screensaverWindowCount === 1, "a screensaver open before the shell started is counted, got " + service.screensaverWindowCount)
        test.check(service.screensaverInputReady, "input arms for a screensaver open before the shell started")
        closeEarlyWindow.running = true
      }
    }

    PauseAnimation { duration: 1500 }
    ScriptAction {
      script: {
        test.check(service.screensaverWindowCount === 0, "a closed screensaver leaves the count, got " + service.screensaverWindowCount)
        test.check(!service.screensaverInputReady, "input disarms once every screensaver has closed")
        service.screensaverLaunchStarted()
        launchedWindow.running = true
      }
    }

    PauseAnimation { duration: 2000 }
    ScriptAction {
      script: {
        test.check(service.screensaverWindowCount === 1, "a screensaver opened mid-launch is counted, got " + service.screensaverWindowCount)
        test.check(!service.screensaverInputReady, "input stays unarmed until the launch reports ready")
        service.screensaverLaunchFinished()
      }
    }

    PauseAnimation { duration: 1000 }
    ScriptAction {
      script: {
        test.check(service.screensaverInputReady, "input arms once the launch reports ready")
        launchedWindow.running = false
      }
    }

    PauseAnimation { duration: 1500 }
    ScriptAction {
      script: {
        test.check(service.screensaverWindowCount === 0, "the launched screensaver leaves the count once closed, got " + service.screensaverWindowCount)
        console.log(test.failed ? "RESULT fail" : "RESULT pass")
        Qt.quit()
      }
    }
  }
}
