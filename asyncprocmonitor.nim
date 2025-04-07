# Monitor a client process and shutdown the current process, if the client
# process is found to be dead

import chronos

when defined(posix):
  import posix_utils
  import posix

type Callback* = proc() {.closure, gcsafe, raises: [].}

when defined(windows):
  import winlean, sugar

  proc hookAsyncProcMonitor*(pid: int, cb: Callback) =
    discard addProcess2(pid, (arg: pointer) => cb())

elif defined(posix):
  proc hookAsyncProcMonitor*(pid: int, cb: Callback) =
    var processExitCallbackCalled = false

    proc checkProcCallback(arg: pointer) =
      if not processExitCallbackCalled:
        try:
          sendSignal(Pid(pid), 0)
        except:
          processExitCallbackCalled = true

    addTimer(1000.int64, checkProcCallback)
