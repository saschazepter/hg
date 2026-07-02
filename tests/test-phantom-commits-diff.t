#require rust

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > phantom_commits=
  > 
  > [phantom_commits]
  > bookmark = phantom
  > ai-user = ai
  > 
  > [defaults]
  > # Use --git to show empty file additions.
  > # Use --nodates to make tests less noisy.
  > phantom-commits::diff=--git --nodates
  > EOF

Set up repo
-----------

  $ hg init repo1
  $ cd repo1
  $ hg bookmark b1
  $ cat << EOF > .hgignore
  > syntax: glob
  > *.ignore
  > EOF
  $ hg ci -qAm "add .hgignore"
  $ touch file
  $ hg commit -qAm "add file"
  $ echo A > file
  $ hg commit -m "A"
  $ echo B > file
  $ hg commit -m "B"
  $ echo C > file
  $ hg commit -m "C"

  $ hg log -T '{rev}: {desc}\n'
  4: C
  3: B
  2: A
  1: add file
  0: add .hgignore

Helpers
-------

Helper to reset state to make each test independent
  $ reset_changes() {
  >   hg update -qr 4 --clean
  >   hg bookmark b1 --force
  >   hg purge --no-confirm --all
  >   touch newfile
  > }

Test behavior with no arguments
-------------------------------

No phantom bookmark set
  $ hg phantom-commits::diff
  $ touch newfile
  $ hg phantom-commits::diff
  diff --git a/newfile b/newfile
  new file mode 100644

Create a phantom commit
  $ hg create-phantom-commit -q --message "initial"

No changes
  $ hg phantom-commits::diff

Modified file
  $ echo modified > newfile
  $ hg phantom-commits::diff
  diff --git a/newfile b/newfile
  --- a/newfile
  +++ b/newfile
  @@ -0,0 +1,1 @@
  +modified
  $ reset_changes

Added file
  $ touch added
  $ hg phantom-commits::diff
  diff --git a/added b/added
  new file mode 100644
  $ hg add added
  $ hg phantom-commits::diff
  diff --git a/added b/added
  new file mode 100644
  $ reset_changes

Removed file
  $ rm file
  $ hg phantom-commits::diff
  diff --git a/file b/file
  deleted file mode 100644
  --- a/file
  +++ /dev/null
  @@ -1,1 +0,0 @@
  -C
  $ hg rm file
  $ hg phantom-commits::diff
  diff --git a/file b/file
  deleted file mode 100644
  --- a/file
  +++ /dev/null
  @@ -1,1 +0,0 @@
  -C
  $ reset_changes

Multiple changes
  $ echo modified > file
  $ touch added
  $ rm newfile
  $ hg phantom-commits::diff
  diff --git a/added b/added
  new file mode 100644
  diff --git a/file b/file
  --- a/file
  +++ b/file
  @@ -1,1 +1,1 @@
  -C
  +modified
  diff --git a/newfile b/newfile
  deleted file mode 100644
  $ reset_changes

Test file pattern arguments
---------------------------

  $ echo change > file
  $ touch added
  $ rm newfile
  $ hg phantom-commits::diff does-not-exist
  does-not-exist: $ENOENT$
  does-not-exist: $ENOENT$
  $ hg phantom-commits::diff file
  diff --git a/file b/file
  --- a/file
  +++ b/file
  @@ -1,1 +1,1 @@
  -C
  +change
  $ hg phantom-commits::diff added
  diff --git a/added b/added
  new file mode 100644
  $ hg phantom-commits::diff newfile
  diff --git a/newfile b/newfile
  deleted file mode 100644
  $ hg phantom-commits::diff 'glob:*file'
  diff --git a/file b/file
  --- a/file
  +++ b/file
  @@ -1,1 +1,1 @@
  -C
  +change
  diff --git a/newfile b/newfile
  deleted file mode 100644
  $ hg phantom-commits::diff --include file
  diff --git a/file b/file
  --- a/file
  +++ b/file
  @@ -1,1 +1,1 @@
  -C
  +change
  $ hg phantom-commits::diff --exclude file
  diff --git a/added b/added
  new file mode 100644
  diff --git a/newfile b/newfile
  deleted file mode 100644
  $ reset_changes

Test size limit
---------------

  >>> open("large.txt", "wb").write(b"x" * 51)
  51
  $ hg phantom-commits::diff --config phantom_commits.unknown-files.size-limit=50
  phantom_commits: ignoring 'large.txt' (51 bytes) since it exceeds size limit (50 bytes)
  $ hg phantom-commits::diff --config phantom_commits.unknown-files.size-limit=50 2>/dev/null
  $ reset_changes

Test --from and --to flags
--------------------------

Both --from and --to not allowed
  $ hg phantom-commits::diff --from . --to .
  abort: cannot specify both --from and --to
  [10]

Diff --from
  $ hg phantom-commits::diff --from 0
  diff --git a/file b/file
  new file mode 100644
  --- /dev/null
  +++ b/file
  @@ -0,0 +1,1 @@
  +C
  diff --git a/newfile b/newfile
  new file mode 100644
  $ hg phantom-commits::diff --from .
  diff --git a/newfile b/newfile
  new file mode 100644
  $ hg phantom-commits::diff --from phantom

Diff --to
  $ hg phantom-commits::diff --to 0
  diff --git a/file b/file
  deleted file mode 100644
  --- a/file
  +++ /dev/null
  @@ -1,1 +0,0 @@
  -C
  diff --git a/newfile b/newfile
  deleted file mode 100644
  $ hg phantom-commits::diff --to .
  diff --git a/newfile b/newfile
  deleted file mode 100644
  $ hg phantom-commits::diff --to phantom

  $ reset_changes

Test --validate-phantom flag
----------------------------

This flag is tested more extensively in test-phantom-commits-status.t.

It validates both --from and --to
  $ hg phantom-commits::diff --from 0 --validate-phantom
  abort: * is invalid according to --validate-phantom (glob)
  [10]
  $ hg phantom-commits::diff --to 0 --validate-phantom
  abort: * is invalid according to --validate-phantom (glob)
  [10]

Test --since-last-ai flag
-------------------------

This flag is tested more extensively in test-phantom-commits-status.t.

Not allowed with --from or --to
  $ hg phantom-commits::diff --from . --since-last-ai
  abort: cannot specify both --from and --since-last-ai
  [10]
  $ hg phantom-commits::diff --to . --since-last-ai
  abort: cannot specify both --to and --since-last-ai
  [10]

Set the config for --since-last-ai
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > last-ai-bookmark=phantom-last-ai
  > EOF

No AI phantom commit
  $ hg phantom-commits::diff --since-last-ai
  there is no last AI phantom commit

Make an AI phantom commit
  $ touch ai
  $ hg create-phantom-commit -q --ai --message "ai"

AI phantom commit, no changes
  $ hg phantom-commits::diff --since-last-ai

AI phantom commit, some changes
  $ echo modified > file
  $ hg phantom-commits::diff --since-last-ai
  diff --git a/file b/file
  --- a/file
  +++ b/file
  @@ -1,1 +1,1 @@
  -C
  +modified

  $ reset_changes
