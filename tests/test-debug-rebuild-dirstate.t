#require rust

  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=1
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF

  $ hg init t
  $ cd t

  $ for i in 1 2 3 4 5 6 7 8 9 10; do touch foobar$i; done
  $ hg add .
  adding foobar1
  adding foobar10
  adding foobar2
  adding foobar3
  adding foobar4
  adding foobar5
  adding foobar6
  adding foobar7
  adding foobar8
  adding foobar9
  $ hg commit -m "1"

Check that there's no space leak on debugrebuilddirstate

  $ f --size .hg/dirstate*
  .hg/dirstate: size=133
  .hg/dirstate.88698448: size=511
  $ hg debugrebuilddirstate
  $ f --size .hg/dirstate*
  .hg/dirstate: size=133
  .hg/dirstate.6b8ab34b: size=511
  $ hg debugrebuilddirstate
  $ f --size .hg/dirstate*
  .hg/dirstate: size=133
  .hg/dirstate.b875dfc5: size=511
