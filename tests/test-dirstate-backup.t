Set up

  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=true
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF

  $ hg init repo
  $ cd repo
  $ echo a > a
  $ hg add a
  $ hg commit -m a

Try to import an empty patch

  $ hg import --no-commit - <<EOF
  > EOF
  applying patch from stdin
  abort: stdin: no diffs found
  [10]

No dirstate backups are left behind

  $ ls .hg/dirstate* | sort
  .hg/dirstate
  .hg/dirstate.* (glob) (dirstate-v2 !)

  $ cd ..

Transaction undo doesn't leave garbage dirstate .bck files around:

  $ hg share --config extensions.share= repo +share1+ -q
  $ hg share --config extensions.share= repo +share2+ -q

  $ c() {
  >   echo "$1" >> x;
  >   hg commit x -qAmx --config devel.dirstate.v2.data_update_mode=force-new;
  >   ls .hg/undo.*dirstate* | wc -l | grep -o '[0-9]*';
  > }
  $ c1() { (cd +share1+; c "$@"); }
  $ c2() { (cd +share2+; c "$@"); }
  $ c1 a
  3
  $ c2 b
  3
  $ c1 c
  3
  $ c2 d
  3
  $ c1 e
  3
  $ c2 f
  3
