  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > absorb=
  > drawdag=$TESTDIR/drawdag.py
  > EOF

  $ hg init
  $ hg debugdrawdag <<'EOS'
  > C
  > |
  > B
  > |
  > A
  > EOS

  $ hg phase -r A --public -q
  $ hg phase -r C --secret --force -q

  $ hg update C -q
  $ printf B1 > B

  $ hg absorb -aq

  $ hg log -G -T '{desc} {phase}'
  @  C secret
  |
  o  B draft
  |
  o  A public
  
