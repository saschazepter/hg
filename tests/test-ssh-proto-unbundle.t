persistent-nodemap is not enabled by default. It is not relevant for this test so disable it.

  $ cat << EOF >> $HGRCPATH
  > [format]
  > use-persistent-nodemap = no
  > EOF

  $ debugwireproto() {
  >   commands=`cat -`
  >   echo 'testing ssh1'
  >   tip=`hg log -r tip -T '{node}'`
  >   echo "${commands}" | hg --verbose debugwireproto --localssh --noreadstderr
  >   if [ -n "$1" ]; then
  >       hg --config extensions.strip= strip --no-backup -r "all() - ::${tip}"
  >   fi
  > }

Generate some bundle files

  $ hg init repo
  $ cd repo
  $ echo 0 > foo
  $ hg -q commit -A -m initial
  $ hg bundle --all -t none-v1 ../initial.v1.hg
  1 changesets found
  $ cd ..

Test pushing bundle1 payload to a server with bundle1 disabled

  $ hg init no-bundle1
  $ cd no-bundle1
  $ cat > .hg/hgrc << EOF
  > [server]
  > bundle1 = false
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 115:
  e>     abort: incompatible Mercurial client; bundle2 required\n
  e>     (see https://www.mercurial-scm.org/wiki/IncompatibleClient)\n

  $ cd ..

Create a pretxnchangegroup hook that fails. Give it multiple modes of printing
output so we can test I/O capture and behavior.

Test pushing to a server that has a pretxnchangegroup Python hook that fails

  $ cat > $TESTTMP/failhook << EOF
  > from __future__ import print_function
  > import sys
  > def hook1line(ui, repo, **kwargs):
  >     ui.write(b'ui.write 1 line\n')
  >     ui.flush()
  >     return 1
  > def hook2lines(ui, repo, **kwargs):
  >     ui.write(b'ui.write 2 lines 1\n')
  >     ui.write(b'ui.write 2 lines 2\n')
  >     ui.flush()
  >     return 1
  > def hook1lineflush(ui, repo, **kwargs):
  >     ui.write(b'ui.write 1 line flush\n')
  >     ui.flush()
  >     return 1
  > def hookmultiflush(ui, repo, **kwargs):
  >     ui.write(b'ui.write 1st\n')
  >     ui.flush()
  >     ui.write(b'ui.write 2nd\n')
  >     ui.flush()
  >     return 1
  > def hookwriteandwriteerr(ui, repo, **kwargs):
  >     ui.write(b'ui.write 1\n')
  >     ui.write_err(b'ui.write_err 1\n')
  >     ui.write(b'ui.write 2\n')
  >     ui.write_err(b'ui.write_err 2\n')
  >     ui.flush()
  >     return 1
  > def hookprintstdout(ui, repo, **kwargs):
  >     print('printed line')
  >     sys.stdout.flush()
  >     return 1
  > def hookprintandwrite(ui, repo, **kwargs):
  >     print('print 1')
  >     sys.stdout.flush()
  >     ui.write(b'ui.write 1\n')
  >     ui.flush()
  >     print('print 2')
  >     sys.stdout.flush()
  >     ui.write(b'ui.write 2\n')
  >     ui.flush()
  >     return 1
  > def hookprintstderrandstdout(ui, repo, **kwargs):
  >     print('stdout 1')
  >     sys.stdout.flush()
  >     print('stderr 1', file=sys.stderr)
  >     sys.stderr.flush()
  >     print('stdout 2')
  >     sys.stdout.flush()
  >     print('stderr 2', file=sys.stderr)
  >     sys.stderr.flush()
  >     return 1
  > EOF

  $ hg init failrepo
  $ cd failrepo

ui.write() in hook is redirected to stderr

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hook1line
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 151:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     ui.write 1 line\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

And a variation that writes multiple lines using ui.write

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hook2lines
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline\(\) -> \d+: (re)
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 173:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     ui.write 2 lines 1\n
  e>     ui.write 2 lines 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

And a variation that does a ui.flush() after writing output

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hook1lineflush
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 157:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     ui.write 1 line flush\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

Multiple writes + flush

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hookmultiflush
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 161:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     ui.write 1st\n
  e>     ui.write 2nd\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

ui.write() + ui.write_err() output is captured

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hookwriteandwriteerr
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 187:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     ui.write 1\n
  e>     ui.write_err 1\n
  e>     ui.write 2\n
  e>     ui.write_err 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n


print() output is captured

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hookprintstdout
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 148:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     printed line\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

Mixed print() and ui.write() are both captured

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hookprintandwrite
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 173:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     print 1\n
  e>     ui.write 1\n
  e>     print 2\n
  e>     ui.write 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

print() to stdout and stderr both get captured

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = python:$TESTTMP/failhook:hookprintstderrandstdout
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 171:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     stdout 1\n
  e>     stderr 1\n
  e>     stdout 2\n
  e>     stderr 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook failed\n

Shell hook writing to stdout has output captured

  $ cat > $TESTTMP/hook.sh << EOF
  > echo 'stdout 1'
  > echo 'stdout 2'
  > exit 1
  > EOF

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.fail = sh $TESTTMP/hook.sh
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 167:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     stdout 1\n
  e>     stdout 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook exited with status 1\n
Shell hook writing to stderr has output captured

  $ cat > $TESTTMP/hook.sh << EOF
  > echo 'stderr 1' 1>&2
  > echo 'stderr 2' 1>&2
  > exit 1
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 167:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     stderr 1\n
  e>     stderr 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook exited with status 1\n
Shell hook writing to stdout and stderr has output captured

  $ cat > $TESTTMP/hook.sh << EOF
  > echo 'stdout 1'
  > echo 'stderr 1' 1>&2
  > echo 'stdout 2'
  > echo 'stderr 2' 1>&2
  > exit 1
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 185:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     stdout 1\n
  e>     stderr 1\n
  e>     stdout 2\n
  e>     stderr 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.fail hook exited with status 1\n
Shell and Python hooks writing to stdout and stderr have output captured

  $ cat > $TESTTMP/hook.sh << EOF
  > echo 'shell stdout 1'
  > echo 'shell stderr 1' 1>&2
  > echo 'shell stdout 2'
  > echo 'shell stderr 2' 1>&2
  > exit 0
  > EOF

  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.a = sh $TESTTMP/hook.sh
  > pretxnchangegroup.b = python:$TESTTMP/failhook:hookprintstderrandstdout
  > EOF

  $ debugwireproto << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 0
  result: 0
  remote output: 
  e> read(-1) -> 228:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     shell stdout 1\n
  e>     shell stderr 1\n
  e>     shell stdout 2\n
  e>     shell stderr 2\n
  e>     stdout 1\n
  e>     stderr 1\n
  e>     stdout 2\n
  e>     stderr 2\n
  e>     transaction abort!\n
  e>     rollback completed\n
  e>     abort: pretxnchangegroup.b hook failed\n
  $ cd ..

Pushing a bundle1 with no output

  $ hg init simplerepo
  $ cd simplerepo

  $ debugwireproto 1 << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 1
  result: 1
  remote output: 
  e> read(-1) -> 100:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     added 1 changesets with 1 changes to 1 files\n
  $ cd ..

Pushing a bundle1 with ui.write() and ui.write_err()

  $ cat > $TESTTMP/hook << EOF
  > def hookuiwrite(ui, repo, **kwargs):
  >     ui.write(b'ui.write 1\n')
  >     ui.write_err(b'ui.write_err 1\n')
  >     ui.write(b'ui.write 2\n')
  >     ui.write_err(b'ui.write_err 2\n')
  > EOF

  $ hg init uiwriterepo
  $ cd uiwriterepo
  $ cat > .hg/hgrc << EOF
  > [hooks]
  > pretxnchangegroup.hook = python:$TESTTMP/hook:hookuiwrite
  > EOF

  $ debugwireproto 1 << EOF
  > command unbundle
  > # This is "force" in hex.
  >     heads 666f726365
  >     PUSHFILE ../initial.v1.hg
  > readavailable
  > EOF
  testing ssh1
  creating ssh peer from handshake results
  i> write(104) -> 104:
  i>     hello\n
  i>     between\n
  i>     pairs 81\n
  i>     0000000000000000000000000000000000000000-0000000000000000000000000000000000000000
  i> flush() -> None
  o> readline() -> 4:
  o>     \d+\\n (re)
  o> readline\(\) -> \d+: (re)
  o>     capabilities: batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash\\n (re)
  o> readline() -> 2:
  o>     1\n
  o> readline() -> 1:
  o>     \n
  sending unbundle command
  i> write(9) -> 9:
  i>     unbundle\n
  i> write(9) -> 9:
  i>     heads 10\n
  i> write(10) -> 10: 666f726365
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  i> write(4) -> 4:
  i>     426\n
  i> write(426) -> 426:
  i>     HG10UN\x00\x00\x00\x9eh\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>cba485ca3678256e044428f70f58291196f6e9de\n
  i>     test\n
  i>     0 0\n
  i>     foo\n
  i>     \n
  i>     initial\x00\x00\x00\x00\x00\x00\x00\x8d\xcb\xa4\x85\xca6x%n\x04D(\xf7\x0fX)\x11\x96\xf6\xe9\xde\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00362fef284ce2ca02aecc8de6d5e8a1c3af0556fe\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00b6/\xef(L\xe2\xca\x02\xae\xcc\x8d\xe6\xd5\xe8\xa1\xc3\xaf\x05V\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00h\x98b\x13\xbdD\x85\xeaQS55\xe3\xfc\x9ex\x00zq\x1f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x020\n
  i>     \x00\x00\x00\x00\x00\x00\x00\x00
  i> write(2) -> 2:
  i>     0\n
  i> flush() -> None
  o> readline() -> 2:
  o>     0\n
  o> readline() -> 2:
  o>     1\n
  o> read(1) -> 1: 1
  result: 1
  remote output: 
  e> read(-1) -> 152:
  e>     adding changesets\n
  e>     adding manifests\n
  e>     adding file changes\n
  e>     ui.write 1\n
  e>     ui.write_err 1\n
  e>     ui.write 2\n
  e>     ui.write_err 2\n
  e>     added 1 changesets with 1 changes to 1 files\n
