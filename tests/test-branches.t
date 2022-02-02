  $ hg init a
  $ cd a

Verify checking branch of nullrev before the cache is created doesnt crash
  $ hg log -r 'branch(.)' -T '{branch}\n'

Basic test
  $ echo 'root' >root
  $ hg add root
  $ hg commit -d '0 0' -m "Adding root node"

  $ echo 'a' >a
  $ hg add a
  $ hg branch a
  marked working directory as branch a
  (branches are permanent and global, did you want a bookmark?)
  $ hg commit -d '1 0' -m "Adding a branch"

  $ hg branch q
  marked working directory as branch q
  $ echo 'aa' >a
  $ hg branch -C
  reset working directory to branch a
  $ hg commit -d '2 0' -m "Adding to a branch"

  $ hg update -C 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo 'b' >b
  $ hg add b
  $ hg branch b
  marked working directory as branch b
  $ hg commit -d '2 0' -m "Adding b branch"

  $ echo 'bh1' >bh1
  $ hg add bh1
  $ hg commit -d '3 0' -m "Adding b branch head 1"

  $ hg update -C 2
  1 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo 'bh2' >bh2
  $ hg add bh2
  $ hg commit -d '4 0' -m "Adding b branch head 2"

  $ echo 'c' >c
  $ hg add c
  $ hg branch c
  marked working directory as branch c
  $ hg commit -d '5 0' -m "Adding c branch"

reserved names

  $ hg branch tip
  abort: the name 'tip' is reserved
  [10]
  $ hg branch null
  abort: the name 'null' is reserved
  [10]
  $ hg branch .
  abort: the name '.' is reserved
  [10]

invalid characters

  $ hg branch 'foo:bar'
  abort: ':' cannot be used in a name
  [10]

  $ hg branch 'foo
  > bar'
  abort: '\n' cannot be used in a name
  [10]

trailing or leading spaces should be stripped before testing duplicates

  $ hg branch 'b '
  abort: a branch of the same name already exists
  (use 'hg update' to switch to it)
  [10]

  $ hg branch ' b'
  abort: a branch of the same name already exists
  (use 'hg update' to switch to it)
  [10]

verify update will accept invalid legacy branch names

  $ hg init test-invalid-branch-name
  $ cd test-invalid-branch-name
  $ hg unbundle -u "$TESTDIR"/bundles/test-invalid-branch-name.hg
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 2 files
  new changesets f0e4c7f04036:33c2ceb9310b (3 drafts)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg update '"colon:test"'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ..

  $ echo 'd' >d
  $ hg add d
  $ hg branch 'a branch name much longer than the default justification used by branches'
  marked working directory as branch a branch name much longer than the default justification used by branches
  $ hg commit -d '6 0' -m "Adding d branch"

  $ hg branches
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  b                              4:aee39cd168d0
  c                              6:589736a22561 (inactive)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)

-------

  $ hg branches -a
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  b                              4:aee39cd168d0

--- Branch a

  $ hg log -b a
  changeset:   5:d8cbc61dbaa6
  branch:      a
  parent:      2:881fe2b92ad0
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     Adding b branch head 2
  
  changeset:   2:881fe2b92ad0
  branch:      a
  user:        test
  date:        Thu Jan 01 00:00:02 1970 +0000
  summary:     Adding to a branch
  
  changeset:   1:dd6b440dd85a
  branch:      a
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     Adding a branch
  

---- Branch b

  $ hg log -b b
  changeset:   4:aee39cd168d0
  branch:      b
  user:        test
  date:        Thu Jan 01 00:00:03 1970 +0000
  summary:     Adding b branch head 1
  
  changeset:   3:ac22033332d1
  branch:      b
  parent:      0:19709c5a4e75
  user:        test
  date:        Thu Jan 01 00:00:02 1970 +0000
  summary:     Adding b branch
  

---- going to test branch listing by rev
  $ hg branches -r0
  default                        0:19709c5a4e75 (inactive)
  $ hg branches -qr0
  default
--- now more than one rev
  $ hg branches -r2:5
  b                              4:aee39cd168d0
  a                              5:d8cbc61dbaa6 (inactive)
  $ hg branches -qr2:5
  b
  a
---- going to test branch closing

  $ hg branches
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  b                              4:aee39cd168d0
  c                              6:589736a22561 (inactive)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)
  $ hg up -C b
  2 files updated, 0 files merged, 4 files removed, 0 files unresolved
  $ echo 'xxx1' >> b
  $ hg commit -d '7 0' -m 'adding cset to branch b'
  $ hg up -C aee39cd168d0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo 'xxx2' >> b
  $ hg commit -d '8 0' -m 'adding head to branch b'
  created new head
  $ echo 'xxx3' >> b
  $ hg commit -d '9 0' -m 'adding another cset to branch b'
  $ hg branches
  b                             10:bfbe841b666e
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  c                              6:589736a22561 (inactive)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)
  $ hg heads --closed
  changeset:   10:bfbe841b666e
  branch:      b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     adding another cset to branch b
  
  changeset:   8:eebb944467c9
  branch:      b
  parent:      4:aee39cd168d0
  user:        test
  date:        Thu Jan 01 00:00:07 1970 +0000
  summary:     adding cset to branch b
  
  changeset:   7:10ff5895aa57
  branch:      a branch name much longer than the default justification used by branches
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     Adding d branch
  
  changeset:   6:589736a22561
  branch:      c
  user:        test
  date:        Thu Jan 01 00:00:05 1970 +0000
  summary:     Adding c branch
  
  changeset:   5:d8cbc61dbaa6
  branch:      a
  parent:      2:881fe2b92ad0
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     Adding b branch head 2
  
  changeset:   0:19709c5a4e75
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     Adding root node
  
  $ hg heads
  changeset:   10:bfbe841b666e
  branch:      b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     adding another cset to branch b
  
  changeset:   8:eebb944467c9
  branch:      b
  parent:      4:aee39cd168d0
  user:        test
  date:        Thu Jan 01 00:00:07 1970 +0000
  summary:     adding cset to branch b
  
  changeset:   7:10ff5895aa57
  branch:      a branch name much longer than the default justification used by branches
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     Adding d branch
  
  changeset:   6:589736a22561
  branch:      c
  user:        test
  date:        Thu Jan 01 00:00:05 1970 +0000
  summary:     Adding c branch
  
  changeset:   5:d8cbc61dbaa6
  branch:      a
  parent:      2:881fe2b92ad0
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     Adding b branch head 2
  
  changeset:   0:19709c5a4e75
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     Adding root node
  
  $ hg commit -d '9 0' --close-branch -m 'prune bad branch'
  $ hg branches -a
  b                              8:eebb944467c9
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  $ hg up -C b
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit -d '9 0' --close-branch -m 'close this part branch too'
  $ hg commit -d '9 0' --close-branch -m 're-closing this branch'
  abort: current revision is already a branch closing head
  [10]

  $ hg log -r tip --debug
  changeset:   12:e3d49c0575d8fc2cb1cd6859c747c14f5f6d499f
  branch:      b
  tag:         tip
  phase:       draft
  parent:      8:eebb944467c9fb9651ed232aeaf31b3c0a7fc6c1
  parent:      -1:0000000000000000000000000000000000000000
  manifest:    8:6f9ed32d2b310e391a4f107d5f0f071df785bfee
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  extra:       branch=b
  extra:       close=1
  description:
  close this part branch too
  
  
--- b branch should be inactive

  $ hg branches
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  c                              6:589736a22561 (inactive)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)
  $ hg branches -c
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  b                             12:e3d49c0575d8 (closed)
  c                              6:589736a22561 (inactive)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)
  $ hg branches -a
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  $ hg branches -q
  a branch name much longer than the default justification used by branches
  c
  a
  default
  $ hg heads b
  no open branch heads found on branches b
  [1]
  $ hg heads --closed b
  changeset:   12:e3d49c0575d8
  branch:      b
  tag:         tip
  parent:      8:eebb944467c9
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     close this part branch too
  
  changeset:   11:d3f163457ebf
  branch:      b
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     prune bad branch
  
  $ echo 'xxx4' >> b
  $ hg commit -d '9 0' -m 'reopen branch with a change'
  reopening closed branch head 12

--- branch b is back in action

  $ hg branches -a
  b                             13:e23b5505d1ad
  a branch name much longer than the default justification used by branches 7:10ff5895aa57

---- test heads listings

  $ hg heads
  changeset:   13:e23b5505d1ad
  branch:      b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     reopen branch with a change
  
  changeset:   7:10ff5895aa57
  branch:      a branch name much longer than the default justification used by branches
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     Adding d branch
  
  changeset:   6:589736a22561
  branch:      c
  user:        test
  date:        Thu Jan 01 00:00:05 1970 +0000
  summary:     Adding c branch
  
  changeset:   5:d8cbc61dbaa6
  branch:      a
  parent:      2:881fe2b92ad0
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     Adding b branch head 2
  
  changeset:   0:19709c5a4e75
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     Adding root node
  

branch default

  $ hg heads default
  changeset:   0:19709c5a4e75
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     Adding root node
  

branch a

  $ hg heads a
  changeset:   5:d8cbc61dbaa6
  branch:      a
  parent:      2:881fe2b92ad0
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     Adding b branch head 2
  
  $ hg heads --active a
  no open branch heads found on branches a
  [1]

branch b

  $ hg heads b
  changeset:   13:e23b5505d1ad
  branch:      b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     reopen branch with a change
  
  $ hg heads --closed b
  changeset:   13:e23b5505d1ad
  branch:      b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     reopen branch with a change
  
  changeset:   11:d3f163457ebf
  branch:      b
  user:        test
  date:        Thu Jan 01 00:00:09 1970 +0000
  summary:     prune bad branch
  

reclose branch

  $ hg up -C c
  3 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg commit -d '9 0' --close-branch -m 'reclosing this branch'
  $ hg branches
  b                             13:e23b5505d1ad
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)
  $ hg branches --closed
  b                             13:e23b5505d1ad
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  c                             14:f894c25619d3 (closed)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)

multihead branch

  $ hg up -C default
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg branch m
  marked working directory as branch m
  $ touch m
  $ hg add m
  $ hg commit -d '10 0' -m 'multihead base'
  $ echo "m1" >m
  $ hg commit -d '10 0' -m 'head 1'
  $ hg up -C '.^'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo "m2" >m
  $ hg commit -d '10 0' -m 'head 2'
  created new head
  $ hg log -b m
  changeset:   17:df343b0df04f
  branch:      m
  tag:         tip
  parent:      15:f3447637f53e
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     head 2
  
  changeset:   16:a58ca5d3bdf3
  branch:      m
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     head 1
  
  changeset:   15:f3447637f53e
  branch:      m
  parent:      0:19709c5a4e75
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     multihead base
  
  $ hg heads --topo m
  changeset:   17:df343b0df04f
  branch:      m
  tag:         tip
  parent:      15:f3447637f53e
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     head 2
  
  changeset:   16:a58ca5d3bdf3
  branch:      m
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     head 1
  
  $ hg branches
  m                             17:df343b0df04f
  b                             13:e23b5505d1ad
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)

partially merge multihead branch

  $ hg up -C default
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg branch md
  marked working directory as branch md
  $ hg merge m
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -d '11 0' -m 'merge head 2'
  $ hg heads --topo m
  changeset:   16:a58ca5d3bdf3
  branch:      m
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     head 1
  
  $ hg branches
  md                            18:c914c99f1fbb
  m                             17:df343b0df04f
  b                             13:e23b5505d1ad
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)

partially close multihead branch

  $ hg up -C a58ca5d3bdf3
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit -d '12 0' -m 'close head 1' --close-branch
  $ hg heads --topo m
  changeset:   19:cd21a80baa3d
  branch:      m
  tag:         tip
  parent:      16:a58ca5d3bdf3
  user:        test
  date:        Thu Jan 01 00:00:12 1970 +0000
  summary:     close head 1
  
  $ hg branches
  md                            18:c914c99f1fbb
  b                             13:e23b5505d1ad
  a branch name much longer than the default justification used by branches 7:10ff5895aa57
  m                             17:df343b0df04f (inactive)
  a                              5:d8cbc61dbaa6 (inactive)
  default                        0:19709c5a4e75 (inactive)

default branch colors:

  $ cat <<EOF >> $HGRCPATH
  > [extensions]
  > color =
  > [color]
  > mode = ansi
  > EOF

  $ hg up -C b
  2 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg branches --color=always
  \x1b[0;0mmd\x1b[0m\x1b[0;33m                            18:c914c99f1fbb\x1b[0m (esc)
  \x1b[0;32mb\x1b[0m\x1b[0;33m                             13:e23b5505d1ad\x1b[0m (esc)
  \x1b[0;0ma branch name much longer than the default justification used by branches\x1b[0m\x1b[0;33m 7:10ff5895aa57\x1b[0m (esc)
  \x1b[0;0mm\x1b[0m\x1b[0;33m                             17:df343b0df04f\x1b[0m (inactive) (esc)
  \x1b[0;0ma\x1b[0m\x1b[0;33m                              5:d8cbc61dbaa6\x1b[0m (inactive) (esc)
  \x1b[0;0mdefault\x1b[0m\x1b[0;33m                        0:19709c5a4e75\x1b[0m (inactive) (esc)

default closed branch color:

  $ hg branches --color=always --closed
  \x1b[0;0mmd\x1b[0m\x1b[0;33m                            18:c914c99f1fbb\x1b[0m (esc)
  \x1b[0;32mb\x1b[0m\x1b[0;33m                             13:e23b5505d1ad\x1b[0m (esc)
  \x1b[0;0ma branch name much longer than the default justification used by branches\x1b[0m\x1b[0;33m 7:10ff5895aa57\x1b[0m (esc)
  \x1b[0;0mm\x1b[0m\x1b[0;33m                             17:df343b0df04f\x1b[0m (inactive) (esc)
  \x1b[0;30;1mc\x1b[0m\x1b[0;33m                             14:f894c25619d3\x1b[0m (closed) (esc)
  \x1b[0;0ma\x1b[0m\x1b[0;33m                              5:d8cbc61dbaa6\x1b[0m (inactive) (esc)
  \x1b[0;0mdefault\x1b[0m\x1b[0;33m                        0:19709c5a4e75\x1b[0m (inactive) (esc)

  $ cat <<EOF >> $HGRCPATH
  > [extensions]
  > color =
  > [color]
  > branches.active = green
  > branches.closed = blue
  > branches.current = red
  > branches.inactive = magenta
  > log.changeset = cyan
  > EOF

custom branch colors:

  $ hg branches --color=always
  \x1b[0;32mmd\x1b[0m\x1b[0;36m                            18:c914c99f1fbb\x1b[0m (esc)
  \x1b[0;31mb\x1b[0m\x1b[0;36m                             13:e23b5505d1ad\x1b[0m (esc)
  \x1b[0;32ma branch name much longer than the default justification used by branches\x1b[0m\x1b[0;36m 7:10ff5895aa57\x1b[0m (esc)
  \x1b[0;35mm\x1b[0m\x1b[0;36m                             17:df343b0df04f\x1b[0m (inactive) (esc)
  \x1b[0;35ma\x1b[0m\x1b[0;36m                              5:d8cbc61dbaa6\x1b[0m (inactive) (esc)
  \x1b[0;35mdefault\x1b[0m\x1b[0;36m                        0:19709c5a4e75\x1b[0m (inactive) (esc)

custom closed branch color:

  $ hg branches --color=always --closed
  \x1b[0;32mmd\x1b[0m\x1b[0;36m                            18:c914c99f1fbb\x1b[0m (esc)
  \x1b[0;31mb\x1b[0m\x1b[0;36m                             13:e23b5505d1ad\x1b[0m (esc)
  \x1b[0;32ma branch name much longer than the default justification used by branches\x1b[0m\x1b[0;36m 7:10ff5895aa57\x1b[0m (esc)
  \x1b[0;35mm\x1b[0m\x1b[0;36m                             17:df343b0df04f\x1b[0m (inactive) (esc)
  \x1b[0;34mc\x1b[0m\x1b[0;36m                             14:f894c25619d3\x1b[0m (closed) (esc)
  \x1b[0;35ma\x1b[0m\x1b[0;36m                              5:d8cbc61dbaa6\x1b[0m (inactive) (esc)
  \x1b[0;35mdefault\x1b[0m\x1b[0;36m                        0:19709c5a4e75\x1b[0m (inactive) (esc)

template output:

  $ hg branches -Tjson --closed
  [
   {
    "active": true,
    "branch": "md",
    "closed": false,
    "current": false,
    "node": "c914c99f1fbb2b1d785a0a939ed3f67275df18e9",
    "rev": 18
   },
   {
    "active": true,
    "branch": "b",
    "closed": false,
    "current": true,
    "node": "e23b5505d1ad24aab6f84fd8c7cb8cd8e5e93be0",
    "rev": 13
   },
   {
    "active": true,
    "branch": "a branch name much longer than the default justification used by branches",
    "closed": false,
    "current": false,
    "node": "10ff5895aa5793bd378da574af8cec8ea408d831",
    "rev": 7
   },
   {
    "active": false,
    "branch": "m",
    "closed": false,
    "current": false,
    "node": "df343b0df04feb2a946cd4b6e9520e552fef14ee",
    "rev": 17
   },
   {
    "active": false,
    "branch": "c",
    "closed": true,
    "current": false,
    "node": "f894c25619d3f1484639d81be950e0a07bc6f1f6",
    "rev": 14
   },
   {
    "active": false,
    "branch": "a",
    "closed": false,
    "current": false,
    "node": "d8cbc61dbaa6dc817175d1e301eecb863f280832",
    "rev": 5
   },
   {
    "active": false,
    "branch": "default",
    "closed": false,
    "current": false,
    "node": "19709c5a4e75bf938f8e349aff97438539bb729e",
    "rev": 0
   }
  ]

  $ hg branches --closed -T '{if(closed, "{branch}\n")}'
  c

  $ hg branches -T '{word(0, branch)}: {desc|firstline}\n'
  md: merge head 2
  b: reopen branch with a change
  a: Adding d branch
  m: head 2
  a: Adding b branch head 2
  default: Adding root node

  $ cat <<'EOF' > "$TESTTMP/map-myjson"
  > docheader = '\{\n'
  > docfooter = '\n}\n'
  > separator = ',\n'
  > branches = ' {dict(branch, node|short)|json}'
  > EOF
  $ hg branches -T "$TESTTMP/map-myjson"
  {
   {"branch": "md", "node": "c914c99f1fbb"},
   {"branch": "b", "node": "e23b5505d1ad"},
   {"branch": "a branch *", "node": "10ff5895aa57"}, (glob)
   {"branch": "m", "node": "df343b0df04f"},
   {"branch": "a", "node": "d8cbc61dbaa6"},
   {"branch": "default", "node": "19709c5a4e75"}
  }

  $ cat <<'EOF' >> .hg/hgrc
  > [templates]
  > myjson = ' {dict(branch, node|short)|json}'
  > myjson:docheader = '\{\n'
  > myjson:docfooter = '\n}\n'
  > myjson:separator = ',\n'
  > EOF
  $ hg branches -T myjson
  {
   {"branch": "md", "node": "c914c99f1fbb"},
   {"branch": "b", "node": "e23b5505d1ad"},
   {"branch": "a branch *", "node": "10ff5895aa57"}, (glob)
   {"branch": "m", "node": "df343b0df04f"},
   {"branch": "a", "node": "d8cbc61dbaa6"},
   {"branch": "default", "node": "19709c5a4e75"}
  }

  $ cat <<'EOF' >> .hg/hgrc
  > [templates]
  > :docheader = 'should not be selected as a docheader for literal templates\n'
  > EOF
  $ hg branches -T '{branch}\n'
  md
  b
  a branch name much longer than the default justification used by branches
  m
  a
  default

Tests of revision branch name caching

We rev branch cache is updated automatically. In these tests we use a trick to
trigger rebuilds. We remove the branch head cache and run 'hg head' to cause a
rebuild that also will populate the rev branch cache.

revision branch cache is created when building the branch head cache
  $ rm -rf .hg/cache; hg head a -T '{rev}\n'
  5
  $ f --hexdump --size .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=92
  0000: 64 65 66 61 75 6c 74 00 61 00 62 00 63 00 61 20 |default.a.b.c.a |
  0010: 62 72 61 6e 63 68 20 6e 61 6d 65 20 6d 75 63 68 |branch name much|
  0020: 20 6c 6f 6e 67 65 72 20 74 68 61 6e 20 74 68 65 | longer than the|
  0030: 20 64 65 66 61 75 6c 74 20 6a 75 73 74 69 66 69 | default justifi|
  0040: 63 61 74 69 6f 6e 20 75 73 65 64 20 62 79 20 62 |cation used by b|
  0050: 72 61 6e 63 68 65 73 00 6d 00 6d 64             |ranches.m.md|
  .hg/cache/rbc-revs-v1: size=160
  0000: 19 70 9c 5a 00 00 00 00 dd 6b 44 0d 00 00 00 01 |.p.Z.....kD.....|
  0010: 88 1f e2 b9 00 00 00 01 ac 22 03 33 00 00 00 02 |.........".3....|
  0020: ae e3 9c d1 00 00 00 02 d8 cb c6 1d 00 00 00 01 |................|
  0030: 58 97 36 a2 00 00 00 03 10 ff 58 95 00 00 00 04 |X.6.......X.....|
  0040: ee bb 94 44 00 00 00 02 5f 40 61 bb 00 00 00 02 |...D...._@a.....|
  0050: bf be 84 1b 00 00 00 02 d3 f1 63 45 80 00 00 02 |..........cE....|
  0060: e3 d4 9c 05 80 00 00 02 e2 3b 55 05 00 00 00 02 |.........;U.....|
  0070: f8 94 c2 56 80 00 00 03 f3 44 76 37 00 00 00 05 |...V.....Dv7....|
  0080: a5 8c a5 d3 00 00 00 05 df 34 3b 0d 00 00 00 05 |.........4;.....|
  0090: c9 14 c9 9f 00 00 00 06 cd 21 a8 0b 80 00 00 05 |.........!......|

no errors when revbranchcache is not writable

  $ echo >> .hg/cache/rbc-revs-v1
  $ mv .hg/cache/rbc-revs-v1 .hg/cache/rbc-revs-v1_
  $ mkdir .hg/cache/rbc-revs-v1
  $ rm -f .hg/cache/branch* && hg head a -T '{rev}\n'
  5
  $ rmdir .hg/cache/rbc-revs-v1
  $ mv .hg/cache/rbc-revs-v1_ .hg/cache/rbc-revs-v1

no errors when wlock cannot be acquired

#if unix-permissions
  $ mv .hg/cache/rbc-revs-v1 .hg/cache/rbc-revs-v1_
  $ rm -f .hg/cache/branch*
  $ chmod 555 .hg
  $ hg head a -T '{rev}\n'
  5
  $ chmod 755 .hg
  $ mv .hg/cache/rbc-revs-v1_ .hg/cache/rbc-revs-v1
#endif

recovery from invalid cache revs file with trailing data
  $ echo >> .hg/cache/rbc-revs-v1
  $ rm -f .hg/cache/branch* && hg head a -T '{rev}\n' --debug
  5
  truncating cache/rbc-revs-v1 to 160
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=160
recovery from invalid cache file with partial last record
  $ mv .hg/cache/rbc-revs-v1 .
  $ f -qDB 119 rbc-revs-v1 > .hg/cache/rbc-revs-v1
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=119
  $ rm -f .hg/cache/branch* && hg head a -T '{rev}\n' --debug
  5
  truncating cache/rbc-revs-v1 to 112
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=160
recovery from invalid cache file with missing record - no truncation
  $ mv .hg/cache/rbc-revs-v1 .
  $ f -qDB 112 rbc-revs-v1 > .hg/cache/rbc-revs-v1
  $ rm -f .hg/cache/branch* && hg head a -T '{rev}\n' --debug
  5
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=160
recovery from invalid cache file with some bad records
  $ mv .hg/cache/rbc-revs-v1 .
  $ f -qDB 8 rbc-revs-v1 > .hg/cache/rbc-revs-v1
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=8
  $ f -qDB 112 rbc-revs-v1 >> .hg/cache/rbc-revs-v1
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=120
  $ hg log -r 'branch(.)' -T '{rev} ' --debug
  history modification detected - truncating revision branch cache to revision 13
  history modification detected - truncating revision branch cache to revision 1
  3 4 8 9 10 11 12 13 truncating cache/rbc-revs-v1 to 8
  $ rm -f .hg/cache/branch* && hg head a -T '{rev}\n' --debug
  5
  truncating cache/rbc-revs-v1 to 104
  $ f --size --hexdump --bytes=16 .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=160
  0000: 19 70 9c 5a 00 00 00 00 dd 6b 44 0d 00 00 00 01 |.p.Z.....kD.....|
cache is updated when committing
  $ hg branch i-will-regret-this
  marked working directory as branch i-will-regret-this
  $ hg ci -m regrets
  $ f --size .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=111
  .hg/cache/rbc-revs-v1: size=168
update after rollback - the cache will be correct but rbc-names will will still
contain the branch name even though it no longer is used
  $ hg up -qr '.^'
  $ hg rollback -qf
  $ f --size --hexdump .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=111
  0000: 64 65 66 61 75 6c 74 00 61 00 62 00 63 00 61 20 |default.a.b.c.a |
  0010: 62 72 61 6e 63 68 20 6e 61 6d 65 20 6d 75 63 68 |branch name much|
  0020: 20 6c 6f 6e 67 65 72 20 74 68 61 6e 20 74 68 65 | longer than the|
  0030: 20 64 65 66 61 75 6c 74 20 6a 75 73 74 69 66 69 | default justifi|
  0040: 63 61 74 69 6f 6e 20 75 73 65 64 20 62 79 20 62 |cation used by b|
  0050: 72 61 6e 63 68 65 73 00 6d 00 6d 64 00 69 2d 77 |ranches.m.md.i-w|
  0060: 69 6c 6c 2d 72 65 67 72 65 74 2d 74 68 69 73    |ill-regret-this|
  .hg/cache/rbc-revs-v1: size=160
  0000: 19 70 9c 5a 00 00 00 00 dd 6b 44 0d 00 00 00 01 |.p.Z.....kD.....|
  0010: 88 1f e2 b9 00 00 00 01 ac 22 03 33 00 00 00 02 |.........".3....|
  0020: ae e3 9c d1 00 00 00 02 d8 cb c6 1d 00 00 00 01 |................|
  0030: 58 97 36 a2 00 00 00 03 10 ff 58 95 00 00 00 04 |X.6.......X.....|
  0040: ee bb 94 44 00 00 00 02 5f 40 61 bb 00 00 00 02 |...D...._@a.....|
  0050: bf be 84 1b 00 00 00 02 d3 f1 63 45 80 00 00 02 |..........cE....|
  0060: e3 d4 9c 05 80 00 00 02 e2 3b 55 05 00 00 00 02 |.........;U.....|
  0070: f8 94 c2 56 80 00 00 03 f3 44 76 37 00 00 00 05 |...V.....Dv7....|
  0080: a5 8c a5 d3 00 00 00 05 df 34 3b 0d 00 00 00 05 |.........4;.....|
  0090: c9 14 c9 9f 00 00 00 06 cd 21 a8 0b 80 00 00 05 |.........!......|
cache is updated/truncated when stripping - it is thus very hard to get in a
situation where the cache is out of sync and the hash check detects it
  $ hg --config extensions.strip= strip -r tip --nob
  $ f --size .hg/cache/rbc-revs*
  .hg/cache/rbc-revs-v1: size=152

cache is rebuilt when corruption is detected
  $ echo > .hg/cache/rbc-names-v1
  $ hg log -r '5:&branch(.)' -T '{rev} ' --debug
  referenced branch names not found - rebuilding revision branch cache from scratch
  8 9 10 11 12 13 truncating cache/rbc-revs-v1 to 40
  $ f --size --hexdump .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=84
  0000: 62 00 61 00 63 00 61 20 62 72 61 6e 63 68 20 6e |b.a.c.a branch n|
  0010: 61 6d 65 20 6d 75 63 68 20 6c 6f 6e 67 65 72 20 |ame much longer |
  0020: 74 68 61 6e 20 74 68 65 20 64 65 66 61 75 6c 74 |than the default|
  0030: 20 6a 75 73 74 69 66 69 63 61 74 69 6f 6e 20 75 | justification u|
  0040: 73 65 64 20 62 79 20 62 72 61 6e 63 68 65 73 00 |sed by branches.|
  0050: 6d 00 6d 64                                     |m.md|
  .hg/cache/rbc-revs-v1: size=152
  0000: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0020: 00 00 00 00 00 00 00 00 d8 cb c6 1d 00 00 00 01 |................|
  0030: 58 97 36 a2 00 00 00 02 10 ff 58 95 00 00 00 03 |X.6.......X.....|
  0040: ee bb 94 44 00 00 00 00 5f 40 61 bb 00 00 00 00 |...D...._@a.....|
  0050: bf be 84 1b 00 00 00 00 d3 f1 63 45 80 00 00 00 |..........cE....|
  0060: e3 d4 9c 05 80 00 00 00 e2 3b 55 05 00 00 00 00 |.........;U.....|
  0070: f8 94 c2 56 80 00 00 02 f3 44 76 37 00 00 00 04 |...V.....Dv7....|
  0080: a5 8c a5 d3 00 00 00 04 df 34 3b 0d 00 00 00 04 |.........4;.....|
  0090: c9 14 c9 9f 00 00 00 05                         |........|

Test that cache files are created and grows correctly:

  $ rm .hg/cache/rbc*
  $ hg log -r "5 & branch(5)" -T "{rev}\n"
  5
  $ f --size --hexdump .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=1
  0000: 61                                              |a|
  .hg/cache/rbc-revs-v1: size=152
  0000: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0020: 00 00 00 00 00 00 00 00 d8 cb c6 1d 00 00 00 00 |................|
  0030: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0040: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0050: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0060: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0070: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0080: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|
  0090: 00 00 00 00 00 00 00 00                         |........|

  $ cd ..

Test for multiple incorrect branch cache entries:

  $ hg init b
  $ cd b
  $ touch f
  $ hg ci -Aqmf
  $ echo >> f
  $ hg ci -Amf
  $ hg branch -q branch
  $ hg ci -Amf

  $ f --size --hexdump .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=14
  0000: 64 65 66 61 75 6c 74 00 62 72 61 6e 63 68       |default.branch|
  .hg/cache/rbc-revs-v1: size=24
  0000: 66 e5 f5 aa 00 00 00 00 fa 4c 04 e5 00 00 00 00 |f........L......|
  0010: 56 46 78 69 00 00 00 01                         |VFxi....|
  $ : > .hg/cache/rbc-revs-v1

No superfluous rebuilding of cache:
  $ hg log -r "branch(null)&branch(branch)" --debug
  $ f --size --hexdump .hg/cache/rbc-*
  .hg/cache/rbc-names-v1: size=14
  0000: 64 65 66 61 75 6c 74 00 62 72 61 6e 63 68       |default.branch|
  .hg/cache/rbc-revs-v1: size=24
  0000: 66 e5 f5 aa 00 00 00 00 fa 4c 04 e5 00 00 00 00 |f........L......|
  0010: 56 46 78 69 00 00 00 01                         |VFxi....|

  $ cd ..

Test to make sure that `--close-branch` only works on a branch head:
--------------------------------------------------------------------
  $ hg init closebranch
  $ cd closebranch
  $ for ch in a b c; do
  > echo $ch > $ch
  > hg add $ch
  > hg ci -m "added "$ch
  > done;

  $ hg up -r "desc('added b')"
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved

trying to close branch from a cset which is not a branch head
it should abort:
  $ hg ci -m "closing branch" --close-branch
  abort: can only close branch heads
  (use --force-close-branch to close branch from a non-head changeset)
  [10]

  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg log -GT "{rev}: {node|short} {desc|firstline}\n\t{branch}\n\n"
  o  2: 155349b645be added c
  |  	default
  |
  o  1: 5f6d8a4bf34a added b
  |  	default
  |
  @  0: 9092f1db7931 added a
     	default
  
Test --force-close-branch to close a branch from a non-head changeset:
---------------------------------------------------------------------

  $ hg show stack --config extensions.show=
    o  1553 added c
    o  5f6d added b
    @  9092 added a

  $ hg ci -m "branch closed" --close-branch
  abort: can only close branch heads
  (use --force-close-branch to close branch from a non-head changeset)
  [10]

  $ hg ci -m "branch closed" --force-close-branch
  created new head
  $ cd ..

Test various special cases for the branchmap
--------------------------------------------

Basic fork of the same branch

  $ hg init branchmap-testing1
  $ cd branchmap-testing1
  $ hg debugbuild '@A . :base . :p1 *base /p1'
  $ hg log -G
  o    changeset:   3:71ca9a6d524e
  |\   branch:      A
  | |  tag:         tip
  | |  parent:      2:a3b807b3ff0b
  | |  parent:      1:99ba08759bc7
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:03 1970 +0000
  | |  summary:     r3
  | |
  | o  changeset:   2:a3b807b3ff0b
  | |  branch:      A
  | |  parent:      0:2ab8003a1750
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:02 1970 +0000
  | |  summary:     r2
  | |
  o |  changeset:   1:99ba08759bc7
  |/   branch:      A
  |    tag:         p1
  |    user:        debugbuilddag
  |    date:        Thu Jan 01 00:00:01 1970 +0000
  |    summary:     r1
  |
  o  changeset:   0:2ab8003a1750
     branch:      A
     tag:         base
     user:        debugbuilddag
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     r0
  
  $ hg branches
  A                              3:71ca9a6d524e
  $ hg clone -r 1 -r 2 . ../branchmap-testing1-clone
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 0 changes to 0 files (+1 heads)
  new changesets 2ab8003a1750:a3b807b3ff0b
  updating to branch A
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../branchmap-testing1-clone
  $ hg pull ../branchmap-testing1
  pulling from ../branchmap-testing1
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (-1 heads)
  new changesets 71ca9a6d524e
  (run 'hg update' to get a working copy)
  $ hg branches
  A                              3:71ca9a6d524e
  $ cd ..

Switching to a different branch and back

  $ hg init branchmap-testing2
  $ cd branchmap-testing2
  $ hg debugbuild '@A . @B . @A .'
  $ hg log -G
  o  changeset:   2:9699e9f260b5
  |  branch:      A
  |  tag:         tip
  |  user:        debugbuilddag
  |  date:        Thu Jan 01 00:00:02 1970 +0000
  |  summary:     r2
  |
  o  changeset:   1:0bc7d348d965
  |  branch:      B
  |  user:        debugbuilddag
  |  date:        Thu Jan 01 00:00:01 1970 +0000
  |  summary:     r1
  |
  o  changeset:   0:2ab8003a1750
     branch:      A
     user:        debugbuilddag
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     r0
  
  $ hg branches
  A                              2:9699e9f260b5
  B                              1:0bc7d348d965 (inactive)
  $ hg clone -r 1 . ../branchmap-testing2-clone
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  new changesets 2ab8003a1750:0bc7d348d965
  updating to branch B
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../branchmap-testing2-clone
  $ hg pull ../branchmap-testing2
  pulling from ../branchmap-testing2
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 9699e9f260b5
  (run 'hg update' to get a working copy)
  $ hg branches
  A                              2:9699e9f260b5
  B                              1:0bc7d348d965 (inactive)
  $ cd ..

A fork on a branch switching to a different branch and back
is still collecting the fork.

  $ hg init branchmap-testing3
  $ cd branchmap-testing3
  $ hg debugbuild '@A . :base . :p1 *base @B . @A /p1'
  $ hg log -G
  o    changeset:   4:3614a1711d23
  |\   branch:      A
  | |  tag:         tip
  | |  parent:      3:e9c8abcf65aa
  | |  parent:      1:99ba08759bc7
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:04 1970 +0000
  | |  summary:     r4
  | |
  | o  changeset:   3:e9c8abcf65aa
  | |  branch:      B
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:03 1970 +0000
  | |  summary:     r3
  | |
  | o  changeset:   2:a3b807b3ff0b
  | |  branch:      A
  | |  parent:      0:2ab8003a1750
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:02 1970 +0000
  | |  summary:     r2
  | |
  o |  changeset:   1:99ba08759bc7
  |/   branch:      A
  |    tag:         p1
  |    user:        debugbuilddag
  |    date:        Thu Jan 01 00:00:01 1970 +0000
  |    summary:     r1
  |
  o  changeset:   0:2ab8003a1750
     branch:      A
     tag:         base
     user:        debugbuilddag
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     r0
  
  $ hg branches
  A                              4:3614a1711d23
  B                              3:e9c8abcf65aa (inactive)
  $ hg clone -r 1 -r 3 . ../branchmap-testing3-clone
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 0 changes to 0 files (+1 heads)
  new changesets 2ab8003a1750:e9c8abcf65aa
  updating to branch A
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../branchmap-testing3-clone
  $ hg pull ../branchmap-testing3
  pulling from ../branchmap-testing3
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (-1 heads)
  new changesets 3614a1711d23
  (run 'hg update' to get a working copy)
  $ hg branches
  A                              4:3614a1711d23
  B                              3:e9c8abcf65aa (inactive)
  $ cd ..

Intermediary parents are on different branches.

  $ hg init branchmap-testing4
  $ cd branchmap-testing4
  $ hg debugbuild '@A . @B :base . @A :p1 *base @C . @A /p1'
  $ hg log -G
  o    changeset:   4:4bf67499b70a
  |\   branch:      A
  | |  tag:         tip
  | |  parent:      3:4a546028fa8f
  | |  parent:      1:0bc7d348d965
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:04 1970 +0000
  | |  summary:     r4
  | |
  | o  changeset:   3:4a546028fa8f
  | |  branch:      C
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:03 1970 +0000
  | |  summary:     r3
  | |
  | o  changeset:   2:a3b807b3ff0b
  | |  branch:      A
  | |  parent:      0:2ab8003a1750
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:02 1970 +0000
  | |  summary:     r2
  | |
  o |  changeset:   1:0bc7d348d965
  |/   branch:      B
  |    tag:         p1
  |    user:        debugbuilddag
  |    date:        Thu Jan 01 00:00:01 1970 +0000
  |    summary:     r1
  |
  o  changeset:   0:2ab8003a1750
     branch:      A
     tag:         base
     user:        debugbuilddag
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     r0
  
  $ hg branches
  A                              4:4bf67499b70a
  C                              3:4a546028fa8f (inactive)
  B                              1:0bc7d348d965 (inactive)
  $ hg clone -r 1 -r 3 . ../branchmap-testing4-clone
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 0 changes to 0 files (+1 heads)
  new changesets 2ab8003a1750:4a546028fa8f
  updating to branch B
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../branchmap-testing4-clone
  $ hg pull ../branchmap-testing4
  pulling from ../branchmap-testing4
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (-1 heads)
  new changesets 4bf67499b70a
  (run 'hg update' to get a working copy)
  $ hg branches
  A                              4:4bf67499b70a
  C                              3:4a546028fa8f (inactive)
  B                              1:0bc7d348d965 (inactive)
  $ cd ..

Check that the cache are not written too early
----------------------------------------------

  $ hg log -R branchmap-testing1 -G
  o    changeset:   3:71ca9a6d524e
  |\   branch:      A
  | |  tag:         tip
  | |  parent:      2:a3b807b3ff0b
  | |  parent:      1:99ba08759bc7
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:03 1970 +0000
  | |  summary:     r3
  | |
  | o  changeset:   2:a3b807b3ff0b
  | |  branch:      A
  | |  parent:      0:2ab8003a1750
  | |  user:        debugbuilddag
  | |  date:        Thu Jan 01 00:00:02 1970 +0000
  | |  summary:     r2
  | |
  o |  changeset:   1:99ba08759bc7
  |/   branch:      A
  |    tag:         p1
  |    user:        debugbuilddag
  |    date:        Thu Jan 01 00:00:01 1970 +0000
  |    summary:     r1
  |
  o  changeset:   0:2ab8003a1750
     branch:      A
     tag:         base
     user:        debugbuilddag
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     r0
  
  $ hg bundle -R branchmap-testing1 --base 1 bundle.hg --rev 'head()'
  2 changesets found

Unbundling revision should warm the served cache

  $ hg clone branchmap-testing1 --rev 1 branchmap-update-01
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  new changesets 2ab8003a1750:99ba08759bc7
  updating to branch A
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat branchmap-update-01/.hg/cache/branch2-served
  99ba08759bc7f6fdbe5304e83d0387f35c082479 1
  99ba08759bc7f6fdbe5304e83d0387f35c082479 o A
  $ hg -R branchmap-update-01 unbundle bundle.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  new changesets a3b807b3ff0b:71ca9a6d524e (2 drafts)
  (run 'hg update' to get a working copy)
  $ cat branchmap-update-01/.hg/cache/branch2-served
  71ca9a6d524ed3c2a215119b2086ac3b8c4c8286 3
  71ca9a6d524ed3c2a215119b2086ac3b8c4c8286 o A

aborted Unbundle should not update the on disk cache

  $ cat >> simplehook.py << EOF
  > import sys
  > from mercurial import node
  > from mercurial import branchmap
  > def hook(ui, repo, *args, **kwargs):
  >     s = repo.filtered(b"served")
  >     s.branchmap()
  >     return 1
  > EOF
  $ hg clone branchmap-testing1 --rev 1 branchmap-update-02
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  new changesets 2ab8003a1750:99ba08759bc7
  updating to branch A
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cat branchmap-update-02/.hg/cache/branch2-served
  99ba08759bc7f6fdbe5304e83d0387f35c082479 1
  99ba08759bc7f6fdbe5304e83d0387f35c082479 o A
  $ hg -R branchmap-update-02 unbundle bundle.hg --config "hooks.pretxnclose=python:$TESTTMP/simplehook.py:hook"
  adding changesets
  adding manifests
  adding file changes
  transaction abort!
  rollback completed
  abort: pretxnclose hook failed
  [40]
  $ cat branchmap-update-02/.hg/cache/branch2-served
  99ba08759bc7f6fdbe5304e83d0387f35c082479 1
  99ba08759bc7f6fdbe5304e83d0387f35c082479 o A
