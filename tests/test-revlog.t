  $ hg init empty-repo
  $ cd empty-repo

Flags on revlog version 0 are rejected

  >>> with open('.hg/store/00changelog.i', 'wb') as fh:
  ...     fh.write(b'\x00\x01\x00\x00') and None

  $ hg log
  abort: unknown flags (0x01) in version 0 revlog 00changelog
  [50]

Unknown flags on revlog version 1 are rejected

  >>> with open('.hg/store/00changelog.i', 'wb') as fh:
  ...     fh.write(b'\x00\x04\x00\x01') and None

  $ hg log
  abort: unknown flags (0x04) in version 1 revlog 00changelog
  [50]

Unknown version is rejected

  >>> with open('.hg/store/00changelog.i', 'wb') as fh:
  ...     fh.write(b'\x00\x00\xbe\xef') and None

  $ hg log
  abort: unknown version (48879) in revlog 00changelog
  [50]

  $ cd ..

Test for CVE-2016-3630

  $ mkdir test2; cd test2
  $ hg init

  >>> import codecs
  >>> open("a.i", "wb").write(codecs.decode(codecs.decode(
  ... b"""eJxjYGZgZIAAYQYGxhgom+k/FMx8YKx9ZUaKSOyqo4cnuKb8mbqHV5cBCVTMWb1Cwqkhe4Gsg9AD
  ... Joa3dYtcYYYBAQ8Qr4OqZAYRICPTSr5WKd/42rV36d+8/VmrNpv7NP1jQAXrQE4BqQUARngwVA==""",
  ... "base64"), "zlib")) and None

  $ hg debugrevlogindex a.i
     rev linkrev nodeid       p1           p2
       0       2 99e0332bd498 000000000000 000000000000
       1       3 6674f57a23d8 99e0332bd498 000000000000

  >>> from mercurial.revlogutils.constants import KIND_OTHER
  >>> from mercurial import revlog, vfs
  >>> tvfs = vfs.vfs(b'.')
  >>> tvfs.options = {b'revlogv1': True}
  >>> rl = revlog.revlog(tvfs, target=(KIND_OTHER, b'test'), radix=b'a')
  >>> rl.revision(1)
  mpatchError(*'patch cannot be decoded'*) (glob)

  $ cd ..


Regression test for support for the old repos with strange diff encoding.
Apparently it used to be possible (maybe it's still possible, but we don't know how)
to create commits whose diffs are encoded relative to a nullrev.
This test checks that a repo with that encoding can still be read.

This is what we did to produce the repo in test-revlog-diff-relative-to-nullrev.tar:

- tweak the code in mercurial/revlogutils/deltas.py to produce such "trivial" deltas:
>          if deltainfo is None:
> -            deltainfo = self._fullsnapshotinfo(fh, revinfo, target_rev)
> +            deltainfo = self._builddeltainfo(revinfo, nullrev, fh)
- hg init
- echo hi > a
- hg commit -Am_
- remove some cache files

  $ tar -xf - < "$TESTDIR"/bundles/test-revlog-diff-relative-to-nullrev.tar
  $ cd nullrev-diff
  $ hg debugdeltachain a
      rev      p1      p2  chain# chainlen     prev   delta       size    rawsize  chainsize     ratio   lindist extradist extraratio   readsize largestblk rddensity srchunks
        0      -1      -1       1        2       -1      p1         15          3         15   5.00000        15         0    0.00000         15         15   1.00000        1
        1       0      -1       1        2       -1      p2         15          3         15   5.00000        30        15    1.00000         30         30   0.50000        1
        2      -1      -1       1        2       -1      p1         15          3         15   5.00000        45        30    2.00000         45         45   0.33333        1
  $ hg cat --config rhg.cat=true -r 0 a
  hi
  $ hg cat --config rhg.cat=true -r 1 a
  ho
  $ hg cat --config rhg.cat=true -r 2 a
  ha
  $ cd ..
