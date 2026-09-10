import
  tsuggestapi,
  tnimlangserver

# XXX getNimPath's nimsuggestPath missing ExeExt
when not defined(windows):
  import
    tnimtrack

import
  tprojectsetup,
  textensions,
  tmisc,
  ttestrunner,
  tmcp,
  tasyncsafety
