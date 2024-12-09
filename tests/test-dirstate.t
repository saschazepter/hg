#testcases dirstate-v1 dirstate-v2

#if dirstate-v2
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=1
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF
#endif

------ Test dirstate._dirs refcounting

  $ hg init t
  $ cd t
  $ mkdir -p a/b/c/d
  $ touch a/b/c/d/x
  $ touch a/b/c/d/y
  $ touch a/b/c/d/z
  $ hg ci -Am m
  adding a/b/c/d/x
  adding a/b/c/d/y
  adding a/b/c/d/z
  $ hg mv a z
  moving a/b/c/d/x to z/b/c/d/x
  moving a/b/c/d/y to z/b/c/d/y
  moving a/b/c/d/z to z/b/c/d/z

Test name collisions

  $ rm z/b/c/d/x
  $ mkdir z/b/c/d/x
  $ touch z/b/c/d/x/y
  $ hg add z/b/c/d/x/y
  abort: file 'z/b/c/d/x' in dirstate clashes with 'z/b/c/d/x/y'
  [255]
  $ rm -rf z/b/c/d
  $ touch z/b/c/d
  $ hg add z/b/c/d
  abort: directory 'z/b/c/d' already in dirstate
  [255]

  $ cd ..

Issue1790: dirstate entry locked into unset if file mtime is set into
the future

Prepare test repo:

  $ hg init u
  $ cd u
  $ echo a > a
  $ hg add
  adding a
  $ hg ci -m1

Set mtime of a into the future:

  $ touch -t 203101011200 a

Status must not set a's entry to unset (issue1790):

  $ hg status
  $ hg debugstate
  n 644          2 2031-01-01 12:00:00 a

Check that .hg/dirstate permissions are correct
(there was a bug where rust atomic replace would set permissions 0600,
which is not what we want)

#if unix-permissions
  $ f --mode .hg/dirstate
  .hg/dirstate: mode=644
#endif

Test modulo storage/comparison of absurd dates:

#if no-aix
  $ touch -t 195001011200 a
  $ hg st
  $ hg debugstate
  n 644          2 2018-01-19 15:14:08 a
#endif

Verify that exceptions during a dirstate change leave the dirstate
coherent (issue4353)

  $ cat > ../dirstateexception.py <<EOF
  > from mercurial import (
  >   error,
  >   extensions,
  >   mergestate as mergestatemod,
  > )
  > 
  > def wraprecordupdates(*args):
  >     raise error.Abort(b"simulated error while recording dirstateupdates")
  > 
  > def reposetup(ui, repo):
  >     extensions.wrapfunction(mergestatemod, 'recordupdates',
  >                             wraprecordupdates)
  > EOF

  $ hg rm a
  $ hg commit -m 'rm a'
  $ echo "[extensions]" >> .hg/hgrc
  $ echo "dirstateex=../dirstateexception.py" >> .hg/hgrc
  $ hg up 0
  abort: simulated error while recording dirstateupdates
  [255]
  $ hg log -r . -T '{rev}\n'
  1
  $ hg status
  ? a

#if dirstate-v2
Check that folders that are prefixes of others do not throw the packer into an
infinite loop.

  $ cd ..
  $ hg init infinite-loop
  $ cd infinite-loop
  $ mkdir hgext3rd hgext
  $ touch hgext3rd/__init__.py hgext/zeroconf.py
  $ hg commit -Aqm0

  $ hg st -c
  C hgext/zeroconf.py
  C hgext3rd/__init__.py

  $ cd ..

Check that the old dirstate data file is removed correctly and the new one is
valid.

  $ dirstate_data_files () {
  >   find .hg -maxdepth 1 -name "dirstate.*"
  > }

  $ find_dirstate_uuid () {
  >   hg debugstate --docket | grep uuid | sed 's/.*uuid: \(.*\)/\1/'
  > }

  $ find_dirstate_data_size () {
  >   hg debugstate --docket | grep 'size of dirstate data' | sed 's/.*size of dirstate data: \(.*\)/\1/'
  > }

  $ dirstate_uuid_has_not_changed () {
  >   # Non-Rust always rewrites the whole dirstate
  >   if [ $# -eq 1 ] || ([ -n "$HGMODULEPOLICY" ] && [ -z "${HGMODULEPOLICY##*rust*}" ]) || [ -n "$RHG_INSTALLED_AS_HG" ]; then
  >     test $current_uid = $(find_dirstate_uuid)
  >   else
  >     echo "not testing because using Python implementation"
  >   fi
  > }

  $ cd ..
  $ hg init append-mostly
  $ cd append-mostly
  $ mkdir dir dir2
  $ touch -t 200001010000 dir/a dir/b dir/c dir/d dir/e dir2/f dir dir2
  $ hg commit -Aqm initial
  $ hg st
  $ dirstate_data_files | wc -l
   *1 (re)
  $ current_uid=$(find_dirstate_uuid)

Nothing changes here

  $ hg st
  $ dirstate_data_files | wc -l
   *1 (re)
  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation (no-rust no-rhg !)

Trigger an append with a small change to directory mtime

  $ current_data_size=$(find_dirstate_data_size)
  $ touch -t 201001010000 dir2
  $ hg st
  $ dirstate_data_files | wc -l
   *1 (re)
  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation (no-rust no-rhg !)
  $ new_data_size=$(find_dirstate_data_size)
  $ [ "$current_data_size" -eq "$new_data_size" ]; echo $?
  0 (no-rust no-rhg !)
  1 (rust !)
  1 (no-rust rhg !)

Unused bytes counter is non-0 when appending
  $ touch file
  $ hg add file
  $ current_uid=$(find_dirstate_uuid)

Trigger a rust/rhg run which updates the unused bytes value
  $ hg st
  A file
  $ dirstate_data_files | wc -l
   *1 (re)
  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation (no-rust no-rhg !)

  $ hg debugstate --docket | grep unused
  number of unused bytes: 0 (no-rust no-rhg !)
  number of unused bytes: [1-9]\d* (re) (rhg no-rust !)
  number of unused bytes: [1-9]\d* (re) (rust no-rhg !)
  number of unused bytes: [1-9]\d* (re) (rust rhg !)

Delete most of the dirstate to trigger a non-append
  $ hg rm dir/a dir/b dir/c dir/d
  $ dirstate_data_files | wc -l
   *1 (re)
  $ dirstate_uuid_has_not_changed also-if-python
  [1]

Check that unused bytes counter is reset when creating a new docket

  $ hg debugstate --docket | grep unused
  number of unused bytes: 0

#endif

(non-Rust always rewrites)

Test the devel option to control write behavior
==============================================

Sometimes, debugging or testing the dirstate requires making sure that we have
done a complete rewrite of the data file and have no unreachable data around,
sometimes it requires we ensure we don't.

We test the option to force this rewrite by creating the situation where an
append would happen and check that it doesn't happen.

  $ cd ..
  $ hg init force-base
  $ cd force-base
  $ mkdir -p dir/nested dir2
  $ touch -t 200001010000 f dir/nested/a dir/b dir/c dir/d dir2/e dir/nested dir dir2
  $ hg commit -Aqm "recreate a bunch of files to facilitate append"
  $ hg st --config devel.dirstate.v2.data_update_mode=force-new
  $ cd ..

#if dirstate-v2
  $ hg -R force-base debugstate --docket | grep unused
  number of unused bytes: 0

Check with the option in "auto" mode
------------------------------------
  $ cp -a force-base append-mostly-no-force-rewrite
  $ cd append-mostly-no-force-rewrite
  $ current_uid=$(find_dirstate_uuid)

Change mtime of dir on disk which will be recorded, causing a small enough change
to warrant only an append

  $ touch -t 202212010000 dir2
  $ hg st \
  > --config rhg.on-unsupported=abort \
  > --config devel.dirstate.v2.data_update_mode=auto

UUID hasn't changed and a non-zero number of unused bytes means we've appended

  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation (no-rust no-rhg !)

#if no-rust no-rhg
The pure python implementation never appends at the time this is written.
  $ hg debugstate --docket | grep unused
  number of unused bytes: 0 (known-bad-output !)
#else
  $ hg debugstate --docket | grep unused
  number of unused bytes: [1-9]\d* (re)
#endif
  $ cd ..

Check the same scenario with the option set to "force-new"
---------------------------------------------------------

  $ cp -a force-base append-mostly-force-rewrite
  $ cd append-mostly-force-rewrite
  $ current_uid=$(find_dirstate_uuid)

Change mtime of dir on disk which will be recorded, causing a small enough change
to warrant only an append, but we force the rewrite

  $ touch -t 202212010000 dir2
  $ hg st \
  > --config rhg.on-unsupported=abort \
  > --config devel.dirstate.v2.data_update_mode=force-new

UUID has changed and zero unused bytes means a full-rewrite happened


#if no-rust no-rhg
  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation
#else
  $ dirstate_uuid_has_not_changed
  [1]
#endif
  $ hg debugstate --docket | grep unused
  number of unused bytes: 0
  $ cd ..


Check the same scenario with the option set to "force-append"
-------------------------------------------------------------

(should behave the same as "auto" here)

  $ cp -a force-base append-mostly-force-append
  $ cd append-mostly-force-append
  $ current_uid=$(find_dirstate_uuid)

Change mtime of dir on disk which will be recorded, causing a small enough change
to warrant only an append, which we are forcing here anyway.

  $ touch -t 202212010000 dir2
  $ hg st \
  > --config rhg.on-unsupported=abort \
  > --config devel.dirstate.v2.data_update_mode=force-append

UUID has not changed and some unused bytes exist in the data file

  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation (no-rust no-rhg !)

#if no-rust no-rhg
The pure python implementation never appends at the time this is written.
  $ hg debugstate --docket | grep unused
  number of unused bytes: 0 (known-bad-output !)
#else
  $ hg debugstate --docket | grep unused
  number of unused bytes: [1-9]\d* (re)
#endif
  $ cd ..

Check with the option in "auto" mode
------------------------------------
  $ cp -a force-base append-mostly-no-force-rewrite
  $ cd append-mostly-no-force-rewrite
  $ current_uid=$(find_dirstate_uuid)

Change mtime of everything on disk causing a full rewrite

  $ touch -t 202212010005 `hg files`
  $ hg st \
  > --config rhg.on-unsupported=abort \
  > --config devel.dirstate.v2.data_update_mode=auto

UUID has changed and zero unused bytes means we've rewritten.

#if no-rust no-rhg
  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation
#else
  $ dirstate_uuid_has_not_changed
  [1]
#endif

  $ hg debugstate --docket | grep unused
  number of unused bytes: 0 (known-bad-output !)
  $ cd ..

Check the same scenario with the option set to "force-new"
---------------------------------------------------------

(should be the same as auto)

  $ cp -a force-base append-mostly-force-rewrite
  $ cd append-mostly-force-rewrite
  $ current_uid=$(find_dirstate_uuid)

Change mtime of everything on disk causing a full rewrite

  $ touch -t 202212010005 `hg files`
  $ hg st \
  > --config rhg.on-unsupported=abort \
  > --config devel.dirstate.v2.data_update_mode=force-new

UUID has changed and a zero number unused bytes means we've rewritten.


#if no-rust no-rhg
  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation
#else
  $ dirstate_uuid_has_not_changed
  [1]
#endif
  $ hg debugstate --docket | grep unused
  number of unused bytes: 0
  $ cd ..


Check the same scenario with the option set to "force-append"
-------------------------------------------------------------

Should append even if "auto" did not

  $ cp -a force-base append-mostly-force-append
  $ cd append-mostly-force-append
  $ current_uid=$(find_dirstate_uuid)

Change mtime of everything on disk causing a full rewrite

  $ touch -t 202212010005 `hg files`
  $ hg st \
  > --config rhg.on-unsupported=abort \
  > --config devel.dirstate.v2.data_update_mode=force-append

UUID has not changed and some unused bytes exist in the data file

  $ dirstate_uuid_has_not_changed
  not testing because using Python implementation (no-rust no-rhg !)

#if no-rust no-rhg
The pure python implementation is never appending at the time this is written.
  $ hg debugstate --docket | grep unused
  number of unused bytes: 0 (known-bad-output !)
#else
  $ hg debugstate --docket | grep unused
  number of unused bytes: [1-9]\d* (re)
#endif
  $ cd ..



Get back into a state suitable for the test of the file.

  $ cd ./append-mostly

#else
  $ cd ./u
#endif

Transaction compatibility
=========================

The transaction preserves the dirstate.
We should make sure all of it (docket + data) is preserved

#if dirstate-v2
  $ hg commit -m 'bli'
#endif

  $ hg update --quiet
  $ hg revert --all --quiet
  $ rm -f a
  $ echo foo > foo
  $ hg add foo
  $ hg commit -m foo

#if dirstate-v2
  $ uid=$(find_dirstate_uuid)
  $ touch bar
  $ while [ uid = $(find_dirstate_uuid) ]; do
  >    hg add bar;
  >    hg remove bar;
  > done;
  $ rm bar
#endif
  $ hg rollback
  repository tip rolled back to revision 1 (undo commit)
  working directory now based on revision 1

  $ hg status
  A foo
  $ cd ..

Check dirstate ordering
(e.g. `src/dirstate/` and `src/dirstate.rs` shouldn't cause issues)

  $ hg init repro
  $ cd repro
  $ mkdir src
  $ mkdir src/dirstate
  $ touch src/dirstate/file1 src/dirstate/file2 src/dirstate.rs
  $ touch file1 file2
  $ hg commit -Aqm1
  $ hg st
  $ cd ..
