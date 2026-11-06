
  $ cat > adddrop.py <<EOF
  > from mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'debugadddrop',
  >   [(b'', b'drop', False, b'drop file from dirstate', b'FILE'),
  >    (b'', b'normal-lookup', False, b'add file to dirstate', b'FILE')],
  >     b'hg debugadddrop')
  > def debugadddrop(ui, repo, *pats, **opts):
  >   '''Add or drop unnamed arguments to or from the dirstate'''
  >   drop = opts.get('drop')
  >   nl = opts.get('normal_lookup')
  >   if nl and drop:
  >       raise error.Abort('drop and normal-lookup are mutually exclusive')
  >   wlock = repo.wlock()
  >   try:
  >     for file in pats:
  >       if opts.get('normal_lookup'):
  >         with repo.dirstate.changing_parents(repo):
  >             repo.dirstate.update_file(
  >                 file,
  >                 p1_tracked=True,
  >                 wc_tracked=True,
  >                 possibly_dirty=True,
  >             )
  >       else:
  >         repo.dirstate._map.reset_state(file)
  >         repo.dirstate._dirty = True
  > 
  >     repo.dirstate.write(repo.currenttransaction())
  >   finally:
  >     wlock.release()
  > EOF

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "debugadddrop=`pwd`/adddrop.py" >> $HGRCPATH

basic test for hg debugrebuildstate

  $ hg init repo
  $ cd repo

The entries are read through a template, as `tracking mode size mtime path`:
the rebuild has to keep what status cached, `set` once an mtime is reliable.

  $ dirstate_entries() {
  >   hg debugdirstate --no-dates -T '{wc_tracked_str}{p1_tracked_str}{p2_info_str} {mode_str} {size_str} {mtime_str} {path}\n'
  > }

  $ touch foo bar
  $ hg ci -Am 'add foo bar'
  adding bar
  adding foo

  $ touch baz
  $ hg add baz
  $ hg rm bar

  $ hg debugrebuildstate

state dump after

  $ dirstate_entries | sort
  w1- - - - bar
  w1- - - - foo

  $ hg debugadddrop --normal-lookup file1 file2
  $ hg debugadddrop --drop bar
  $ hg debugadddrop --drop
  $ dirstate_entries
  w1- - - - file1
  w1- - - - file2
  w1- - - - foo
  $ hg debugrebuildstate

status

  $ hg st -A
  ! bar
  ? baz
  C foo

Test debugdirstate --minimal where a file is not in parent manifest
but in the dirstate
  $ touch foo bar qux
  $ hg add qux
  $ hg remove bar
  $ sleep 1 # remove potential ambiguity in mtime
  $ hg status -A
  A qux
  R bar
  ? baz
  C foo
  $ hg debugadddrop --normal-lookup baz
  $ dirstate_entries
  -1- - - - bar
  w1- - - - baz
  w1- 644 0 set foo
  w-- - - - qux
  $ hg debugrebuilddirstate --minimal
  $ dirstate_entries
  -1- - - - bar
  w1- 644 0 set foo
  w-- - - - qux
  $ hg status -A
  A qux
  R bar
  ? baz
  C foo

Test debugdirstate --minimal where file is in the parent manifest but not the
dirstate
  $ hg manifest
  bar
  foo
  $ sleep 1 # remove potential ambiguity in mtime
  $ hg status -A
  A qux
  R bar
  ? baz
  C foo
  $ dirstate_entries
  -1- - - - bar
  w1- 644 0 set foo
  w-- - - - qux
  $ hg debugadddrop --drop foo
  $ dirstate_entries
  -1- - - - bar
  w-- - - - qux
  $ hg debugrebuilddirstate --minimal
  $ dirstate_entries
  -1- - - - bar
  w1- - - - foo
  w-- - - - qux
  $ hg status -A
  A qux
  R bar
  ? baz
  C foo

