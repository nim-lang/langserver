# Monitor a client process and shutdown the current process, if the client
# process is found to be dead

import os, asyncdispatch

when defined(posix):
  import posix_utils
  import posix

when defined(windows):
  import winlean

when defined(windows):
  proc hookAsyncProcMonitor*(pid: int, cb: Callback) =
    addProcess(pid, cb)

when defined(posix):
  proc hookAsyncProcMonitor*(pid: int, cb: Callback) =

    var processExitCallbackCalled = false

    proc checkProcCallback(fd: AsyncFD): bool =
      if not processExitCallbackCalled:
        try:
          sendSignal(Pid(pid), 0)
        except:
          processExitCallbackCalled = true
          result = cb(fd)
      else:
        result = true

    addTimer(1000, false, checkProcCallback)
