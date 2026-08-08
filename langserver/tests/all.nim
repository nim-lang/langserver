import
  textensions,
  tfindnimblepaths,
  thover,
  tknownbug3,
  tmaxlimits,
  tmisc,
  tmonorepo2,
  tmonorepo3,
  tmonorepo4,
  tmonorepo5,
  tnimlangserver,
  tprojectsetup,
  tstability,
  tsuggestapi,
  ttestrunner

# The whole aim of this file is to be a projectFile/entryPoint for nimsuggest to serve any file in the tests folder, as by default, a nimsuggest instance spawned with `src/nimtortoise.nim` as the projectFile will not know about the tests, as imports are transitive, and tests know about the src, but src doesn't know about the tests.

