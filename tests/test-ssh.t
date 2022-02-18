This test tries to exercise the ssh functionality with a dummy script

creating 'remote' repo

  $ hg init remote
  $ cd remote
  $ echo this > foo
  $ echo this > fooO
  $ hg ci -A -m "init" foo fooO

insert a closed branch (issue4428)

  $ hg up null
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg branch closed
  marked working directory as branch closed
  (branches are permanent and global, did you want a bookmark?)
  $ hg ci -mc0
  $ hg ci --close-branch -mc1
  $ hg up -q default

configure for serving

  $ cat <<EOF > .hg/hgrc
  > [server]
  > uncompressed = True
  > 
  > [hooks]
  > changegroup = sh -c "printenv.py --line changegroup-in-remote 0 ../dummylog"
  > EOF
  $ cd $TESTTMP

repo not found error

  $ hg clone ssh://user@dummy/nonexistent local
  remote: abort: repository nonexistent not found
  abort: no suitable response from remote hg
  [255]
  $ hg clone -q ssh://user@dummy/nonexistent local
  remote: abort: repository nonexistent not found
  abort: no suitable response from remote hg
  [255]

non-existent absolute path

  $ hg clone ssh://user@dummy/`pwd`/nonexistent local
  remote: abort: repository $TESTTMP/nonexistent not found
  abort: no suitable response from remote hg
  [255]

clone remote via stream

#if no-reposimplestore

  $ hg clone --stream ssh://user@dummy/remote local-stream
  streaming all changes
  8 files to transfer, 827 bytes of data (no-zstd !)
  transferred 827 bytes in * seconds (*) (glob) (no-zstd !)
  8 files to transfer, 846 bytes of data (zstd !)
  transferred * bytes in * seconds (* */sec) (glob) (zstd !)
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd local-stream
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 2 changes to 2 files
  $ hg branches
  default                        0:1160648e36ce
  $ cd $TESTTMP

clone bookmarks via stream

  $ hg -R local-stream book mybook
  $ hg clone --stream ssh://user@dummy/local-stream stream2
  streaming all changes
  15 files to transfer, * of data (glob)
  transferred * in * seconds (*) (glob)
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd stream2
  $ hg book
     mybook                    0:1160648e36ce
  $ cd $TESTTMP
  $ rm -rf local-stream stream2

#endif

clone remote via pull

  $ hg clone ssh://user@dummy/remote local
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 2 changes to 2 files
  new changesets 1160648e36ce:ad076bfb429d
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

verify

  $ cd local
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 2 changes to 2 files
  $ cat >> .hg/hgrc <<EOF
  > [hooks]
  > changegroup = sh -c "printenv.py changegroup-in-local 0 ../dummylog"
  > EOF

empty default pull

  $ hg paths
  default = ssh://user@dummy/remote
  $ hg pull
  pulling from ssh://user@dummy/remote
  searching for changes
  no changes found

pull from wrong ssh URL

  $ hg pull ssh://user@dummy/doesnotexist
  pulling from ssh://user@dummy/doesnotexist
  remote: abort: repository doesnotexist not found
  abort: no suitable response from remote hg
  [255]

local change

  $ echo bleah > foo
  $ hg ci -m "add"

updating rc

  $ echo "default-push = ssh://user@dummy/remote" >> .hg/hgrc

find outgoing

  $ hg out ssh://user@dummy/remote
  comparing with ssh://user@dummy/remote
  searching for changes
  changeset:   3:a28a9d1a809c
  tag:         tip
  parent:      0:1160648e36ce
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     add
  

find incoming on the remote side

  $ hg incoming -R ../remote ssh://user@dummy/local
  comparing with ssh://user@dummy/local
  searching for changes
  changeset:   3:a28a9d1a809c
  tag:         tip
  parent:      0:1160648e36ce
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     add
  

find incoming on the remote side (using absolute path)

  $ hg incoming -R ../remote "ssh://user@dummy/`pwd`"
  comparing with ssh://user@dummy/$TESTTMP/local
  searching for changes
  changeset:   3:a28a9d1a809c
  tag:         tip
  parent:      0:1160648e36ce
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     add
  

push

  $ hg push
  pushing to ssh://user@dummy/remote
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  $ cd $TESTTMP/remote

check remote tip

  $ hg tip
  changeset:   3:a28a9d1a809c
  tag:         tip
  parent:      0:1160648e36ce
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     add
  
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 3 changes to 2 files
  $ hg cat -r tip foo
  bleah
  $ echo z > z
  $ hg ci -A -m z z
  created new head

test pushkeys and bookmarks

  $ cd $TESTTMP/local
  $ hg debugpushkey ssh://user@dummy/remote namespaces
  bookmarks	
  namespaces	
  phases	
  $ hg book foo -r 0
  $ hg out -B --config paths.default=bogus://invalid --config paths.default:pushurl=`hg paths default`
  comparing with ssh://user@dummy/remote
  searching for changed bookmarks
     foo                       1160648e36ce
  $ hg push -B foo
  pushing to ssh://user@dummy/remote
  searching for changes
  no changes found
  exporting bookmark foo
  [1]
  $ hg debugpushkey ssh://user@dummy/remote bookmarks
  foo	1160648e36cec0054048a7edc4110c6f84fde594
  $ hg book -f foo
  $ hg push --traceback
  pushing to ssh://user@dummy/remote
  searching for changes
  no changes found
  updating bookmark foo
  [1]
  $ hg book -d foo
  $ hg in -B
  comparing with ssh://user@dummy/remote
  searching for changed bookmarks
     foo                       a28a9d1a809c
  $ hg book -f -r 0 foo
  $ hg pull -B foo
  pulling from ssh://user@dummy/remote
  no changes found
  updating bookmark foo
  $ hg book -d foo
  $ hg push -B foo
  pushing to ssh://user@dummy/remote
  searching for changes
  no changes found
  deleting remote bookmark foo
  [1]

a bad, evil hook that prints to stdout

  $ cat <<EOF > $TESTTMP/badhook
  > import sys
  > sys.stdout.write("KABOOM\n")
  > sys.stdout.flush()
  > EOF

  $ cat <<EOF > $TESTTMP/badpyhook.py
  > import sys
  > def hook(ui, repo, hooktype, **kwargs):
  >     sys.stdout.write("KABOOM IN PROCESS\n")
  >     sys.stdout.flush()
  > EOF

  $ cat <<EOF >> ../remote/.hg/hgrc
  > [hooks]
  > changegroup.stdout = "$PYTHON" $TESTTMP/badhook
  > changegroup.pystdout = python:$TESTTMP/badpyhook.py:hook
  > EOF
  $ echo r > r
  $ hg ci -A -m z r

push should succeed even though it has an unexpected response

  $ hg push
  pushing to ssh://user@dummy/remote
  searching for changes
  remote has heads on branch 'default' that are not known locally: 6c0482d977a3
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files (py3 !)
  remote: added 1 changesets with 1 changes to 1 files (no-py3 no-chg !)
  remote: KABOOM
  remote: KABOOM IN PROCESS
  remote: added 1 changesets with 1 changes to 1 files (no-py3 chg !)
  $ hg -R ../remote heads
  changeset:   5:1383141674ec
  tag:         tip
  parent:      3:a28a9d1a809c
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     z
  
  changeset:   4:6c0482d977a3
  parent:      0:1160648e36ce
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     z
  

#if chg

try again with remote chg, which should succeed as well

  $ hg rollback -R ../remote
  repository tip rolled back to revision 4 (undo serve)

  $ hg push --config ui.remotecmd=chg
  pushing to ssh://user@dummy/remote
  searching for changes
  remote has heads on branch 'default' that are not known locally: 6c0482d977a3
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files (py3 !)
  remote: KABOOM
  remote: KABOOM IN PROCESS
  remote: added 1 changesets with 1 changes to 1 files (no-py3 !)

#endif

clone bookmarks

  $ hg -R ../remote bookmark test
  $ hg -R ../remote bookmarks
   * test                      4:6c0482d977a3
  $ hg clone ssh://user@dummy/remote local-bookmarks
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 5 changes to 4 files (+1 heads)
  new changesets 1160648e36ce:1383141674ec
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R local-bookmarks bookmarks
     test                      4:6c0482d977a3

passwords in ssh urls are not supported
(we use a glob here because different Python versions give different
results here)

  $ hg push ssh://user:erroneouspwd@dummy/remote
  pushing to ssh://user:*@dummy/remote (glob)
  abort: password in URL not supported
  [255]

  $ cd $TESTTMP

hide outer repo
  $ hg init

Test remote paths with spaces (issue2983):

  $ hg init "ssh://user@dummy/a repo"
  $ touch "$TESTTMP/a repo/test"
  $ hg -R 'a repo' commit -A -m "test"
  adding test
  $ hg -R 'a repo' tag tag
  $ hg id "ssh://user@dummy/a repo"
  73649e48688a

  $ hg id "ssh://user@dummy/a repo#noNoNO"
  abort: unknown revision 'noNoNO'
  [255]

Test (non-)escaping of remote paths with spaces when cloning (issue3145):

  $ hg clone "ssh://user@dummy/a repo"
  destination directory: a repo
  abort: destination 'a repo' is not empty
  [10]

#if no-rhg
Make sure hg is really paranoid in serve --stdio mode. It used to be
possible to get a debugger REPL by specifying a repo named --debugger.
  $ hg -R --debugger serve --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', '--debugger', 'serve', '--stdio']
  [255]
  $ hg -R --config=ui.debugger=yes serve --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', '--config=ui.debugger=yes', 'serve', '--stdio']
  [255]
Abbreviations of 'serve' also don't work, to avoid shenanigans.
  $ hg -R narf serv --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', 'narf', 'serv', '--stdio']
  [255]
#else
rhg aborts early on -R without a repository at that path
  $ hg -R --debugger serve --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', '--debugger', 'serve', '--stdio'] (missing-correct-output !)
  abort: repository --debugger not found (known-bad-output !)
  [255]
  $ hg -R --config=ui.debugger=yes serve --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', '--config=ui.debugger=yes', 'serve', '--stdio'] (missing-correct-output !)
  abort: repository --config=ui.debugger=yes not found (known-bad-output !)
  [255]
  $ hg -R narf serv --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', 'narf', 'serv', '--stdio'] (missing-correct-output !)
  abort: repository narf not found (known-bad-output !)
  [255]
If the repo does exist, rhg finds an unsupported command and falls back to Python
which still does the right thing
  $ hg init narf
  $ hg -R narf serv --stdio
  abort: potentially unsafe serve --stdio invocation: ['-R', 'narf', 'serv', '--stdio']
  [255]
#endif

Test hg-ssh using a helper script that will restore PYTHONPATH (which might
have been cleared by a hg.exe wrapper) and invoke hg-ssh with the right
parameters:

  $ cat > ssh.sh << EOF
  > userhost="\$1"
  > SSH_ORIGINAL_COMMAND="\$2"
  > export SSH_ORIGINAL_COMMAND
  > PYTHONPATH="$PYTHONPATH"
  > export PYTHONPATH
  > "$PYTHON" "$TESTDIR/../contrib/hg-ssh" "$TESTTMP/a repo"
  > EOF

  $ hg id --ssh "sh ssh.sh" "ssh://user@dummy/a repo"
  73649e48688a

  $ hg id --ssh "sh ssh.sh" "ssh://user@dummy/a'repo"
  remote: Illegal repository "$TESTTMP/a'repo"
  abort: no suitable response from remote hg
  [255]

  $ hg id --ssh "sh ssh.sh" --remotecmd hacking "ssh://user@dummy/a'repo"
  remote: Illegal command "hacking -R 'a'\''repo' serve --stdio"
  abort: no suitable response from remote hg
  [255]

  $ SSH_ORIGINAL_COMMAND="'hg' -R 'a'repo' serve --stdio" "$PYTHON" "$TESTDIR/../contrib/hg-ssh"
  Illegal command "'hg' -R 'a'repo' serve --stdio": No closing quotation
  [255]

Test hg-ssh in read-only mode:

  $ cat > ssh.sh << EOF
  > userhost="\$1"
  > SSH_ORIGINAL_COMMAND="\$2"
  > export SSH_ORIGINAL_COMMAND
  > PYTHONPATH="$PYTHONPATH"
  > export PYTHONPATH
  > "$PYTHON" "$TESTDIR/../contrib/hg-ssh" --read-only "$TESTTMP/remote"
  > EOF

  $ hg clone --ssh "sh ssh.sh" "ssh://user@dummy/$TESTTMP/remote" read-only-local
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 5 changes to 4 files (+1 heads)
  new changesets 1160648e36ce:1383141674ec
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cd read-only-local
  $ echo "baz" > bar
  $ hg ci -A -m "unpushable commit" bar
  $ hg push --ssh "sh ../ssh.sh"
  pushing to ssh://user@dummy/*/remote (glob)
  searching for changes
  remote: Permission denied
  remote: pretxnopen.hg-ssh hook failed
  abort: push failed on remote
  [100]

  $ cd $TESTTMP

stderr from remote commands should be printed before stdout from local code (issue4336)

  $ hg clone remote stderr-ordering
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd stderr-ordering
  $ cat >> localwrite.py << EOF
  > from mercurial import exchange, extensions
  > 
  > def wrappedpush(orig, repo, *args, **kwargs):
  >     res = orig(repo, *args, **kwargs)
  >     repo.ui.write(b'local stdout\n')
  >     repo.ui.flush()
  >     return res
  > 
  > def extsetup(ui):
  >     extensions.wrapfunction(exchange, b'push', wrappedpush)
  > EOF

  $ cat >> .hg/hgrc << EOF
  > [paths]
  > default-push = ssh://user@dummy/remote
  > [extensions]
  > localwrite = localwrite.py
  > EOF

  $ echo localwrite > foo
  $ hg commit -m 'testing localwrite'
  $ hg push
  pushing to ssh://user@dummy/remote
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files (py3 !)
  remote: added 1 changesets with 1 changes to 1 files (no-py3 no-chg !)
  remote: KABOOM
  remote: KABOOM IN PROCESS
  remote: added 1 changesets with 1 changes to 1 files (no-py3 chg !)
  local stdout

debug output

  $ hg pull --debug ssh://user@dummy/remote --config devel.debug.peer-request=yes
  pulling from ssh://user@dummy/remote
  running .* ".*[/\\]dummyssh" ['"]user@dummy['"] ['"]hg -R remote serve --stdio['"] (re)
  devel-peer-request: hello+between
  devel-peer-request:   pairs: 81 bytes
  sending hello command
  sending between command
  remote: \d+ (re)
  remote: capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash (re)
  remote: 1
  devel-peer-request: protocaps
  devel-peer-request:   caps: * bytes (glob)
  sending protocaps command
  query 1; heads
  devel-peer-request: batched-content
  devel-peer-request:    - heads (0 arguments)
  devel-peer-request:    - known (1 arguments)
  devel-peer-request: batch
  devel-peer-request:   cmds: 141 bytes
  sending batch command
  searching for changes
  all remote heads known locally
  no changes found
  devel-peer-request: getbundle
  devel-peer-request:   bookmarks: 1 bytes
  devel-peer-request:   bundlecaps: 270 bytes
  devel-peer-request:   cg: 1 bytes
  devel-peer-request:   common: 122 bytes
  devel-peer-request:   heads: 122 bytes
  devel-peer-request:   listkeys: 9 bytes
  devel-peer-request:   phases: 1 bytes
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "bookmarks" supported
  bundle2-input-part: total payload size 26
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: total payload size 45
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 72
  bundle2-input-bundle: 3 parts total
  checking for updated bookmarks

  $ cd $TESTTMP

  $ cat dummylog
  Got arguments 1:user@dummy 2:hg -R nonexistent serve --stdio
  Got arguments 1:user@dummy 2:hg -R nonexistent serve --stdio
  Got arguments 1:user@dummy 2:hg -R $TESTTMP/nonexistent serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R local-stream serve --stdio (no-reposimplestore !)
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio (no-reposimplestore !)
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio (no-reposimplestore !)
  Got arguments 1:user@dummy 2:hg -R doesnotexist serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R local serve --stdio
  Got arguments 1:user@dummy 2:hg -R $TESTTMP/local serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  changegroup-in-remote hook: HG_BUNDLE2=1
  HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=a28a9d1a809cab7d4e2fde4bee738a9ede948b60
  HG_NODE_LAST=a28a9d1a809cab7d4e2fde4bee738a9ede948b60
  HG_SOURCE=serve
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=serve
  HG_URL=remote:ssh:$LOCALIP
  
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  changegroup-in-remote hook: HG_BUNDLE2=1
  HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=1383141674ec756a6056f6a9097618482fe0f4a6
  HG_NODE_LAST=1383141674ec756a6056f6a9097618482fe0f4a6
  HG_SOURCE=serve
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=serve
  HG_URL=remote:ssh:$LOCALIP
  
  Got arguments 1:user@dummy 2:chg -R remote serve --stdio (chg !)
  changegroup-in-remote hook: HG_BUNDLE2=1 (chg !)
  HG_HOOKNAME=changegroup (chg !)
  HG_HOOKTYPE=changegroup (chg !)
  HG_NODE=1383141674ec756a6056f6a9097618482fe0f4a6 (chg !)
  HG_NODE_LAST=1383141674ec756a6056f6a9097618482fe0f4a6 (chg !)
  HG_SOURCE=serve (chg !)
  HG_TXNID=TXN:$ID$ (chg !)
  HG_TXNNAME=serve (chg !)
  HG_URL=remote:ssh:$LOCALIP (chg !)
   (chg !)
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  Got arguments 1:user@dummy 2:hg init 'a repo'
  Got arguments 1:user@dummy 2:hg -R 'a repo' serve --stdio
  Got arguments 1:user@dummy 2:hg -R 'a repo' serve --stdio
  Got arguments 1:user@dummy 2:hg -R 'a repo' serve --stdio
  Got arguments 1:user@dummy 2:hg -R 'a repo' serve --stdio
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio
  changegroup-in-remote hook: HG_BUNDLE2=1
  HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=65c38f4125f9602c8db4af56530cc221d93b8ef8
  HG_NODE_LAST=65c38f4125f9602c8db4af56530cc221d93b8ef8
  HG_SOURCE=serve
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=serve
  HG_URL=remote:ssh:$LOCALIP
  
  Got arguments 1:user@dummy 2:hg -R remote serve --stdio


remote hook failure is attributed to remote

  $ cat > $TESTTMP/failhook << EOF
  > def hook(ui, repo, **kwargs):
  >     ui.write(b'hook failure!\n')
  >     ui.flush()
  >     return 1
  > EOF

  $ echo "pretxnchangegroup.fail = python:$TESTTMP/failhook:hook" >> remote/.hg/hgrc

  $ hg -q clone ssh://user@dummy/remote hookout
  $ cd hookout
  $ touch hookfailure
  $ hg -q commit -A -m 'remote hook failure'
  $ hg push
  pushing to ssh://user@dummy/remote
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: hook failure!
  remote: transaction abort!
  remote: rollback completed
  remote: pretxnchangegroup.fail hook failed
  abort: push failed on remote
  [100]

abort during pull is properly reported as such

  $ echo morefoo >> ../remote/foo
  $ hg -R ../remote commit --message "more foo to be pulled"
  $ cat >> ../remote/.hg/hgrc << EOF
  > [extensions]
  > crash = ${TESTDIR}/crashgetbundler.py
  > EOF
  $ hg pull
  pulling from ssh://user@dummy/remote
  searching for changes
  remote: abort: this is an exercise
  abort: pull failed on remote
  [100]

abort with no error hint when there is a ssh problem when pulling

  $ hg pull ssh://brokenrepository
  pulling from ssh://brokenrepository/
  abort: no suitable response from remote hg
  [255]

abort with configured error hint when there is a ssh problem when pulling

  $ hg pull ssh://brokenrepository \
  > --config ui.ssherrorhint="Please see http://company/internalwiki/ssh.html"
  pulling from ssh://brokenrepository/
  abort: no suitable response from remote hg
  (Please see http://company/internalwiki/ssh.html)
  [255]

test that custom environment is passed down to ssh executable
  $ cat >>dumpenv <<EOF
  > #! /bin/sh
  > echo \$VAR >&2
  > EOF
  $ chmod +x dumpenv
  $ hg pull ssh://something --config ui.ssh="sh dumpenv"
  pulling from ssh://something/
  remote: 
  abort: no suitable response from remote hg
  [255]
  $ hg pull ssh://something --config ui.ssh="sh dumpenv" --config sshenv.VAR=17
  pulling from ssh://something/
  remote: 17
  abort: no suitable response from remote hg
  [255]

