#require rust

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > phantom_commits=
  > EOF

  $ hg init repo1
  $ cd repo1

Test required flags and config
------------------------------

Must pass --message
  $ hg create-phantom-commit
  abort: --message is required
  [10]

Must set the bookmark name
  $ hg create-phantom-commit --message message
  abort: missing config phantom_commits.bookmark
  [10]

Must set the ai username
  $ hg create-phantom-commit --message message --config phantom_commits.bookmark=phantom
  abort: missing config phantom_commits.ai-user
  [10]

The bookmark template can only use {bookmark}
  $ hg create-phantom-commit --message message --config phantom_commits.bookmark='test-{invalid}' --config phantom_commits.ai-user=ai
  abort: phantom_commits.bookmark has unexpected '{' or '}'
  [10]

The ai-user template can only use {user}
  $ hg create-phantom-commit --message message --config phantom_commits.bookmark=phantom --config phantom_commits.ai-user=test-{invalid}
  abort: phantom_commits.ai-user has unexpected '{' or '}'
  [10]

If using {bookmark}, must have an active bookmark
  $ hg create-phantom-commit --message message --config phantom_commits.bookmark='{bookmark}/phantom' --config phantom_commits.ai-user=ai
  abort: phantom_commits.bookmark contains '{bookmark}', but there is no active bookmark
  [10]

If using {user}, must have a user set
  $ (unset HGUSER; unset EMAIL; hg create-phantom-commit --message message --config phantom_commits.bookmark='phantom' --config phantom_commits.ai-user=ai-{user})
  abort: phantom_commits.ai-user contains '{user}', but username cannot be determined (no HGUSER, no EMAIL, no ui.username)
  [10]

A bookmark must be active
  $ hg create-phantom-commit --message message --config phantom_commits.bookmark=phantom --config phantom_commits.ai-user=ai
  abort: a bookmark must be active
  [20]

Set up repo
-----------

  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > bookmark = phantom
  > ai-user = ai
  > EOF

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

Test basics
-----------

This section tests create-phantom-commit for individual changes.

Helper to reset state to make each test independent
  $ reset_changes() {
  >   hg revert --all --quiet --no-backup
  >   hg purge --no-confirm --all
  >   hg bookmark --delete phantom
  > }

No changes
  $ hg create-phantom-commit --message nothing
  no-changes
  $ hg status
  $ hg status --change phantom
  abort: unknown revision 'phantom'
  [10]

Modify file
  $ echo modified > file
  $ hg create-phantom-commit --message "modify"
  in-progress
  revision * (glob)
  $ hg status
  M file
  $ hg status --change phantom
  M file
  $ reset_changes

Add file
  $ touch added
  $ hg add added
  $ hg create-phantom-commit --message "add"
  in-progress
  revision * (glob)
  $ hg status
  A added
  $ hg status --change phantom
  A added
  $ reset_changes

Create ignored file
  $ touch file.ignore
  $ hg create-phantom-commit --message "add file.ignore"
  no-changes

Add the ignored file
  $ hg add file.ignore
  $ hg create-phantom-commit --message "add file.ignore"
  in-progress
  revision * (glob)
  $ hg status
  A file.ignore
  $ hg status --change phantom
  A file.ignore
  $ reset_changes

Create untracked file
  $ touch untracked
  $ hg create-phantom-commit --message "untracked"
  in-progress
  revision * (glob)
  $ hg status
  ? untracked
  $ hg status --change phantom
  A untracked
  $ reset_changes

Remove file
  $ hg rm file
  $ hg create-phantom-commit --message "remove"
  in-progress
  revision * (glob)
  $ hg status
  R file
  $ hg status --change phantom
  R file
  $ reset_changes

Forget file (still on disk)
  $ hg forget file
  $ hg create-phantom-commit --message "forget"
  in-progress
  revision * (glob)
  $ hg status
  R file
  $ hg status --change phantom
  R file
  $ reset_changes

Delete file (still tracked)
  $ rm file
  $ hg create-phantom-commit --message "delete"
  in-progress
  revision * (glob)
  $ hg status
  ! file
  $ hg status --change phantom
  R file
  $ reset_changes

Rename file
TODO: track copy sources in phantom commits
  $ hg mv file renamed
  $ hg create-phantom-commit --message "rename"
  in-progress
  revision * (glob)
  $ hg status --copies
  A renamed
    file
  R file
  $ hg status --copies --change phantom
  A renamed
    file (missing-correct-output !)
  R file
  $ reset_changes

Copy file
TODO: track copy sources in phantom commits
  $ hg cp file copied
  $ hg create-phantom-commit --message "rename"
  in-progress
  revision * (glob)
  $ hg status --copies
  A copied
    file
  $ hg status --copies --change phantom
  A copied
    file (missing-correct-output !)
  $ reset_changes

Test special files
------------------

This section tests create-phantom-commit for special kinds of files: binary
(containing null byte), executable ('x' flag), and symlinks ('l' flag).

Binary file
  >>> open("binary", "wb").write(b"\x00")
  1
  $ hg create-phantom-commit --message "binary"
  in-progress
  revision * (glob)
  $ hg diff --change phantom --git
  diff --git a/binary b/binary
  new file mode 100644
  index 0000000000000000000000000000000000000000..f76dd238ade08917e6712764a16a22005a50573d
  GIT binary patch
  literal 1
  Ic${MZ000310RR91
  
  $ reset_changes

Executable file
  $ chmod +x file
  $ hg create-phantom-commit --message "executable"
  in-progress
  revision * (glob)
  $ hg diff --change phantom --git
  diff --git a/file b/file
  old mode 100644
  new mode 100755
  $ reset_changes

Symlink (broken, since nothing should be trying to follow it)
  $ ln -s broken symlink
  $ hg create-phantom-commit --message "symlink"
  in-progress
  revision * (glob)
  $ hg diff --change phantom --git
  diff --git a/symlink b/symlink
  new file mode 120000
  --- /dev/null
  +++ b/symlink
  @@ -0,0 +1,1 @@
  +broken
  \ No newline at end of file
  $ reset_changes

Test unknown files size limit
-----------------------------

This section tests the config phantom_commits.unknown-files.size-limit.

Unknown files that exceed the limit are not committed
  >>> open("small.txt", "wb").write(b"x" * 50)
  50
  >>> open("large.txt", "wb").write(b"x" * 51)
  51
  $ hg status
  ? large.txt
  ? small.txt
  $ hg create-phantom-commit --message "size limit" --config phantom_commits.unknown-files.size-limit=50
  phantom_commits: ignoring 'large.txt' (51 bytes) since it exceeds size limit (50 bytes)
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A small.txt
  $ reset_changes

The limit does not apply to modified/added files
  >>> open("file", "wb").write(b"x" * 51)
  51
  >>> open("newfile", "wb").write(b"x" * 51)
  51
  $ hg add newfile
  $ hg status
  M file
  A newfile
  $ hg create-phantom-commit --message "size limit" --config phantom_commits.unknown-files.size-limit=50
  in-progress
  revision * (glob)
  $ hg status --change phantom
  M file
  A newfile
  $ reset_changes

If the only change is a file past the size limit, it doesn't create a commit
  >>> open("large.txt", "wb").write(b"x" * 51)
  51
  $ hg create-phantom-commit --message "size limit" --config phantom_commits.unknown-files.size-limit=50
  phantom_commits: ignoring 'large.txt' (51 bytes) since it exceeds size limit (50 bytes)
  no-changes
  $ rm large.txt

Test file patterns
------------------

This section tests creating phantom commits for specific files using pattern
arguments and --include/--exclude flags.

No changes
  $ hg create-phantom-commit --message "test" file
  no-changes
  $ hg create-phantom-commit --message "test" does-not-exist
  does-not-exist: $ENOENT$
  no-changes
  $ hg create-phantom-commit --message "test" 'glob:*.py'
  no-changes
  $ hg create-phantom-commit --message "test" --include file
  no-changes
  $ hg create-phantom-commit --message "test" --exclude file
  no-changes

Changes ignored
  $ touch foo.ignore
  $ hg status -i
  I foo.ignore
  $ hg create-phantom-commit --message "test" foo.ignore
  no-changes
  $ rm foo.ignore

Changes excluded by pattern
  $ echo change > file
  $ hg create-phantom-commit --message "test" does-not-exist
  does-not-exist: $ENOENT$
  no-changes
  $ hg create-phantom-commit --message "test" 'glob:*.py'
  no-changes
  $ hg create-phantom-commit --message "test" --include other
  no-changes
  $ hg create-phantom-commit --message "test" --exclude file
  no-changes

Changes included by pattern
  $ echo change1 > file
  $ hg create-phantom-commit --message "test" file
  in-progress
  revision * (glob)
  $ echo change2 > file
  $ hg create-phantom-commit --message "test" filepath:file
  in-progress
  revision * (glob)
  $ echo change3 > file
  $ hg create-phantom-commit --message "test" 'glob:fi*'
  in-progress
  revision * (glob)
  $ reset_changes

Add file
  $ touch added
  $ hg create-phantom-commit --message "test" added
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A added
  $ reset_changes

Remove file (existed in parent)
  $ rm file
  $ hg create-phantom-commit --message "test" file
  in-progress
  revision * (glob)
  $ hg status --change phantom
  R file
  $ reset_changes

Remove file (did not exist in parent)
  $ touch newfile
  $ hg create-phantom-commit --message "test"
  in-progress
  revision * (glob)
  $ rm newfile
  $ hg create-phantom-commit --message "test" newfile
  in-progress
  revision * (glob)
  $ hg status --change phantom
  $ hg status --from $(hg log -r phantom -T '{get(extras, "phantom_prev")}') --to phantom
  R newfile
  $ reset_changes

Commit partial changes
  $ echo change > file
  $ echo "# comment" >> .hgignore
  $ touch newfile
  $ hg status
  M .hgignore
  M file
  ? newfile
  $ hg create-phantom-commit --message "test" file
  in-progress
  revision * (glob)
  $ hg status --change phantom
  M file
  $ reset_changes

Partial commit should retain previous modification
  $ echo change > file
  $ touch other
  $ hg create-phantom-commit --message "test" file
  in-progress
  revision * (glob)
  $ hg create-phantom-commit --message "test" other
  in-progress
  revision * (glob)
  $ hg status --change phantom
  M file
  A other
  $ hg status --from $(hg log -r phantom -T '{get(extras, "phantom_prev")}') --to phantom
  A other
  $ reset_changes

Partial commit should retain previous addition
  $ touch added
  $ hg create-phantom-commit --message "test"
  in-progress
  revision * (glob)
  $ touch other
  $ hg create-phantom-commit --message "test" other
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A added
  A other
  $ hg status --from $(hg log -r phantom -T '{get(extras, "phantom_prev")}') --to phantom
  A other
  $ reset_changes

Partial commit should retain previous removal (existed in parent)
  $ rm file
  $ hg create-phantom-commit --message "test"
  in-progress
  revision * (glob)
  $ touch other
  $ hg create-phantom-commit --message "test" other
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A other
  R file
  $ hg status --from $(hg log -r phantom -T '{get(extras, "phantom_prev")}') --to phantom
  A other
  $ reset_changes

Partial commit should retain previous removal (did not exist in parent)
  $ touch newfile
  $ hg create-phantom-commit --message "test"
  in-progress
  revision * (glob)
  $ rm newfile
  $ hg create-phantom-commit --message "test"
  in-progress
  revision * (glob)
  $ touch other
  $ hg create-phantom-commit --message "test" other
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A other
  $ hg status --from $(hg log -r phantom -T '{get(extras, "phantom_prev")}') --to phantom
  A other
  $ reset_changes

Specify changed file and clean file (no previous phantom commit)
  $ echo 1 > newfile
  $ hg create-phantom-commit --message "test" newfile file
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A newfile
  $ reset_changes

Specify changed file and clean file (also clean in previous phantom commit)
  $ echo 1 > newfile
  $ hg create-phantom-commit --message "test" newfile file
  in-progress
  revision * (glob)
  $ echo 2 > newfile
  $ hg create-phantom-commit --message "test" newfile file
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A newfile
  $ reset_changes

Specify changed file and clean file (not clean in previous phantom commit)
  $ echo change > file
  $ echo 1 > newfile
  $ hg create-phantom-commit --message "test" newfile file
  in-progress
  revision * (glob)
  $ hg revert --no-backup file
  $ echo 2 > newfile
  $ hg create-phantom-commit --message "test" newfile file
  in-progress
  revision * (glob)
  $ hg status --change phantom
  A newfile
  $ reset_changes

Test multiple commits
---------------------

This section tests creating a sequence of multiple phantom commits.

Make change and create phantom commits
  $ echo change1 > file
  $ hg create-phantom-commit --message "multiple - change1"
  in-progress
  revision * (glob)
  $ echo change2 > file
  $ hg create-phantom-commit --message "multiple - change2"
  in-progress
  revision * (glob)
  $ touch newfile
  $ hg create-phantom-commit --message "multiple - newfile"
  in-progress
  revision * (glob)
  $ echo content > newfile
  $ hg create-phantom-commit --message "multiple - content"
  in-progress
  revision * (glob)

There are now multiple phantom commits all based off the wdir p1 "."
  $ hg debug::phantom-commits
  #1 28b5ad17156b 1970-01-01T00:00:00+0000 test
  #2 d9423e8604a2 1970-01-01T00:00:00+0000 test
  #3 bb1b3a9abbe5 1970-01-01T00:00:00+0000 test
  #4 a6415ff88ec5 1970-01-01T00:00:00+0000 test
  $ hg log --graph -T '{node|short} by {user}: {desc}' -r '. + desc("multiple -")'
  o  a6415ff88ec5 by test: multiple - content
  |
  | o  bb1b3a9abbe5 by test: multiple - newfile
  |/
  | o  d9423e8604a2 by test: multiple - change2
  |/
  | o  28b5ad17156b by test: multiple - change1
  |/
  @  28ce161e4d81 by test: C
  |
  ~

  $ reset_changes

Test --allow-empty
------------------

No previous phantom commit
  $ hg create-phantom-commit --message "empty" --allow-empty
  in-progress
  revision * (glob)
  $ hg status --change phantom
  $ reset_changes

With a previous phantom commit
  $ echo change > file
  $ hg create-phantom-commit --message "change"
  in-progress
  revision * (glob)
  $ hg create-phantom-commit --message "empty" --allow-empty
  in-progress
  revision * (glob)
  $ hg status --from $(hg log -r phantom -T '{get(extras, "phantom_prev")}') --to phantom
  $ reset_changes

Test --show-previous
--------------------

  $ hg log -r . -T "{node}\n"
  28ce161e4d81454f9b73b7dcd68092b5ae69c6bf

  $ hg create-phantom-commit --message "test" --show-previous
  previous none 28ce161e4d81454f9b73b7dcd68092b5ae69c6bf
  no-changes

  $ echo change1 > file
  $ hg create-phantom-commit --message "test" --show-previous
  previous none 28ce161e4d81454f9b73b7dcd68092b5ae69c6bf
  in-progress
  revision 5f4d87303616900eeaaa9ed73322d4181ecb42b5

  $ echo change2 > file
  $ hg create-phantom-commit --message "test" --show-previous
  previous phantom 5f4d87303616900eeaaa9ed73322d4181ecb42b5
  in-progress
  revision bcc7b017519a71d0ac1ac11d8858ea75dafaf6dc

  $ reset_changes

Test --set-bookmark
-------------------

With no changes, it sets the bookmark to the wdir parent
  $ hg create-phantom-commit --message "test" --set-bookmark mark
  no-changes
  $ hg log -r mark -T "{node}\n"
  28ce161e4d81454f9b73b7dcd68092b5ae69c6bf

With changes, it sets the bookmark to the new phantom commit
  $ echo change1 > file
  $ hg create-phantom-commit --message "test" --set-bookmark mark
  in-progress
  revision 5f4d87303616900eeaaa9ed73322d4181ecb42b5
  $ hg log -r mark -T "{node}\n"
  5f4d87303616900eeaaa9ed73322d4181ecb42b5

With no changes again, it sets the bookmark to the previous phantom commit
  $ hg bookmark --delete mark
  $ hg create-phantom-commit --message "test" --set-bookmark mark
  no-changes
  $ hg log -r mark -T "{node}\n"
  5f4d87303616900eeaaa9ed73322d4181ecb42b5

It works with --allow-empty
  $ hg create-phantom-commit --message "empty" --allow-empty --set-bookmark mark
  in-progress
  revision 144d8a3d65a04af95850f74b9adabceb7da8191e
  $ hg log -r mark -T "{node}\n"
  144d8a3d65a04af95850f74b9adabceb7da8191e

It moves an existing bookmark
  $ echo change2 > file
  $ hg create-phantom-commit --message "test" --set-bookmark mark
  in-progress
  revision b393be1f67e6ec9332ec641d4b362a3f2b09eaf9
  $ hg log -r mark -T "{node}\n"
  b393be1f67e6ec9332ec641d4b362a3f2b09eaf9

It does not activate the bookmark
  $ hg bookmarks
   * b1                        4:28ce161e4d81
     mark                      43:b393be1f67e6
     phantom                   43:b393be1f67e6
  $ hg bookmark --delete mark
  $ reset_changes

It rejects an invalid bookmark name
  $ hg create-phantom-commit --message "test" --set-bookmark 'tip'
  abort: the name 'tip' is reserved
  [10]

It rejects the phantom bookmark
  $ hg create-phantom-commit --message "test" --set-bookmark phantom
  abort: --set-bookmark cannot be the phantom bookmark 'phantom'
  [10]

Test metadata
-------------

Without --metadata, there is no phantom_metadata extra
  $ echo change > file
  $ hg create-phantom-commit --message "modify"
  in-progress
  revision * (glob)
  $ hg log -r phantom -T '{extras|json}\n'
  {"branch": "default", "phantom_prev": "0000000000000000000000000000000000000000"}
  $ reset_changes

With --metadata, it stores a phantom_metadata extra
  $ echo change > file
  $ hg create-phantom-commit --message "modify" --metadata '{"version": "v1", "sessions": [{"source": "foo", "session_id": "0", "first_message_id": "1", "last_message_id": "2"}]}'
  in-progress
  revision * (glob)
  $ hg log -r phantom -T '{extras|json}\n'
  {"branch": "default", "phantom_metadata": "{\"version\":\"v1\",\"sessions\":[{\"source\":\"foo\",\"session_id\":\"0\",\"first_message_id\":\"1\",\"last_message_id\":\"2\"}]}", "phantom_prev": "0000000000000000000000000000000000000000"}
  $ reset_changes

It allows unknown fields
  $ echo change > file
  $ hg create-phantom-commit --message "modify" --metadata '{"version": "v1", "sessions": [{"source": "foo"}], "new_field": 42}'
  in-progress
  revision * (glob)
  $ hg log -r phantom -T '{extras|json}\n'
  {"branch": "default", "phantom_metadata": "{\"version\":\"v1\",\"sessions\":[{\"source\":\"foo\"}],\"new_field\":42}", "phantom_prev": "0000000000000000000000000000000000000000"}
  $ reset_changes

It rejects invalid JSON
  $ hg create-phantom-commit --message "modify" --metadata '{'
  abort: invalid --metadata value: invalid JSON
  [10]

It rejects JSON without a version
  $ hg create-phantom-commit --message "modify" --metadata '{}'
  abort: invalid --metadata value: $: missing version
  [10]

It rejects JSON with an unknown version
  $ hg create-phantom-commit --message "modify" --metadata '{"version": "v0"}'
  abort: invalid --metadata value: unknown version 'v0'
  [10]

It rejects JSON that doesn't match the schema
  $ hg create-phantom-commit --message "modify" --metadata '{"version": "v1", "sessions": [1]}'
  abort: invalid --metadata value: $.sessions[0]: expected dict, got int
  [10]

Test tracing
------------

Trace events with no changes
  $ hg create-phantom-commit --message "test" --config phantom_commits.tracing=true
  trace-start wlock
  trace-end wlock
  trace-start load
  trace-end load
  trace-start status
  trace-end status
  no-changes

Trace events with changes
  $ echo change > file
  $ hg create-phantom-commit --message "test" --config phantom_commits.tracing=true
  trace-start wlock
  trace-end wlock
  trace-start load
  trace-end load
  trace-start status
  trace-end status
  trace-start lock
  trace-end lock
  trace-start read
  trace-end read
  in-progress
  trace-start commit
  trace-end commit
  revision * (glob)
  $ reset_changes

Test racing with another process
--------------------------------

This section tests what happens when another process creates a phantom commit
in between us reading the repo state and acquiring the wlock.

Spin up a create-phantom-commit that waits just before taking the wlock
  $ sync=$TESTTMP/pre-wlock
  $ hg create-phantom-commit --message "ours" \
  > --config devel.sync.phantom-commits.pre-wlock-file=$sync \
  > > $TESTTMP/ours.out 2>&1 &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $sync.waiting

Let another process create a phantom commit, then make our own change
  $ echo racer > file
  $ hg create-phantom-commit --message "racer"
  in-progress
  revision e2645a8937a9b7a795f2d4b6c451f967b6e19101
  $ touch other

Unblock the first process and wait for it to finish
  $ touch $sync
  $ wait
  $ cat $TESTTMP/ours.out
  in-progress
  revision * (glob)

We observe the bookmark's value as of acquiring the wlock, so we record the
correct phantom_prev and don't lose the first phantom commit.
  $ hg log -r phantom -T 'phantom_prev={get(extras, "phantom_prev")}\n'
  phantom_prev=e2645a8937a9b7a795f2d4b6c451f967b6e19101
  $ hg debug::phantom-commits
  #1 * 1970-01-01T00:00:00+0000 test (glob)
  #2 * 1970-01-01T00:00:00+0000 test (glob)
  $ rm $sync $sync.waiting

  $ reset_changes
