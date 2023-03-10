#testcases dirstate-v1 dirstate-v2

#if dirstate-v2
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=1
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF
#endif

The proliferation of status implementations can be confusing:
- The pure python implementation:
(no-rhg pure !)
- The C implementation:
(no-rhg no-rust no-pure !)
- The two rust implementations:
(rhg !)
(no-rhg rust !)

  $ hg init repo1
  $ cd repo1
  $ mkdir d1
  $ touch d1/x
  $ hg commit -Am.
  adding d1/x
  $ touch d1/y
  $ chmod -r d1
  $ hg status
  d1: $EACCES$
  ! d1/x (rhg !)
  ! d1/x (no-rhg rust !)
  $ hg status
  d1: $EACCES$ (rhg dirstate-v1 !)
  d1: $EACCES$ (no-rhg rust dirstate-v1 !)
  d1: $EACCES$ (no-rust no-rhg !)
  ! d1/x (rust dirstate-v1 !)
  ! d1/x (no-rust rhg dirstate-v1 !)
  $ chmod +r d1
  $ hg status
  ? d1/y (rhg dirstate-v1 !)
  ? d1/y (no-rhg rust dirstate-v1 !)
  ? d1/y (no-rhg no-rust !)

TODO: make the tests marked with (dirstate-v1) above work the same way
with dirstate-v2 as well.

  $ touch d1/z
  $ hg status
  ? d1/y
  ? d1/z
