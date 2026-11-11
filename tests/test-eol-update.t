Test EOL update

  $ cat >> $HGRCPATH <<EOF
  > [diff]
  > git = 1
  > EOF

  $ seteol () {
  >     if [ $1 = "LF" ]; then
  >         EOL='\n'
  >     else
  >         EOL='\r\n'
  >     fi
  > }

  $ makerepo () {
  >     echo
  >     echo "# ==== setup repository ===="
  >     echo '% hg init'
  >     hg init repo
  >     cd repo
  > 
  >     cat > .hgeol <<EOF
  > [patterns]
  > **.txt = LF
  > EOF
  > 
  >     printf "first\nsecond\nthird\n" > a.txt
  >     printf "f\r\n" > f
  >     hg commit --addremove -m 'LF commit'
  > 
  >     cat > .hgeol <<EOF
  > [patterns]
  > **.txt = CRLF
  > f = LF
  > EOF
  > 
  >     printf "first\r\nsecond\r\nthird\r\n" > a.txt
  >     printf "f\n" > f
  >     hg commit -m 'CRLF commit'
  > 
  >     cd ..
  > }

  $ dotest () {
  >     seteol $1
  > 
  >     echo
  >     echo "% hg clone repo repo-$1"
  >     hg clone --noupdate repo repo-$1
  >     cd repo-$1
  > 
  >     cat > .hg/hgrc <<EOF
  > [extensions]
  > eol =
  > EOF
  > 
  >     hg update
  > 
  >     echo '% a.txt (before)'
  >     cat a.txt
  > 
  >     printf "first${EOL}third${EOL}" > a.txt
  > 
  >     echo '% a.txt (after)'
  >     cat a.txt
  >     echo '% hg diff'
  >     hg diff
  > 
  >     echo '% hg update 0'
  >     hg update 0
  > 
  >     echo '% a.txt'
  >     cat a.txt
  >     echo '% hg diff'
  >     hg diff
  > 
  > 
  >     cd ..
  >     rm -r repo-$1
  > }

  $ makerepo
  
  # ==== setup repository ====
  % hg init
  adding .hgeol
  adding a.txt
  adding f
  $ dotest LF
  
  % hg clone repo repo-LF
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  % a.txt (before)
  first\r (esc)
  second\r (esc)
  third\r (esc)
  % a.txt (after)
  first
  third
  % hg diff
  diff --git a/a.txt b/a.txt
  --- a/a.txt
  +++ b/a.txt
  @@ -1,3 +1,2 @@
   first\r (esc)
  -second\r (esc)
   third\r (esc)
  % hg update 0
  merging a.txt
  2 files updated, 1 files merged, 0 files removed, 0 files unresolved
  % a.txt
  first
  third
  % hg diff
  diff --git a/a.txt b/a.txt
  --- a/a.txt
  +++ b/a.txt
  @@ -1,3 +1,2 @@
   first
  -second
   third
  $ dotest CRLF
  
  % hg clone repo repo-CRLF
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  % a.txt (before)
  first\r (esc)
  second\r (esc)
  third\r (esc)
  % a.txt (after)
  first\r (esc)
  third\r (esc)
  % hg diff
  diff --git a/a.txt b/a.txt
  --- a/a.txt
  +++ b/a.txt
  @@ -1,3 +1,2 @@
   first\r (esc)
  -second\r (esc)
   third\r (esc)
  % hg update 0
  merging a.txt
  2 files updated, 1 files merged, 0 files removed, 0 files unresolved
  % a.txt
  first
  third
  % hg diff
  diff --git a/a.txt b/a.txt
  --- a/a.txt
  +++ b/a.txt
  @@ -1,3 +1,2 @@
   first
  -second
   third

Test in repo using eol extension, while keeping an eye on how filters are
applied:

  $ cd repo

  $ hg up -q -c -r null
  $ cat > .hg/hgrc <<EOF
  > [extensions]
  > eol =
  > EOF

Update to revision 0 which has no .hgeol, shouldn't use any filters, and
obviously should leave things as tidy as they were before the clean update.

  $ hg up -c -r 0 -v --debug
  resolving manifests
   branchmerge: False, force: False, partial: False
   ancestor: 000000000000, local: 000000000000+, remote: 15cbdf8ca3db
  calling hook preupdate.eol: hgext.eol.preupdate
   .hgeol: remote created -> g
  getting .hgeol
  filtering .hgeol through isbinary
   a.txt: remote created -> g
  getting a.txt
  filtering a.txt through tolf
   f: remote created -> g
  getting f
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg st

  $ hg branch b
  marked working directory as branch b
  (branches are permanent and global, did you want a bookmark?)
  $ hg ci -m b

Merge changes that apply a filter to f:

  $ hg merge 1
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg st
  M .hgeol
  M a.txt
  M f
  $ hg diff
  diff --git a/.hgeol b/.hgeol
  --- a/.hgeol
  +++ b/.hgeol
  @@ -1,2 +1,3 @@
   [patterns]
  -**.txt = LF
  +**.txt = CRLF
  +f = LF
  diff --git a/a.txt b/a.txt
  --- a/a.txt
  +++ b/a.txt
  @@ -1,3 +1,3 @@
  -first
  -second
  -third
  +first\r (esc)
  +second\r (esc)
  +third\r (esc)
  diff --git a/f b/f
  --- a/f
  +++ b/f
  @@ -1,1 +1,1 @@
  -f\r (esc)
  +f

Abort the merge with up -C to revision 0.
Note that files are filtered correctly for revision 0: f is not filtered, a.txt
is filtered with tolf, and everything is left tidy.

  $ touch .hgeol *  # ensure consistent dirtyness checks ignoring dirstate
  $ hg up -C -r 0 -v --debug
  eol: detected change in .hgeol
  resolving manifests
   branchmerge: False, force: True, partial: False
   ancestor: 1db78bdd3bd6+, local: 1db78bdd3bd6+, remote: 15cbdf8ca3db
  calling hook preupdate.eol: hgext.eol.preupdate
   .hgeol: remote is newer -> g
  getting .hgeol
  filtering .hgeol through isbinary
   a.txt: remote is newer -> g
  getting a.txt
  filtering a.txt through tolf
   f: remote is newer -> g
  getting f
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ touch .hgeol *
  $ hg st --debug
  eol: detected change in .hgeol
  filtering .hgeol through isbinary
  filtering a.txt through tolf
  skip updating dirstate: identity mismatch (?)
  $ hg diff

Things were clean, and updating again will not change anything:

  $ touch .hgeol *
  $ hg up -C -r 0 -v --debug
  eol: detected change in .hgeol
  filtering .hgeol through isbinary
  filtering a.txt through tolf
  resolving manifests
   branchmerge: False, force: True, partial: False
   ancestor: 15cbdf8ca3db+, local: 15cbdf8ca3db+, remote: 15cbdf8ca3db
  calling hook preupdate.eol: hgext.eol.preupdate
  starting 4 threads for background file closing (?)
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ touch .hgeol *
  $ hg st --debug
  eol: detected change in .hgeol
  filtering .hgeol through isbinary
  filtering a.txt through tolf
  skip updating dirstate: identity mismatch (?)

  $ cd ..

  $ rm -r repo

Updating several times in one process
=====================================

The extension configures the filters from the .hgeol of each update. A rebase
updates the working copy once per rebased revision, within the same process.
Each of these updates must use the filters configured for it.

Rebasing across a change of .hgeol
----------------------------------

The first rebased revision switches the .txt files from LF to CRLF, the second
one modifies such a file. They are committed without the extension, to control
the stored line endings.

  $ hg init rebase-repo
  $ cd rebase-repo
  $ cat > .hgeol <<EOF
  > [patterns]
  > **.txt = LF
  > EOF
  $ printf 'babar\n' > a.txt
  $ hg commit -Aqm 'LF'
  $ echo celeste > other
  $ hg commit -Aqm 'destination'
  $ hg update -q 0
  $ cat > .hgeol <<EOF
  > [patterns]
  > **.txt = CRLF
  > EOF
  $ hg commit -qm 'switch to CRLF'
  $ printf 'babar\r\nceleste\r\n' > a.txt
  $ hg commit -qm 'modify a.txt'

  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > eol =
  > rebase =
  > EOF
  $ hg update -q 1

  $ hg rebase -s 2 -d 1
  rebasing 2:4f6bc3d748d9 "switch to CRLF"
  rebasing 3:dc37a473d1d3 tip "modify a.txt"
  saved backup bundle to $TESTTMP/rebase-repo/.hg/strip-backup/4f6bc3d748d9-16b30702-rebase.hg

The second rebased revision comes after the switch to CRLF, its a.txt is
written and committed with CRLF line endings.

  $ hg cat -r tip a.txt
  babar\r (esc)
  celeste\r (esc)

  $ cd ..
