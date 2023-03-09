  $ cat >> $HGRCPATH <<EOF
  > [experimental]
  > bundle-phases=yes
  > [extensions]
  > strip=
  > drawdag=$TESTDIR/drawdag.py
  > EOF

Set up repo with linear history
  $ hg init linear
  $ cd linear
  $ hg debugdrawdag <<'EOF'
  > E
  > |
  > D
  > |
  > C
  > |
  > B
  > |
  > A
  > EOF
  $ hg phase --public A
  $ hg phase --force --secret D
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  
  $ hg bundle --base B -r E bundle
  3 changesets found
  $ hg debugbundle bundle
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 3, targetphase: 2, version: 02} (mandatory: True)
      26805aba1e600a82e93661149f2313866a221a7b
      f585351a92f85104bff7c284233c338b10eb1df7
      9bc730a19041f9ec7cb33c626e811aa233efb18c
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      26805aba1e600a82e93661149f2313866a221a7b draft
      9bc730a19041f9ec7cb33c626e811aa233efb18c secret
  $ hg strip --no-backup C

Phases show on incoming, and are also restored when pulling.  Secret commits
aren't incoming or pulled, following usual incoming/pull semantics.

  $ hg log -R bundle -r 'bundle()^+bundle()' -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  ~

  $ hg incoming bundle -G -T '{desc} {phase}\n'
  comparing with bundle
  searching for changes
  o  C draft
  
  $ hg pull bundle
  pulling from bundle
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 26805aba1e60 (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg log -G -T '{desc} {phase}\n'
  o  C draft
  |
  o  B draft
  |
  o  A public
  
  $ hg log -R bundle -r 'bundle()^+bundle()' -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  ~

  $ hg rollback --config ui.rollback=1
  repository tip rolled back to revision 1 (undo pull)

Phases are restored when unbundling
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  
Root revision's phase is preserved
  $ hg bundle -a bundle
  5 changesets found
  $ hg strip --no-backup A
  $ hg unbundle -q bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  
  $ hg init empty
  $ hg -R empty pull bundle
  pulling from bundle
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 3 files
  new changesets 426bada5c675:26805aba1e60 (2 drafts)
  (run 'hg update' to get a working copy)
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  

Public repo commits take precedence over phases in the bundle
  $ hg phase --public E
  $ hg incoming bundle -G -T '{desc} {phase}\n'
  comparing with bundle
  searching for changes
  no changes found
  $ hg log -R bundle -r 'bundle()^+bundle()' -G -T '{desc} {phase}\n'
  o  E public
  |
  o  D public
  |
  o  C public
  |
  o  B public
  |
  o  A public
  
  $ hg pull bundle
  pulling from bundle
  searching for changes
  no changes found
  $ hg log -G -T '{desc} {phase}\n'
  o  E public
  |
  o  D public
  |
  o  C public
  |
  o  B public
  |
  o  A public
  
  $ rm bundle

A bundle with public phases that are not public in the repo will show as public
with `hg log`, but will remain not public in the plain repo.

  $ hg bundle --base B -r E bundle
  3 changesets found
  $ hg phase --force --draft -r C

  $ hg log -R bundle -G -T '{desc} {phase}\n'
  o  E public
  |
  o  D public
  |
  o  C public
  |
  o  B public
  |
  o  A public
  
  $ hg log -G -T '{desc} {phase}\n'
  o  E draft
  |
  o  D draft
  |
  o  C draft
  |
  o  B public
  |
  o  A public
  
  $ hg phase --public -r E
  $ rm bundle

Completely public history can be restored
  $ hg bundle -a bundle
  5 changesets found
  $ hg strip --no-backup A
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E public
  |
  o  D public
  |
  o  C public
  |
  o  B public
  |
  o  A public
  
Direct transition from public to secret can be restored
  $ hg phase --secret --force D
  $ hg bundle -a bundle
  5 changesets found
  $ hg strip --no-backup A
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C public
  |
  o  B public
  |
  o  A public
  
Revisions within bundle preserve their phase even if parent changes its phase
  $ hg phase --draft --force B
  $ hg bundle --base B -r E bundle
  3 changesets found
  $ hg strip --no-backup C
  $ hg phase --public B
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B public
  |
  o  A public
  
Phase of ancestors of stripped node get advanced to accommodate child
  $ hg bundle --base B -r E bundle
  3 changesets found
  $ hg strip --no-backup C
  $ hg phase --force --secret B
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E secret
  |
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  
Unbundling advances phases of changesets even if they were already in the repo.
To test that, create a bundle of everything in draft phase and then unbundle
to see that secret becomes draft, but public remains public.
  $ hg phase --draft --force A
  $ hg phase --draft E
  $ hg bundle -a bundle
  5 changesets found
  $ hg phase --public A
  $ hg phase --secret --force E
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  E draft
  |
  o  D draft
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  
Unbundling change in the middle of a stack does not affect later changes
  $ hg strip --no-backup E
  $ hg phase --secret --force D
  $ hg log -G -T '{desc} {phase}\n'
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  
  $ hg bundle --base A -r B bundle
  1 changesets found
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{desc} {phase}\n'
  o  D secret
  |
  o  C draft
  |
  o  B draft
  |
  o  A public
  

  $ cd ..

Set up repo with non-linear history
  $ hg init non-linear
  $ cd non-linear
  $ hg debugdrawdag <<'EOF'
  > D E
  > |\|
  > B C
  > |/
  > A
  > EOF
  $ hg phase --public C
  $ hg phase --force --secret B
  $ hg log -G -T '{node|short} {desc} {phase}\n'
  o  03ca77807e91 E draft
  |
  | o  4e4f9194f9f1 D secret
  |/|
  o |  dc0947a82db8 C public
  | |
  | o  112478962961 B secret
  |/
  o  426bada5c675 A public
  

Restore bundle of entire repo
  $ hg bundle -a bundle
  5 changesets found
  $ hg debugbundle bundle
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 5, targetphase: 2, version: 02} (mandatory: True)
      426bada5c67598ca65036d57d9e4b64b0c1ce7a0
      112478962961147124edd43549aedd1a335e44bf
      dc0947a82db884575bb76ea10ac97b08536bfa03
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4
      03ca77807e919db8807c3749086dc36fb478cac0
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      dc0947a82db884575bb76ea10ac97b08536bfa03 public
      03ca77807e919db8807c3749086dc36fb478cac0 draft
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4 secret
  $ hg strip --no-backup A
  $ hg unbundle -q bundle
  $ rm bundle
  $ hg log -G -T '{node|short} {desc} {phase}\n'
  o  03ca77807e91 E draft
  |
  | o  4e4f9194f9f1 D secret
  |/|
  o |  dc0947a82db8 C public
  | |
  | o  112478962961 B secret
  |/
  o  426bada5c675 A public
  

  $ hg bundle --base 'A + C' -r D bundle
  2 changesets found
  $ hg debugbundle bundle
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 2, targetphase: 2, version: 02} (mandatory: True)
      112478962961147124edd43549aedd1a335e44bf
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4 secret
  $ rm bundle

  $ hg bundle --base A -r D bundle
  3 changesets found
  $ hg debugbundle bundle
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 3, targetphase: 2, version: 02} (mandatory: True)
      112478962961147124edd43549aedd1a335e44bf
      dc0947a82db884575bb76ea10ac97b08536bfa03
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      dc0947a82db884575bb76ea10ac97b08536bfa03 public
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4 secret
  $ rm bundle

  $ hg bundle --base 'B + C' -r 'D + E' bundle
  2 changesets found
  $ hg debugbundle bundle
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 2, targetphase: 2, version: 02} (mandatory: True)
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4
      03ca77807e919db8807c3749086dc36fb478cac0
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      03ca77807e919db8807c3749086dc36fb478cac0 draft
      4e4f9194f9f181c57f62e823e8bdfa46ab9e4ff4 secret
  $ rm bundle
