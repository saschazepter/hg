Tests for the journal extension; records bookmark locations.

  $ cat >> testmocks.py << EOF
  > # mock out procutil.getuser() and util.makedate() to supply testable values
  > import os
  > from mercurial import pycompat, util
  > from mercurial.utils import dateutil, procutil
  > def mockgetuser():
  >     return b'foobar'
  > 
  > def mockmakedate():
  >     filename = os.path.join(os.environ['TESTTMP'], 'testtime')
  >     try:
  >         with open(filename, 'rb') as timef:
  >             time = float(timef.read()) + 1
  >     except IOError:
  >         time = 0.0
  >     with open(filename, 'wb') as timef:
  >         timef.write(pycompat.bytestr(time))
  >     return (time, 0)
  > 
  > procutil.getuser = mockgetuser
  > dateutil.makedate = mockmakedate
  > EOF

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > journal=
  > testmocks=`pwd`/testmocks.py
  > EOF

Setup repo

  $ hg init repo
  $ cd repo

Test empty journal

  $ hg journal
  previous locations of '.':
  no recorded locations
  $ hg journal foo
  previous locations of 'foo':
  no recorded locations

Test that working copy changes are tracked

  $ echo a > a
  $ hg commit -Aqm a
  $ hg journal
  previous locations of '.':
  cb9a9f314b8b  commit -Aqm a
  $ echo b > a
  $ hg commit -Aqm b
  $ hg journal
  previous locations of '.':
  1e6c11564562  commit -Aqm b
  cb9a9f314b8b  commit -Aqm a
  $ hg up 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg journal
  previous locations of '.':
  cb9a9f314b8b  up 0
  1e6c11564562  commit -Aqm b
  cb9a9f314b8b  commit -Aqm a

Test that bookmarks are tracked

  $ hg book -r tip bar
  $ hg journal bar
  previous locations of 'bar':
  1e6c11564562  book -r tip bar
  $ hg book -f bar
  $ hg journal bar
  previous locations of 'bar':
  cb9a9f314b8b  book -f bar
  1e6c11564562  book -r tip bar
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating bookmark bar
  $ hg journal bar
  previous locations of 'bar':
  1e6c11564562  up
  cb9a9f314b8b  book -f bar
  1e6c11564562  book -r tip bar

Test that we tracks bookmark deletion

  $ hg book -r . babar
  $ hg book -f -r .~1 babar
  $ hg book -d babar
  $ hg journal babar
  previous locations of 'babar':
  000000000000  book -d babar
  cb9a9f314b8b  book -f -r ?.~1? babar (glob)
  1e6c11564562  book -r . babar

Test that bookmarks and working copy tracking is not mixed

  $ hg journal
  previous locations of '.':
  1e6c11564562  up
  cb9a9f314b8b  up 0
  1e6c11564562  commit -Aqm b
  cb9a9f314b8b  commit -Aqm a

Test that you can list all entries as well as limit the list or filter on them

  $ hg book -r tip baz
  $ hg journal --all
  previous locations of the working copy and bookmarks:
  1e6c11564562  baz       book -r tip baz
  000000000000  babar     book -d babar
  cb9a9f314b8b  babar     book -f -r ?.~1? babar (glob)
  1e6c11564562  babar     book -r . babar
  1e6c11564562  bar       up
  1e6c11564562  .         up
  cb9a9f314b8b  bar       book -f bar
  1e6c11564562  bar       book -r tip bar
  cb9a9f314b8b  .         up 0
  1e6c11564562  .         commit -Aqm b
  cb9a9f314b8b  .         commit -Aqm a
  $ hg journal --limit 2
  previous locations of '.':
  1e6c11564562  up
  cb9a9f314b8b  up 0
  $ hg journal bar
  previous locations of 'bar':
  1e6c11564562  up
  cb9a9f314b8b  book -f bar
  1e6c11564562  book -r tip bar
  $ hg journal foo
  previous locations of 'foo':
  no recorded locations
  $ hg journal .
  previous locations of '.':
  1e6c11564562  up
  cb9a9f314b8b  up 0
  1e6c11564562  commit -Aqm b
  cb9a9f314b8b  commit -Aqm a
  $ hg journal "re:ba."
  previous locations of 're:ba.':
  1e6c11564562  baz       book -r tip baz
  000000000000  babar     book -d babar
  cb9a9f314b8b  babar     book -f -r ?.~1? babar (glob)
  1e6c11564562  babar     book -r . babar
  1e6c11564562  bar       up
  cb9a9f314b8b  bar       book -f bar
  1e6c11564562  bar       book -r tip bar

Test that verbose, JSON, template and commit output work

  $ hg journal --verbose --all
  previous locations of the working copy and bookmarks:
  000000000000 -> 1e6c11564562 foobar    baz      1970-01-01 00:00 +0000  book -r tip baz
  cb9a9f314b8b -> 000000000000 foobar    babar    1970-01-01 00:00 +0000  book -d babar
  1e6c11564562 -> cb9a9f314b8b foobar    babar    1970-01-01 00:00 +0000  book -f -r ?.~1? babar (glob)
  000000000000 -> 1e6c11564562 foobar    babar    1970-01-01 00:00 +0000  book -r . babar
  cb9a9f314b8b -> 1e6c11564562 foobar    bar      1970-01-01 00:00 +0000  up
  cb9a9f314b8b -> 1e6c11564562 foobar    .        1970-01-01 00:00 +0000  up
  1e6c11564562 -> cb9a9f314b8b foobar    bar      1970-01-01 00:00 +0000  book -f bar
  000000000000 -> 1e6c11564562 foobar    bar      1970-01-01 00:00 +0000  book -r tip bar
  1e6c11564562 -> cb9a9f314b8b foobar    .        1970-01-01 00:00 +0000  up 0
  cb9a9f314b8b -> 1e6c11564562 foobar    .        1970-01-01 00:00 +0000  commit -Aqm b
  000000000000 -> cb9a9f314b8b foobar    .        1970-01-01 00:00 +0000  commit -Aqm a
  $ hg journal --verbose -Tjson
  [
   {
    "command": "up",
    "date": [5, 0],
    "name": ".",
    "newnodes": ["1e6c11564562b4ed919baca798bc4338bd299d6a"],
    "oldnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "user": "foobar"
   },
   {
    "command": "up 0",
    "date": [2, 0],
    "name": ".",
    "newnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "oldnodes": ["1e6c11564562b4ed919baca798bc4338bd299d6a"],
    "user": "foobar"
   },
   {
    "command": "commit -Aqm b",
    "date": [1, 0],
    "name": ".",
    "newnodes": ["1e6c11564562b4ed919baca798bc4338bd299d6a"],
    "oldnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "user": "foobar"
   },
   {
    "command": "commit -Aqm a",
    "date": [0, 0],
    "name": ".",
    "newnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "oldnodes": ["0000000000000000000000000000000000000000"],
    "user": "foobar"
   }
  ]

  $ cat <<EOF >> $HGRCPATH
  > [templates]
  > j = "{oldnodes % '{node|upper}'} -> {newnodes % '{node|upper}'}
  >      - user: {user}
  >      - command: {command}
  >      - date: {date|rfc3339date}
  >      - newnodes: {newnodes}
  >      - oldnodes: {oldnodes}
  >      "
  > EOF
  $ hg journal -Tj -l1
  previous locations of '.':
  CB9A9F314B8B07BA71012FCDBC544B5A4D82FF5B -> 1E6C11564562B4ED919BACA798BC4338BD299D6A
  - user: foobar
  - command: up
  - date: 1970-01-01T00:00:05+00:00
  - newnodes: 1e6c11564562b4ed919baca798bc4338bd299d6a
  - oldnodes: cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b

  $ hg journal --commit
  previous locations of '.':
  1e6c11564562  up
  changeset:   1:1e6c11564562
  bookmark:    bar
  bookmark:    baz
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  cb9a9f314b8b  up 0
  changeset:   0:cb9a9f314b8b
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  
  1e6c11564562  commit -Aqm b
  changeset:   1:1e6c11564562
  bookmark:    bar
  bookmark:    baz
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  cb9a9f314b8b  commit -Aqm a
  changeset:   0:cb9a9f314b8b
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  

  $ hg journal --commit -Tjson
  [
   {
    "changesets": [{"bookmarks": ["bar", "baz"], "branch": "default", "date": [0, 0], "desc": "b", "node": "1e6c11564562b4ed919baca798bc4338bd299d6a", "parents": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"], "phase": "draft", "rev": 1, "tags": ["tip"], "user": "test"}],
    "command": "up",
    "date": [5, 0],
    "name": ".",
    "newnodes": ["1e6c11564562b4ed919baca798bc4338bd299d6a"],
    "oldnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "user": "foobar"
   },
   {
    "changesets": [{"bookmarks": [], "branch": "default", "date": [0, 0], "desc": "a", "node": "cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b", "parents": ["0000000000000000000000000000000000000000"], "phase": "draft", "rev": 0, "tags": [], "user": "test"}],
    "command": "up 0",
    "date": [2, 0],
    "name": ".",
    "newnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "oldnodes": ["1e6c11564562b4ed919baca798bc4338bd299d6a"],
    "user": "foobar"
   },
   {
    "changesets": [{"bookmarks": ["bar", "baz"], "branch": "default", "date": [0, 0], "desc": "b", "node": "1e6c11564562b4ed919baca798bc4338bd299d6a", "parents": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"], "phase": "draft", "rev": 1, "tags": ["tip"], "user": "test"}],
    "command": "commit -Aqm b",
    "date": [1, 0],
    "name": ".",
    "newnodes": ["1e6c11564562b4ed919baca798bc4338bd299d6a"],
    "oldnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "user": "foobar"
   },
   {
    "changesets": [{"bookmarks": [], "branch": "default", "date": [0, 0], "desc": "a", "node": "cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b", "parents": ["0000000000000000000000000000000000000000"], "phase": "draft", "rev": 0, "tags": [], "user": "test"}],
    "command": "commit -Aqm a",
    "date": [0, 0],
    "name": ".",
    "newnodes": ["cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b"],
    "oldnodes": ["0000000000000000000000000000000000000000"],
    "user": "foobar"
   }
  ]

  $ hg journal --commit \
  > -T'command: {command}\n{changesets % " rev: {rev}\n children: {children}\n"}'
  previous locations of '.':
  command: up
   rev: 1
   children: 
  command: up 0
   rev: 0
   children: 1:1e6c11564562
  command: commit -Aqm b
   rev: 1
   children: 
  command: commit -Aqm a
   rev: 0
   children: 1:1e6c11564562

Test for behaviour on unexpected storage version information

  $ printf '42\0' > .hg/namejournal
  $ hg journal
  previous locations of '.':
  abort: unknown journal file version '42'
  [255]
  $ hg book -r tip doomed
  unsupported journal file version '42'
