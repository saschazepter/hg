Set up

  $ hg init repo
  $ cd repo
  $ echo a > a
  $ hg add a
  $ hg commit -m a

Try to import an empty patch

  $ hg import --no-commit - <<EOF
  > EOF
  applying patch from stdin
  abort: stdin: no diffs found
  [10]

No dirstate backups are left behind

  $ ls .hg/dirstate* | sort
  .hg/dirstate

