  $ hg init test
  $ cd test
  $ hg debugbuilddag '+2'
  $ hg phase --public 0

  $ hg serve -p $HGPORT -d --pid-file=hg.pid -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ cd ..
  $ hg init test2
  $ cd test2
  $ hg incoming http://foo:xyzzy@localhost:$HGPORT/ -T '{desc}\n'
  comparing with http://foo:***@localhost:$HGPORT/
  r0
  r1
  $ killdaemons.py

  $ cd ..
  $ hg -R test --config server.view=immutable serve -p $HGPORT -d --pid-file=hg.pid -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ hg -R test2 incoming http://foo:xyzzy@localhost:$HGPORT/ -T '{desc}\n'
  comparing with http://foo:***@localhost:$HGPORT/
  r0

Check same result using `experimental.extra-filter-revs`

  $ hg -R test --config experimental.extra-filter-revs='not public()' serve -p $HGPORT1 -d --pid-file=hg2.pid -E errors.log
  $ cat hg2.pid >> $DAEMON_PIDS
  $ hg -R test2 incoming http://foo:xyzzy@localhost:$HGPORT1/
  comparing with http://foo:***@localhost:$HGPORT1/
  changeset:   0:1ea73414a91b
  tag:         tip
  user:        debugbuilddag
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     r0
  
  $ hg -R test --config experimental.extra-filter-revs='not public()' debugupdatecache
  $ ls -1 test/.hg/cache/
  branch2-base%89c45d2fa07e
  branch2-served
  hgtagsfnodes1
  rbc-names-v2
  rbc-revs-v2
  tags2
  tags2-served%89c45d2fa07e

cleanup

  $ cat errors.log
  $ killdaemons.py

Check the behavior is other filtered revision exists
----------------------------------------------------

add more content and complexity to the repository too

  $ hg -R test debugbuilddag '+6:branchpoint.:left+4*branchpoint.:right+5' --from-existing
  $ hg -R test phase --public 'desc("re:^r11$")'
  $ hg -R test phase --secret --force 'desc("re:^r9$")'
  $ hg -R test log -G -T '{desc} {phase}\n'
  o  r17 draft
  |
  o  r16 draft
  |
  o  r15 draft
  |
  o  r14 draft
  |
  o  r13 draft
  |
  o  r12 draft
  |
  o  r11 public
  |
  | o  r10 secret
  | |
  | o  r9 secret
  | |
  | o  r8 draft
  | |
  | o  r7 draft
  | |
  | o  r6 draft
  |/
  o  r5 public
  |
  o  r4 public
  |
  o  r3 public
  |
  o  r2 public
  |
  o  r1 public
  |
  o  r0 public
  
  $ hg -R test --config experimental.extra-filter-revs='(desc("re:^r13$") + desc("re:^r10$"))::' serve -p $HGPORT1 -d --pid-file=hg2.pid -E errors.log
  $ cat hg2.pid >> $DAEMON_PIDS
  $ hg -R test2 incoming http://foo:xyzzy@localhost:$HGPORT1/ -T '{desc}\n'
  comparing with http://foo:***@localhost:$HGPORT1/
  r0
  r1
  r2
  r3
  r4
  r5
  r6
  r7
  r8
  r11
  r12

cleanups

  $ cat errors.log
  $ killdaemons.py
