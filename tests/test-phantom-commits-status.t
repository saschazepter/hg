#require rust

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > phantom_commits=
  > 
  > [phantom_commits]
  > bookmark = phantom
  > ai-user = ai
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
  $ hg phantom-commits::status
  $ touch newfile
  $ hg phantom-commits::status
  A newfile

Create a phantom commit
  $ hg create-phantom-commit -q --message "initial"

No changes
  $ hg phantom-commits::status

Modified file
  $ echo modified > newfile
  $ hg phantom-commits::status
  M newfile
  $ reset_changes

Added file
  $ touch added
  $ hg phantom-commits::status
  A added
  $ hg add added
  $ hg phantom-commits::status
  A added
  $ reset_changes

Removed file
  $ rm file
  $ hg phantom-commits::status
  R file
  $ hg rm file
  $ hg phantom-commits::status
  R file
  $ reset_changes

Multiple changes
  $ echo modified > file
  $ touch added
  $ rm newfile
  $ hg phantom-commits::status
  M file
  A added
  R newfile
  $ reset_changes

Test file pattern arguments
---------------------------

  $ echo change > file
  $ touch added
  $ rm newfile
  $ hg phantom-commits::status does-not-exist
  does-not-exist: $ENOENT$
  $ hg phantom-commits::status file
  M file
  $ hg phantom-commits::status added
  A added
  $ hg phantom-commits::status newfile
  R newfile
  $ hg phantom-commits::status 'glob:*file'
  M file
  R newfile
  $ hg phantom-commits::status --include file
  M file
  $ hg phantom-commits::status --exclude file
  A added
  R newfile
  $ reset_changes

Test size limit
---------------

  >>> open("large.txt", "wb").write(b"x" * 51)
  51
  $ hg phantom-commits::status --config phantom_commits.unknown-files.size-limit=50
  phantom_commits: ignoring 'large.txt' (51 bytes) since it exceeds size limit (50 bytes)
  $ hg phantom-commits::status --config phantom_commits.unknown-files.size-limit=50 2>/dev/null
  $ reset_changes

Test --from and --to flags
--------------------------

Both --from and --to not allowed
  $ hg phantom-commits::status --from . --to .
  abort: cannot specify both --from and --to
  [10]

Status --from
  $ hg phantom-commits::status --from 0
  A file
  A newfile
  $ hg phantom-commits::status --from .
  A newfile
  $ hg phantom-commits::status --from phantom

Status --to
  $ hg phantom-commits::status --to 0
  R file
  R newfile
  $ hg phantom-commits::status --to .
  R newfile
  $ hg phantom-commits::status --to phantom

Make some changes
  $ echo modified > file
  $ touch added
  $ rm newfile

Status --from, after changes
  $ hg phantom-commits::status --from 0
  A added
  A file
  $ hg phantom-commits::status --from .
  M file
  A added
  $ hg phantom-commits::status --from phantom
  M file
  A added
  R newfile

Status --to, after changes
  $ hg phantom-commits::status --to 0
  R added
  R file
  $ hg phantom-commits::status --to .
  M file
  R added
  $ hg phantom-commits::status --to phantom
  M file
  A newfile
  R added

  $ reset_changes

Test --validate-phantom flag
----------------------------

It validates both --from and --to
  $ hg phantom-commits::status --from 0 --validate-phantom
  abort: * is invalid according to --validate-phantom (glob)
  [10]
  $ hg phantom-commits::status --to 0 --validate-phantom
  abort: * is invalid according to --validate-phantom (glob)
  [10]

The working directory and active phantom commits are allowed
  $ hg phantom-commits::status --from . --validate-phantom
  A newfile
  $ hg phantom-commits::status --from phantom --validate-phantom

Make another phantom commit, then try the middle one
  $ middle=$(hg log -r phantom -T '{node}')
  $ echo modified > file
  $ hg create-phantom-commit -q --message test
  $ hg phantom-commits::status --from $middle --validate-phantom
  M file
  $ hg phantom-commits::status --from phantom --validate-phantom

Stale phantom commits aren't allowed
  $ hg commit -qAm commit
  $ hg phantom-commits::status --from $middle --validate-phantom
  abort: * is invalid according to --validate-phantom (glob)
  [10]

  $ reset_changes

Test --since-last-ai flag
-------------------------

Not allowed with --from or --to
  $ hg phantom-commits::status --from . --since-last-ai
  abort: cannot specify both --from and --since-last-ai
  [10]
  $ hg phantom-commits::status --to . --since-last-ai
  abort: cannot specify both --to and --since-last-ai
  [10]

The --since-last-ai flag requires config
  $ hg phantom-commits::status --since-last-ai
  abort: the --since-last-ai flag requires setting the config phantom_commits.last-ai-bookmark
  [255]

Set the config for --since-last-ai
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > last-ai-bookmark=phantom-last-ai
  > EOF

No AI phantom commit
  $ hg phantom-commits::status --since-last-ai
  there is no last AI phantom commit
  $ hg phantom-commits::status --since-last-ai 2>/dev/null

Make an AI phantom commit
  $ touch ai
  $ hg create-phantom-commit -q --ai --message "ai"

The --since-last-ai flag makes no difference when latest phantom commit is AI
  $ hg phantom-commits::status
  $ hg phantom-commits::status --since-last-ai
  $ echo modified > file
  $ rm ai
  $ touch anotherfile
  $ hg phantom-commits::status
  M file
  A anotherfile
  R ai
  $ hg phantom-commits::status --since-last-ai
  M file
  A anotherfile
  R ai

Make a human phantom commit
  $ touch human
  $ hg create-phantom-commit -q --message "human"

The --since-last-ai flag makes a difference when latest phantom commit is human
  $ hg phantom-commits::status
  $ hg phantom-commits::status --since-last-ai
  M file
  A anotherfile
  A human
  R ai
  $ rm human
  $ touch newfile2
  $ echo modified2 > file
  $ hg phantom-commits::status
  M file
  A newfile2
  R human
  $ hg phantom-commits::status --since-last-ai
  M file
  A anotherfile
  A newfile2
  R ai

After committing, the status is clean
  $ hg commit -qAm commit
  $ hg status
  $ hg phantom-commits::status

But --since-last-ai still goes from the last AI phantom commit
  $ hg phantom-commits::status --since-last-ai
  M file
  A anotherfile
  A newfile2
  R ai

It does status from wdir if the phantom bookmark is stale
  $ echo modified3 > file
  $ hg create-phantom-commit -q --ai --message test
  $ hg revert --all --quiet --no-backup
  $ hg purge --no-confirm --all
  $ hg update -q '.^'
  $ hg phantom-commits::status
  ignoring stale phantom bookmark phantom (*) (glob)
  $ hg phantom-commits::status 2>/dev/null

But status --since-last-ai does not look at the phantom bookmark at all, so it
doesn't care that it's stale
  $ hg phantom-commits::status --since-last-ai
  M file
  R anotherfile
  R newfile
  R newfile2
  $ hg phantom-commits::status --since-last-ai 2>/dev/null
  M file
  R anotherfile
  R newfile
  R newfile2

  $ reset_changes
