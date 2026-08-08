--hints: off
--debuginfo
--threads:on
--define:"debugLogging=on"
--define:"chronicles_disable_thread_id"
--define:"async_backend=asyncdispatch"
--define:"chronicles_timestamps=None"
--define:"debugLogging"
--define:"test"

# Put all test executables in the repo's bin/ directory
switch("outdir", thisDir() & "/../bin")
