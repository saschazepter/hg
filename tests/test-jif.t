====================
Basic jif testing
====================

#require jif

Test behavior of repo command outside a repo
  $ jf status
  abort: no repository found in $TESTTMP
  [255]

Humans get errors on stderr, machines get them as normal records on stdout

  $ jf status >/dev/null
  abort: no repository found in $TESTTMP
  [255]
  $ jf status 2>/dev/null
  [255]
  $ jf status --do-not-use-format json 2>/dev/null
  {"_internal_jf_kind":"error","code":"repo-not-found","context":[],"hint":null,"message":{"args":{"path":"$TESTTMP"},"template":"no repository found in {path}","text":"no repository found in $TESTTMP"},"snippets":[]}
  [255]
  $ jf status --do-not-use-format json >/dev/null
  [255]

Get a small repo

  $ hg init repo
  $ cd repo

Test some status output

  $ echo foo > foo
  $ jf status
  ? foo

  $ hg add foo
  $ jf status
  A foo

  $ hg commit -m 'foo'
  $ echo bar > bar
  $ jf status
  ? bar

  $ hg add bar
  $ jf status
  A bar

  $ echo fuz > foo
  $ jf status
  A bar
  M foo

  $ hg commit -m 'fuz'
  $ hg remove foo
  $ jf st
  R foo

Test copies, and output for machines

  $ hg copy bar baz
  $ jf status
  R foo
  A baz
    bar
  $ jf status --do-not-use-format json
  {"_internal_jf_kind":"status","path":"foo","status":"R"}
  {"_internal_jf_kind":"status","copy_source":"bar","path":"baz","status":"A"}

Test warnings

  $ echo 'syntax: bogus' > .hgignore
  $ jf status
  warning: $TESTTMP/repo/.hgignore: ignoring invalid syntax 'bogus'
  R foo
  A baz
    bar
  ? .hgignore
  $ jf status --do-not-use-format json
  {"_internal_jf_kind":"warning","message":{"args":{"path":"$TESTTMP/repo/.hgignore","syntax":"bogus"},"template":"{path}: ignoring invalid syntax '{syntax}'","text":"$TESTTMP/repo/.hgignore: ignoring invalid syntax 'bogus'"},"snippets":[]}
  {"_internal_jf_kind":"status","path":"foo","status":"R"}
  {"_internal_jf_kind":"status","copy_source":"bar","path":"baz","status":"A"}
  {"_internal_jf_kind":"status","path":".hgignore","status":"?"}
