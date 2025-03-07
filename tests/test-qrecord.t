Create configuration

  $ echo "[ui]" >> $HGRCPATH
  $ echo "interactive=true" >> $HGRCPATH

help record (no record)

  $ hg help record
  record extension - commands to interactively select changes for
  commit/qrefresh (DEPRECATED)
  
  The feature provided by this extension has been moved into core Mercurial as
  'hg commit --interactive'.
  
  (use 'hg help extensions' for information on enabling extensions)

help qrecord (no record)

  $ hg help qrecord
  'qrecord' is provided by the following extension:
  
      record        commands to interactively select changes for commit/qrefresh
                    (DEPRECATED)
  
  (use 'hg help extensions' for information on enabling extensions)

  $ echo "[extensions]"     >> $HGRCPATH
  $ echo "record="          >> $HGRCPATH

help record (record)

  $ hg help record
  hg record [OPTION]... [FILE]...
  
  interactively select changes to commit
  
  If a list of files is omitted, all changes reported by 'hg status' will be
  candidates for recording.
  
  See 'hg help dates' for a list of formats valid for -d/--date.
  
  If using the text interface (see 'hg help config'), you will be prompted for
  whether to record changes to each modified file, and for files with multiple
  changes, for each change to use. For each query, the following responses are
  possible:
  
    y - record this change
    n - skip this change
    e - edit this change manually
  
    s - skip remaining changes to this file
    f - record remaining changes to this file
  
    d - done, skip remaining changes and files
    a - record all changes to all remaining files
    q - quit, recording no changes
  
    ? - display help
  
  This command is not available when committing a merge.
  
  (use 'hg help -e record' to show help for the record extension)
  
  options ([+] can be repeated):
  
   -A --addremove           mark new/missing files as added/removed before
                            committing
      --close-branch        mark a branch head as closed
      --amend               amend the parent of the working directory
   -s --secret              use the secret phase for committing
      --draft               use the draft phase for committing
   -e --edit                invoke editor on commit messages
   -I --include PATTERN [+] include names matching the given patterns
   -X --exclude PATTERN [+] exclude names matching the given patterns
   -m --message TEXT        use text as commit message
   -l --logfile FILE        read commit message from file
   -d --date DATE           record the specified date as commit date
   -u --user USER           record the specified user as committer
   -S --subrepos            recurse into subrepositories
   -w --ignore-all-space    ignore white space when comparing lines
   -b --ignore-space-change ignore changes in the amount of white space
   -B --ignore-blank-lines  ignore changes whose lines are all blank
   -Z --ignore-space-at-eol ignore changes in whitespace at EOL
  
  (some details hidden, use --verbose to show complete help)

help (no mq, so no qrecord)

  $ hg help qrecord
  hg qrecord [OPTION]... PATCH [FILE]...
  
  interactively record a new patch
  
  See 'hg help qnew' & 'hg help record' for more information and usage.
  
  (some details hidden, use --verbose to show complete help)

  $ hg init a

qrecord (mq not present)

  $ hg -R a qrecord
  hg qrecord: invalid arguments
  hg qrecord [OPTION]... PATCH [FILE]...
  
  interactively record a new patch
  
  (use 'hg qrecord -h' to show more help)
  [10]

qrecord patch (mq not present)

  $ hg -R a qrecord patch
  abort: 'mq' extension not loaded
  [255]

help (bad mq)

  $ echo "mq=nonexistent" >> $HGRCPATH
  $ hg help qrecord
  *** failed to import extension "mq" from nonexistent: [Errno *] * (glob)
  hg qrecord [OPTION]... PATCH [FILE]...
  
  interactively record a new patch
  
  See 'hg help qnew' & 'hg help record' for more information and usage.
  
  (some details hidden, use --verbose to show complete help)

help (mq present)

  $ sed 's/mq=nonexistent/mq=/' $HGRCPATH > hgrc.tmp
  $ mv hgrc.tmp $HGRCPATH

  $ hg help qrecord
  hg qrecord [OPTION]... PATCH [FILE]...
  
  interactively record a new patch
  
  See 'hg help qnew' & 'hg help record' for more information and usage.
  
  options ([+] can be repeated):
  
   -e --edit                invoke editor on commit messages
   -g --git                 use git extended diff format
   -U --currentuser         add "From: <current user>" to patch
   -u --user USER           add "From: <USER>" to patch
   -D --currentdate         add "Date: <current date>" to patch
   -d --date DATE           add "Date: <DATE>" to patch
   -I --include PATTERN [+] include names matching the given patterns
   -X --exclude PATTERN [+] exclude names matching the given patterns
   -m --message TEXT        use text as commit message
   -l --logfile FILE        read commit message from file
   -w --ignore-all-space    ignore white space when comparing lines
   -b --ignore-space-change ignore changes in the amount of white space
   -B --ignore-blank-lines  ignore changes whose lines are all blank
   -Z --ignore-space-at-eol ignore changes in whitespace at EOL
      --mq                  operate on patch repository
  
  (some details hidden, use --verbose to show complete help)

  $ cd a

Base commit

  $ cat > 1.txt <<EOF
  > 1
  > 2
  > 3
  > 4
  > 5
  > EOF
  $ cat > 2.txt <<EOF
  > a
  > b
  > c
  > d
  > e
  > f
  > EOF

  $ mkdir dir
  $ cat > dir/a.txt <<EOF
  > hello world
  > 
  > someone
  > up
  > there
  > loves
  > me
  > EOF

  $ hg add 1.txt 2.txt dir/a.txt
  $ hg commit -m 'initial checkin'

Changing files

  $ sed -e 's/2/2 2/;s/4/4 4/' 1.txt > 1.txt.new
  $ sed -e 's/b/b b/' 2.txt > 2.txt.new
  $ sed -e 's/hello world/hello world!/' dir/a.txt > dir/a.txt.new

  $ mv -f 1.txt.new 1.txt
  $ mv -f 2.txt.new 2.txt
  $ mv -f dir/a.txt.new dir/a.txt

Whole diff

  $ hg diff --nodates
  diff -r 1057167b20ef 1.txt
  --- a/1.txt
  +++ b/1.txt
  @@ -1,5 +1,5 @@
   1
  -2
  +2 2
   3
  -4
  +4 4
   5
  diff -r 1057167b20ef 2.txt
  --- a/2.txt
  +++ b/2.txt
  @@ -1,5 +1,5 @@
   a
  -b
  +b b
   c
   d
   e
  diff -r 1057167b20ef dir/a.txt
  --- a/dir/a.txt
  +++ b/dir/a.txt
  @@ -1,4 +1,4 @@
  -hello world
  +hello world!
   
   someone
   up

qrecord with bad patch name, should abort before prompting

  $ hg qrecord .hg
  abort: patch name cannot begin with ".hg"
  [255]
  $ hg qrecord ' foo'
  abort: patch name cannot begin or end with whitespace
  [255]
  $ hg qrecord 'foo '
  abort: patch name cannot begin or end with whitespace
  [255]

qrecord a.patch

  $ hg qrecord -d '0 0' -m aaa a.patch <<EOF
  > y
  > y
  > n
  > y
  > y
  > n
  > EOF
  diff --git a/1.txt b/1.txt
  2 hunks, 2 lines changed
  examine changes to '1.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
   1
  -2
  +2 2
   3
  record change 1/4 to '1.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -3,3 +3,3 @@
   3
  -4
  +4 4
   5
  record change 2/4 to '1.txt'?
  (enter ? for help) [Ynesfdaq?] n
  
  diff --git a/2.txt b/2.txt
  1 hunks, 1 lines changed
  examine changes to '2.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,5 +1,5 @@
   a
  -b
  +b b
   c
   d
   e
  record change 3/4 to '2.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  diff --git a/dir/a.txt b/dir/a.txt
  1 hunks, 1 lines changed
  examine changes to 'dir/a.txt'?
  (enter ? for help) [Ynesfdaq?] n
  

After qrecord a.patch 'tip'"

  $ hg tip -p
  changeset:   1:5d1ca63427ee
  tag:         a.patch
  tag:         qbase
  tag:         qtip
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     aaa
  
  diff -r 1057167b20ef -r 5d1ca63427ee 1.txt
  --- a/1.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/1.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,5 +1,5 @@
   1
  -2
  +2 2
   3
   4
   5
  diff -r 1057167b20ef -r 5d1ca63427ee 2.txt
  --- a/2.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/2.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,5 +1,5 @@
   a
  -b
  +b b
   c
   d
   e
  

After qrecord a.patch 'diff'"

  $ hg diff --nodates
  diff -r 5d1ca63427ee 1.txt
  --- a/1.txt
  +++ b/1.txt
  @@ -1,5 +1,5 @@
   1
   2 2
   3
  -4
  +4 4
   5
  diff -r 5d1ca63427ee dir/a.txt
  --- a/dir/a.txt
  +++ b/dir/a.txt
  @@ -1,4 +1,4 @@
  -hello world
  +hello world!
   
   someone
   up

qrecord b.patch

  $ hg qrecord -d '0 0' -m bbb b.patch <<EOF
  > y
  > y
  > y
  > y
  > EOF
  diff --git a/1.txt b/1.txt
  1 hunks, 1 lines changed
  examine changes to '1.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,5 +1,5 @@
   1
   2 2
   3
  -4
  +4 4
   5
  record change 1/2 to '1.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  diff --git a/dir/a.txt b/dir/a.txt
  1 hunks, 1 lines changed
  examine changes to 'dir/a.txt'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,4 +1,4 @@
  -hello world
  +hello world!
   
   someone
   up
  record change 2/2 to 'dir/a.txt'?
  (enter ? for help) [Ynesfdaq?] y
  

After qrecord b.patch 'tip'

  $ hg tip -p
  changeset:   2:b056198bf878
  tag:         b.patch
  tag:         qtip
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     bbb
  
  diff -r 5d1ca63427ee -r b056198bf878 1.txt
  --- a/1.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/1.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,5 +1,5 @@
   1
   2 2
   3
  -4
  +4 4
   5
  diff -r 5d1ca63427ee -r b056198bf878 dir/a.txt
  --- a/dir/a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/dir/a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,4 +1,4 @@
  -hello world
  +hello world!
   
   someone
   up
  

After qrecord b.patch 'diff'

  $ hg diff --nodates

  $ cd ..

qrecord should throw an error when histedit in process

  $ hg init issue5981
  $ cd issue5981
  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > histedit=
  > mq=
  > EOF
  $ echo > a
  $ hg ci -Am 'foo bar'
  adding a
  $ hg log
  changeset:   0:ea55e2ae468f
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     foo bar
  
  $ hg histedit tip --commands - 2>&1 <<EOF
  > edit ea55e2ae468f foo bar
  > EOF
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  Editing (ea55e2ae468f), commit as needed now to split the change
  (to edit ea55e2ae468f, `hg histedit --continue` after making changes)
  [240]
  $ echo 'foo bar' > a
  $ hg qrecord -d '0 0' -m aaa a.patch <<EOF
  > y
  > y
  > n
  > y
  > y
  > n
  > EOF
  abort: histedit in progress
  (use 'hg histedit --continue' or 'hg histedit --abort')
  [20]
