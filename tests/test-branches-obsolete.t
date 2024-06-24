================================================================
test the interaction of the branch cache with obsolete changeset
================================================================

Some corner case have been covered by unrelated test (like rebase ones) this
file meant to gather explicite testing of those.

See also: test-obsolete-checkheads.t

#testcases v2 v3

  $ cat >> $HGRCPATH << EOF
  > [phases]
  > publish = false
  > [experimental]
  > evolution = all
  > server.allow-hidden-access = *
  > EOF

#if v3
  $ cat <<EOF >> $HGRCPATH
  > [experimental]
  > branch-cache-v3=yes
  > EOF
  $ CACHE_PREFIX=branch3-exp
#else
  $ cat <<EOF >> $HGRCPATH
  > [experimental]
  > branch-cache-v3=no
  > EOF
  $ CACHE_PREFIX=branch2
#endif

  $ show_cache() {
  >     for cache_file in .hg/cache/$CACHE_PREFIX*; do
  >         echo "##### $cache_file"
  >         cat $cache_file
  >     done
  > }

Setup graph
#############

  $ . $RUNTESTDIR/testlib/common.sh

graph with a single branch
--------------------------

We want some branching and some obsolescence

  $ hg init main-single-branch
  $ cd main-single-branch
  $ mkcommit root
  $ mkcommit A_1
  $ mkcommit A_2
  $ hg update 'desc("A_2")' --quiet
  $ mkcommit B_1
  $ mkcommit B_2
  $ mkcommit B_3
  $ mkcommit B_4
  $ hg update 'desc("A_2")' --quiet
  $ mkcommit A_3
  created new head
  $ mkcommit A_4
  $ hg up null --quiet
  $ hg clone --noupdate . ../main-single-branch-pre-ops
  $ hg log -r 'desc("A_1")' -T '{node}' > ../main-single-branch-node_A1
  $ hg log -r 'desc("A_2")' -T '{node}' > ../main-single-branch-node_A2
  $ hg log -r 'desc("A_3")' -T '{node}' > ../main-single-branch-node_A3
  $ hg log -r 'desc("A_4")' -T '{node}' > ../main-single-branch-node_A4
  $ hg log -r 'desc("B_1")' -T '{node}' > ../main-single-branch-node_B1
  $ hg log -r 'desc("B_2")' -T '{node}' > ../main-single-branch-node_B2
  $ hg log -r 'desc("B_3")' -T '{node}' > ../main-single-branch-node_B3
  $ hg log -r 'desc("B_4")' -T '{node}' > ../main-single-branch-node_B4

(double check the heads are right before we obsolete)

  $ hg log -R ../main-single-branch-pre-ops -G -T '{desc}\n'
  o  A_4
  |
  o  A_3
  |
  | o  B_4
  | |
  | o  B_3
  | |
  | o  B_2
  | |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  
  $ hg log -G -T '{desc}\n'
  o  A_4
  |
  o  A_3
  |
  | o  B_4
  | |
  | o  B_3
  | |
  | o  B_2
  | |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  

#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8
  63ba7cd843d1e95aac1a24435befeb1909c53619 o default
  3d808bbc94408ea19da905596d4079357a1f28be o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8 topo-mode=pure
  default
#endif
  $ hg log -T '{desc}\n' --rev 'head()'
  B_4
  A_4

Absolete a couple of changes

  $ for d in B2 B3 B4 A4; do
  >   hg debugobsolete --record-parents `cat ../main-single-branch-node_$d`;
  > done
  1 new obsolescence markers
  obsoleted 1 changesets
  2 new orphan changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets

(double check the result is okay)

  $ hg log -G -T '{desc}\n'
  o  A_3
  |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  7c29ff2453bf38c75ee8982935739103c38a9284 7 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f8006d64a10d35c011a5c5fa88be1e25c5929514 tip-node=7c29ff2453bf38c75ee8982935739103c38a9284 tip-rev=7 topo-mode=pure
  default
#endif
  $ cd ..


Actual testing
##############

Revealing obsolete changeset
----------------------------

Check that revealing obsolete changesets does not confuse branch computation and checks

Revealing tipmost changeset
~~~~~~~~~~~~~~~~~~~~~~~~~~~


  $ cp -R ./main-single-branch tmp-repo
  $ cd tmp-repo
  $ hg update --hidden --rev 'desc("A_4")' --quiet
  updated to hidden changeset 3d808bbc9440
  (hidden revision '3d808bbc9440' is pruned)
  $ hg log -G -T '{desc}\n'
  @  A_4
  |
  o  A_3
  |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2
  3d808bbc94408ea19da905596d4079357a1f28be 8 a943c3355ad9e93654d58b1c934c7c4329a5d1d4
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 a943c3355ad9e93654d58b1c934c7c4329a5d1d4
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp
  obsolete-hash=b6d2b1f5b70f09c25c835edcae69be35f681605c tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f8006d64a10d35c011a5c5fa88be1e25c5929514 obsolete-hash=ac5282439f301518f362f37547fcd52bcc670373 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#endif

Even when computing branches from scratch

  $ rm -rf .hg/cache/branch*
  $ rm -rf .hg/wcache/branch*
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 a943c3355ad9e93654d58b1c934c7c4329a5d1d4
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f8006d64a10d35c011a5c5fa88be1e25c5929514 obsolete-hash=ac5282439f301518f362f37547fcd52bcc670373 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#endif

And we can get back to normal

  $ hg update null --quiet
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  7c29ff2453bf38c75ee8982935739103c38a9284 7 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f8006d64a10d35c011a5c5fa88be1e25c5929514 tip-node=7c29ff2453bf38c75ee8982935739103c38a9284 tip-rev=7 topo-mode=pure
  default
#endif

  $ cd ..
  $ rm -rf tmp-repo

Revealing  changeset in the middle of the changelog
~~~~~~~~~~~~~~~~~~~~~~~~~~~------------------------

Check that revealing an obsolete changeset does not confuse branch computation and checks

  $ cp -R ./main-single-branch tmp-repo
  $ cd tmp-repo
  $ hg update --hidden --rev 'desc("B_3")' --quiet
  updated to hidden changeset 9c996d7674bb
  (hidden revision '9c996d7674bb' is pruned)
  $ hg log -G -T '{desc}\n'
  o  A_3
  |
  | @  B_3
  | |
  | x  B_2
  | |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2
  3d808bbc94408ea19da905596d4079357a1f28be 8 a943c3355ad9e93654d58b1c934c7c4329a5d1d4
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
  ##### .hg/cache/branch2-served
  7c29ff2453bf38c75ee8982935739103c38a9284 7 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp
  obsolete-hash=b6d2b1f5b70f09c25c835edcae69be35f681605c tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f1456c0d675980582dda9b8edc7f13f503ce544f obsolete-hash=3e74f5349008671629e39d13d7e00d9ba94c74f7 tip-node=7c29ff2453bf38c75ee8982935739103c38a9284 tip-rev=7
  550bb31f072912453ccbb503de1d554616911e88 o default
#endif

Even when computing branches from scratch

  $ rm -rf .hg/cache/branch*
  $ rm -rf .hg/wcache/branch*
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  7c29ff2453bf38c75ee8982935739103c38a9284 7 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f1456c0d675980582dda9b8edc7f13f503ce544f obsolete-hash=3e74f5349008671629e39d13d7e00d9ba94c74f7 tip-node=7c29ff2453bf38c75ee8982935739103c38a9284 tip-rev=7
  550bb31f072912453ccbb503de1d554616911e88 o default
#endif

And we can get back to normal

  $ hg update null --quiet
  $ hg heads -T '{desc}\n'
  A_3
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  7c29ff2453bf38c75ee8982935739103c38a9284 7 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f8006d64a10d35c011a5c5fa88be1e25c5929514 tip-node=7c29ff2453bf38c75ee8982935739103c38a9284 tip-rev=7 topo-mode=pure
  default
#endif

  $ cd ..
  $ rm -rf tmp-repo

Getting the obsolescence marker after the fact for the tip rev
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  $ cp -R ./main-single-branch-pre-ops tmp-repo
  $ cd tmp-repo
  $ hg update --hidden --rev 'desc("A_4")' --quiet
  $ hg log -G -T '{desc}\n'
  @  A_4
  |
  o  A_3
  |
  | o  B_4
  | |
  | o  B_3
  | |
  | o  B_2
  | |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  
  $ hg heads -T '{desc}\n'
  A_4
  B_4
  $ hg pull --rev `cat ../main-single-branch-node_A4` --remote-hidden
  pulling from $TESTTMP/main-single-branch
  no changes found
  1 new obsolescence markers
  obsoleted 1 changesets

branch head are okay

  $ hg heads -T '{desc}\n'
  A_3
  B_4
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 ac5282439f301518f362f37547fcd52bcc670373
  63ba7cd843d1e95aac1a24435befeb1909c53619 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  obsolete-hash=ac5282439f301518f362f37547fcd52bcc670373 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#endif

Even when computing branches from scratch

  $ rm -rf .hg/cache/branch*
  $ rm -rf .hg/wcache/branch*
  $ hg heads -T '{desc}\n'
  A_3
  B_4
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 ac5282439f301518f362f37547fcd52bcc670373
  63ba7cd843d1e95aac1a24435befeb1909c53619 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  obsolete-hash=ac5282439f301518f362f37547fcd52bcc670373 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#endif

And we can get back to normal

  $ hg update null --quiet
  $ hg heads -T '{desc}\n'
  A_3
  B_4
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  7c29ff2453bf38c75ee8982935739103c38a9284 7
  63ba7cd843d1e95aac1a24435befeb1909c53619 o default
  7c29ff2453bf38c75ee8982935739103c38a9284 o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  tip-node=7c29ff2453bf38c75ee8982935739103c38a9284 tip-rev=7 topo-mode=pure
  default
#endif

  $ cd ..
  $ rm -rf tmp-repo

Getting the obsolescence marker after the fact for another rev
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  $ cp -R ./main-single-branch-pre-ops tmp-repo
  $ cd tmp-repo
  $ hg update --hidden --rev 'desc("B_3")' --quiet
  $ hg log -G -T '{desc}\n'
  o  A_4
  |
  o  A_3
  |
  | o  B_4
  | |
  | @  B_3
  | |
  | o  B_2
  | |
  | o  B_1
  |/
  o  A_2
  |
  o  A_1
  |
  o  root
  
  $ hg heads -T '{desc}\n'
  A_4
  B_4
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8
  63ba7cd843d1e95aac1a24435befeb1909c53619 o default
  3d808bbc94408ea19da905596d4079357a1f28be o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8 topo-mode=pure
  default
#endif

  $ hg pull --rev `cat ../main-single-branch-node_B4` --remote-hidden
  pulling from $TESTTMP/main-single-branch
  no changes found
  3 new obsolescence markers
  obsoleted 3 changesets

branch head are okay

  $ hg heads -T '{desc}\n'
  A_4
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  3d808bbc94408ea19da905596d4079357a1f28be o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f1456c0d675980582dda9b8edc7f13f503ce544f obsolete-hash=3e74f5349008671629e39d13d7e00d9ba94c74f7 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  550bb31f072912453ccbb503de1d554616911e88 o default
#endif

Even when computing branches from scratch

  $ rm -rf .hg/cache/branch*
  $ rm -rf .hg/wcache/branch*
  $ hg heads -T '{desc}\n'
  A_4
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  3d808bbc94408ea19da905596d4079357a1f28be o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f1456c0d675980582dda9b8edc7f13f503ce544f obsolete-hash=3e74f5349008671629e39d13d7e00d9ba94c74f7 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8
  550bb31f072912453ccbb503de1d554616911e88 o default
#endif

And we can get back to normal

  $ hg update null --quiet
  $ hg heads -T '{desc}\n'
  A_4
  B_1
#if v2
  $ show_cache
  ##### .hg/cache/branch2-served
  3d808bbc94408ea19da905596d4079357a1f28be 8 f8006d64a10d35c011a5c5fa88be1e25c5929514
  550bb31f072912453ccbb503de1d554616911e88 o default
  3d808bbc94408ea19da905596d4079357a1f28be o default
#else
  $ show_cache
  ##### .hg/cache/branch3-exp-served
  filtered-hash=f8006d64a10d35c011a5c5fa88be1e25c5929514 tip-node=3d808bbc94408ea19da905596d4079357a1f28be tip-rev=8 topo-mode=pure
  default
#endif

  $ cd ..
  $ rm -rf tmp-repo
