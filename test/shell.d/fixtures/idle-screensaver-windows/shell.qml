import QtQuick
import Quickshell
import Quickshell.Io
import "idle" as Idle

// Runs the real idle service against real screensaver-class windows: one the
// test opened before this shell started, then one opened from here.
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
    id: lateWindow
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
        lateWindow.running = true
      }
    }

    PauseAnimation { duration: 2000 }
    ScriptAction {
      script: {
        test.check(service.screensaverWindowCount === 2, "a screensaver opened later is counted, got " + service.screensaverWindowCount)
        test.check(service.screensaverInputReady, "input stays armed when another screensaver opens")
        lateWindow.running = false
        closeEarlyWindow.running = true
      }
    }

    PauseAnimation { duration: 1500 }
    ScriptAction {
      script: {
        test.check(service.screensaverWindowCount === 0, "closed screensavers leave the count, got " + service.screensaverWindowCount)
        test.check(!service.screensaverInputReady, "input disarms once every screensaver has closed")
        console.log(test.failed ? "RESULT fail" : "RESULT pass")
        Qt.quit()
      }
    }
  }
}
