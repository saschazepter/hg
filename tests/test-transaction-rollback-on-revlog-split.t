Test correctness of revlog inline -> non-inline transition
----------------------------------------------------------

Helper extension to intercept renames and kill process

  $ cat > $TESTTMP/intercept_before_rename.py << EOF
  > import os
  > import signal
  > from mercurial import extensions, util
  > 
  > def extsetup(ui):
  >     def close(orig, *args, **kwargs):
  >         path = util.normpath(args[0]._atomictempfile__name)
  >         if path.endswith(b'/.hg/store/data/file.i'):
  >             os.kill(os.getpid(), signal.SIGKILL)
  >         return orig(*args, **kwargs)
  >     extensions.wrapfunction(util.atomictempfile, 'close', close)
  > EOF

  $ cat > $TESTTMP/intercept_after_rename.py << EOF
  > import os
  > import signal
  > from mercurial import extensions, util
  > 
  > def extsetup(ui):
  >     def close(orig, *args, **kwargs):
  >         path = util.normpath(args[0]._atomictempfile__name)
  >         r = orig(*args, **kwargs)
  >         if path.endswith(b'/.hg/store/data/file.i'):
  >             os.kill(os.getpid(), signal.SIGKILL)
  >         return r
  >     extensions.wrapfunction(util.atomictempfile, 'close', close)
  > EOF

  $ cat > $TESTTMP/killme.py << EOF
  > import os
  > import signal
  > 
  > def killme(ui, repo, hooktype, **kwargs):
  >     os.kill(os.getpid(), signal.SIGKILL)
  > EOF

  $ cat > $TESTTMP/reader_wait_split.py << EOF
  > import os
  > import signal
  > from mercurial import extensions, revlog, testing
  > def _wait_post_load(orig, self, *args, **kwargs):
  >     wait = b'data/file' in self.radix
  >     if wait:
  >         testing.wait_file(b"$TESTTMP/writer-revlog-split")
  >     r = orig(self, *args, **kwargs)
  >     if wait:
  >         testing.write_file(b"$TESTTMP/reader-index-read")
  >         testing.wait_file(b"$TESTTMP/writer-revlog-unsplit")
  >     return r
  > 
  > def extsetup(ui):
  >     extensions.wrapfunction(revlog.revlog, '_loadindex', _wait_post_load)
  > EOF

setup a repository for tests
----------------------------

  $ cat >> $HGRCPATH << EOF
  > [format]
  > revlog-compression=none
  > EOF

  $ hg init troffset-computation
  $ cd troffset-computation
  $ printf '%20d' '1' > file
  $ hg commit -Aqma
  $ printf '%1024d' '1' > file
  $ hg commit -Aqmb
  $ printf '%20d' '1' > file
  $ hg commit -Aqmc
  $ dd if=/dev/zero of=file bs=1k count=128 > /dev/null 2>&1
  $ hg commit -AqmD

Reference size:
  $ f -s file
  file: size=131072
  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=132139
  .hg/store/data/file.i: size=256

  $ cd ..


Test a hard crash after the file was split but before the transaction was committed
===================================================================================

Test offset computation to correctly factor in the index entries themselves.
Also test that the new data size has the correct size if the transaction is aborted
after the index has been replaced.

Test repo has commits a, b, c, D, where D is large (grows the revlog enough that it
transitions to non-inline storage). The clone initially has changes a, b
and will transition to non-inline storage when adding c, D.

If the transaction adding c, D is rolled back, then we don't undo the revlog split,
but truncate the index and the data to remove both c and D.


  $ hg clone --quiet --rev 1 troffset-computation troffset-computation-copy
  $ cd troffset-computation-copy

Reference size:
  $ f -s file
  file: size=1024
  $ f -s .hg/store/data/file*
  .hg/store/data/file.i: size=1174

  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > pretxnchangegroup = python:$TESTTMP/killme.py:killme
  > EOF
#if chg
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  [255]
#else
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  Killed
  [137]
#endif


The revlog have been split on disk

  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=132139
  .hg/store/data/file.i: size=256

  $ cat .hg/store/journal | tr -s '\000' ' ' | grep data/file | tail -1
  data/file.i 128

The first file.i entry should match the "Reference size" above.
The first file.d entry is the temporary record during the split,

The second entry after the split happened. The sum of the second file.d
and the second file.i entry should match the first file.i entry.

  $ cat .hg/store/journal | tr -s '\000' ' ' | grep data/file
  data/file.i 1174
  data/file.d 0
  data/file.d 1046
  data/file.i 128
  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)
  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=1046
  .hg/store/data/file.i: size=128
  $ hg tip
  changeset:   1:cfa8d6e60429
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  $ hg verify -q
   warning: revlog 'data/file.d' not in fncache!
  1 warnings encountered!
  hint: run "hg debugrebuildfncache" to recover from corrupt fncache
  $ hg debugrebuildfncache --only-data
  adding data/file.d
  1 items added, 0 removed from fncache
  $ hg verify -q
  $ cd ..

Test a hard crash right before the index is move into place
===========================================================

Now retry the procedure but intercept the rename of the index and check that
the journal does not contain the new index size. This demonstrates the edge case
where the data file is left as garbage.

  $ hg clone --quiet --rev 1 troffset-computation troffset-computation-copy2
  $ cd troffset-computation-copy2

Reference size:
  $ f -s file
  file: size=1024
  $ f -s .hg/store/data/file*
  .hg/store/data/file.i: size=1174

  $ cat > .hg/hgrc <<EOF
  > [extensions]
  > intercept_rename = $TESTTMP/intercept_before_rename.py
  > [hooks]
  > pretxnchangegroup = python:$TESTTMP/killme.py:killme
  > EOF
#if chg
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  [255]
#else
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  Killed
  [137]
#endif

The data file is created, but the revlog is still inline

  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=132139
  .hg/store/data/file.i: size=132395

  $ cat .hg/store/journal | tr -s '\000' ' ' | grep data/file
  data/file.i 1174
  data/file.d 0
  data/file.d 1046

  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)
  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=1046
  .hg/store/data/file.i: size=1174
  $ hg tip
  changeset:   1:cfa8d6e60429
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  $ hg verify -q
  $ cd ..

Test a hard crash right after the index is move into place
===========================================================

Now retry the procedure but intercept the rename of the index.

Things get corrupted /o\

  $ hg clone --quiet --rev 1 troffset-computation troffset-computation-crash-after-rename
  $ cd troffset-computation-crash-after-rename

Reference size:
  $ f -s file
  file: size=1024
  $ f -s .hg/store/data/file*
  .hg/store/data/file.i: size=1174

  $ cat > .hg/hgrc <<EOF
  > [extensions]
  > intercept_rename = $TESTTMP/intercept_after_rename.py
  > [hooks]
  > pretxnchangegroup = python:$TESTTMP/killme.py:killme
  > EOF
#if chg
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  [255]
#else
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  Killed
  [137]
#endif

the revlog has been split on disk

  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=132139
  .hg/store/data/file.i: size=256

  $ cat .hg/store/journal | tr -s '\000' ' ' | grep data/file
  data/file.i 1174
  data/file.d 0
  data/file.d 1046

  $ hg recover
  rolling back interrupted transaction
  abort: attempted to truncate data/file.i to 1174 bytes, but it was already 256 bytes
  
  [255]
  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=1046
  .hg/store/data/file.i: size=256
  $ hg tip
  changeset:   1:cfa8d6e60429
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  $ hg verify -q
  abandoned transaction found - run hg recover
   warning: revlog 'data/file.d' not in fncache!
   file@0: data length off by -131093 bytes
   file@2: unpacking fa1120531cc1: partial read of revlog data/file.d; expected 21 bytes from offset 1046, got 0
   file@3: unpacking a631378adaa3: partial read of revlog data/file.d; expected 131072 bytes from offset 1067, got -21
   file@?: rev 2 points to nonexistent changeset 2
   (expected )
   file@?: fa1120531cc1 not in manifests
   file@?: rev 3 points to nonexistent changeset 3
   (expected )
   file@?: a631378adaa3 not in manifests
  not checking dirstate because of previous errors
  3 warnings encountered!
  hint: run "hg debugrebuildfncache" to recover from corrupt fncache
  7 integrity errors encountered!
  (first damaged changeset appears to be 0)
  [1]
  $ cd ..

Have the transaction rollback itself without any hard crash
===========================================================


Repeat the original test but let hg rollback the transaction.

  $ hg clone --quiet --rev 1 troffset-computation troffset-computation-copy-rb
  $ cd troffset-computation-copy-rb
  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > pretxnchangegroup = false
  > EOF
  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  transaction abort!
  rollback completed
  abort: pretxnchangegroup hook exited with status 1
  [40]

File are still split on disk, with the expected size.

  $ f -s .hg/store/data/file*
  .hg/store/data/file.d: size=1046
  .hg/store/data/file.i: size=128

  $ hg tip
  changeset:   1:cfa8d6e60429
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  $ hg verify -q
   warning: revlog 'data/file.d' not in fncache!
  1 warnings encountered!
  hint: run "hg debugrebuildfncache" to recover from corrupt fncache
  $ cd ..

Read race
=========

We check that a client that started reading a revlog (its index) after the
split and end reading (the data) after the rollback should be fine

  $ hg clone --quiet --rev 1 troffset-computation troffset-computation-race
  $ cd troffset-computation-race
  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > pretxnchangegroup=$RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/reader-index-read $TESTTMP/writer-revlog-split
  > pretxnclose = false
  > EOF

start a reader

  $ hg cat --rev 0 file \
  > --config "extensions.wait_read=$TESTTMP/reader_wait_split.py" \
  > 2> $TESTTMP/reader.stderr \
  > > $TESTTMP/reader.stdout &

Do a failed pull in //

  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  transaction abort!
  rollback completed
  abort: pretxnclose hook exited with status 1
  [40]
  $ touch $TESTTMP/writer-revlog-unsplit
  $ wait

The reader should be fine
  $ cat $TESTTMP/reader.stderr
  $ cat $TESTTMP/reader.stdout
                     1 (no-eol)
  $ cd ..

pending hooks
=============

We checks that hooks properly see the inside of the transaction, while other process don't.

  $ hg clone --quiet --rev 1 troffset-computation troffset-computation-hooks
  $ cd troffset-computation-hooks
  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > pretxnclose.01-echo = hg cat -r 'max(all())' file | f --size
  > pretxnclose.02-echo = $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/hook-done $TESTTMP/hook-tr-ready
  > pretxnclose.03-abort = false
  > EOF

  $ (
  >   $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/hook-tr-ready;\
  >   hg cat -r 'max(all())' file | f --size;\
  >   touch $TESTTMP/hook-done
  > ) >stdout 2>stderr &

  $ hg pull ../troffset-computation
  pulling from ../troffset-computation
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  size=131072
  transaction abort!
  rollback completed
  abort: pretxnclose.03-abort hook exited with status 1
  [40]

  $ cat stdout
  size=1024
  $ cat stderr


  $ cd ..
