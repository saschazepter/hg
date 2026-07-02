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
  $ base=$(hg log -r . -T '{rev}')
  $ reset_to_base() {
  >   hg update --clean "$base" --quiet
  >   hg purge --no-confirm --all
  >   hg bookmark b1 --force --quiet
  >   hg bookmark --delete phantom 2>/dev/null || true
  > }

Helper to show all changeset(s) created, in the order they were committed
  $ show_commits() {
  >   hg export -r "$base::. - $base" --git -T '({index+1}) {node|short} by {user}: {desc}\n{indent(diff, "    ")}'
  > }

Test debug commands
-------------------

Set up some phantom commits
  $ echo change1 > file
  $ hg create-phantom-commit -q --message change
  $ echo change2 > file
  $ hg create-phantom-commit -q --ai --message change

List them
  $ hg debug::phantom-commits
  #1 61d86751d0c1 1970-01-01T00:00:00+0000 test
  #2 a41111038be4 1970-01-01T00:00:00+0000 ai
  $ hg debug::phantom-commits -r phantom
  #1 61d86751d0c1 1970-01-01T00:00:00+0000 test
  #2 a41111038be4 1970-01-01T00:00:00+0000 ai

Make a squashed AI commit
  $ hg commit -qm test

The bookmark is gone
  $ hg debug::phantom-commits

But we can still give the rev explicitly
  $ hg debug::phantom-commits -r a41111038be4
  #1 61d86751d0c1 1970-01-01T00:00:00+0000 test
  #2 a41111038be4 1970-01-01T00:00:00+0000 ai

Or make it look up the phantom_tip extra on the squashed AI commit
  $ hg debug::phantom-commits --for .
  #1 61d86751d0c1 1970-01-01T00:00:00+0000 test
  #2 a41111038be4 1970-01-01T00:00:00+0000 ai

We can also bundle them
  $ hg debug::phantom-commits --for . --bundle $TESTTMP/phantom.hg
  2 changesets found
  $ hg debugbundle $TESTTMP/phantom.hg
  Stream params: {}
  changegroup -- {nbchanges: 2, version: 03} (mandatory: True)
      61d86751d0c14595c2ff3b052d353de73551839a
      a41111038be461bc92f25bac7d507772e157f420
  $ rm $TESTTMP/phantom.hg

Both flags abort if the changeset is not what they expect
  $ hg debug::phantom-commits --for "$base"
  abort: * is not an AI change (no phantom_tip) (glob)
  [255]
  $ hg debug::phantom-commits -r "$base"
  abort: * has no phantom_prev in commit extras (glob)
  [255]

  $ reset_to_base

Test changeset information
--------------------------

This section tests that the two changesets produced by an augmented commit have
the expected information (message, date, etc).

Make an AI change
  $ echo ai > file
  $ hg create-phantom-commit -q --ai --message change

Make a human change
  $ touch human-file

Commit with a specific message, date, and extras
  $ message=$(printf "first line\nsecond line")
  $ hg commit -qAm "$message" --date "2000-01-01T01:02:03+00:00" --config extensions.commitextras= --extra extra-key=extra-value

AI commit message appends " (AI)" to the first line
  $ hg log -r '.^ + .' -T '{user}:\n{indent(desc, "    ")}\n'
  ai:
      first line (AI)
      second line
  test:
      first line
      second line

AI commit uses the provided date
  $ hg log -r '.^ + .' -T '{user}: {date|rfc3339date}\n'
  ai: 2000-01-01T01:02:03+00:00
  test: 2000-01-01T01:02:03+00:00

AI commit uses the same extras, and also stores "phantom_tip"
  $ hg log -r '.^ + .' -T '{user}: {extras|json}\n'
  ai: {"branch": "default", "extra-key": "extra-value", "phantom_tip": "bf7eeca656d283594f6864c2895e63fb8f0aaad5"}
  test: {"branch": "default", "extra-key": "extra-value"}

AI and human commits have the expected list of touched files
  $ hg log -r '.^ + .' -T '{user}: {files}\n'
  ai: file
  test: human-file

  $ reset_to_base

Test metadata
-------------

This section tests that `hg commit` aggregates metadata from the phantom commits
to produce metadata for the squashed AI commit.

Make phantom commits with different metadata
  $ echo change1 > file
  $ hg create-phantom-commit -q --ai --message change --metadata '{"version": "v1", "sessions": [{"source": "foo", "session_id": "0", "first_message_id": "1", "last_message_id": "1"}]}'
  $ echo change2 > file
  $ hg create-phantom-commit -q --ai --message change --metadata '{"version": "v1", "sessions": [{"source": "bar"}]}'
  $ touch untracked
  $ hg create-phantom-commit -q --ai --message change --metadata '{"version": "v1", "sessions": [{"source": "bar", "session_id": "x"}]}'
  $ echo change4 > file
  $ hg create-phantom-commit -q --ai --message change --metadata '{"version": "v1", "sessions": [{"source": "foo", "session_id": "0", "first_message_id": "2", "last_message_id": "4"}]}'

Commit the changes
  $ hg commit -qm "change"

The squashed AI commit and the new phantom commit both have phantom_metadata
aggregated from all the old phantom commits. (It would be nice to aggregate
only the metadata from phantom commits that touched the relevant files, but
that would require doing a lot of statuses so probably isn't worth it.)
  $ hg log -r . -T '{get(extras,"phantom_metadata")}\n'
  {"version":"v1","sessions":[{"source":"foo","session_id":"0","first_message_id":"1","last_message_id":"4"},{"source":"bar","session_id":"x"},{"source":"bar"}]}
  $ hg log -r phantom -T '{get(extras,"phantom_metadata")}\n'
  {"version":"v1","sessions":[{"source":"foo","session_id":"0","first_message_id":"1","last_message_id":"4"},{"source":"bar","session_id":"x"},{"source":"bar"}]}

  $ reset_to_base

Test alternative configs
------------------------

This section tests alternative ways of setting configs.

Use template placeholders in configs
  $ cp $HGRCPATH $TESTTMP/hgrc.bak
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > bookmark={bookmark}/phantom
  > ai-user=ai-{user}
  > EOF

Make changes with inferred users and with explict --user
  $ echo change1 > file
  $ hg create-phantom-commit -q --message change
  $ echo change2 >> file
  $ hg create-phantom-commit -q --ai --message change
  $ echo change3 >> file
  $ hg create-phantom-commit -q --user someone-else --message change
  $ echo change4 >> file
  $ hg create-phantom-commit -q --user "ai-$HGUSER" --message change

It's using the correct bookmark
  $ hg log -r b1/phantom -T '{user}: {node}\n'
  ai-test: 09a262137a45b1640677b89d7071f6c2fc1ca791

It squashes AI changes from the phantom commit with `--ai`, and from the phantom
commit with `--user "ai-$HGUSER"` which is the same username
  $ hg commit -qm "change"
  $ show_commits
  (1) 4614a9335630 by ai-test: change (AI)
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,3 @@
       C
      +change2
      +change4
  (2) a920f9be8e3f by test: change
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,3 +1,4 @@
      -C
      +change1
       change2
      +change3
       change4
  $ reset_to_base

  $ mv $TESTTMP/hgrc.bak $HGRCPATH
