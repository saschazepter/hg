commit hooks can see env vars
(and post-transaction one are run unlocked)


  $ cat > $TESTTMP/txnabort.checkargs.py <<EOF
  > from mercurial import pycompat
  > def showargs(ui, repo, hooktype, **kwargs):
  >     kwargs = pycompat.byteskwargs(kwargs)
  >     ui.write(b'%s Python hook: %s\n' % (hooktype,
  >                                         b','.join(sorted(kwargs))))
  > EOF

  $ hg init a
  $ cd a
  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > commit = sh -c "HG_LOCAL= HG_TAG= printenv.py --line commit"
  > commit.b = sh -c "HG_LOCAL= HG_TAG= printenv.py --line commit.b"
  > precommit = sh -c  "HG_LOCAL= HG_NODE= HG_TAG= printenv.py --line precommit"
  > pretxncommit = sh -c "HG_LOCAL= HG_TAG= printenv.py --line pretxncommit"
  > pretxncommit.tip = hg -q tip
  > pre-identify = sh -c "printenv.py --line pre-identify 1"
  > pre-cat = sh -c "printenv.py --line pre-cat"
  > post-cat = sh -c "printenv.py --line post-cat"
  > pretxnopen = sh -c "HG_LOCAL= HG_TAG= printenv.py --line pretxnopen"
  > pretxnclose = sh -c "HG_LOCAL= HG_TAG= printenv.py --line pretxnclose"
  > txnclose = sh -c "HG_LOCAL= HG_TAG= printenv.py --line txnclose"
  > txnabort.0 = python:$TESTTMP/txnabort.checkargs.py:showargs
  > txnabort.1 = sh -c "HG_LOCAL= HG_TAG= printenv.py --line txnabort"
  > txnclose.checklock = sh -c "hg debuglock > /dev/null"
  > EOF
  $ echo a > a
  $ hg add a
  $ hg commit -m a
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=0000000000000000000000000000000000000000
  
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  pretxncommit hook: HG_HOOKNAME=pretxncommit
  HG_HOOKTYPE=pretxncommit
  HG_NODE=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  HG_PARENT1=0000000000000000000000000000000000000000
  HG_PENDING=$TESTTMP/a
  
  0:cb9a9f314b8b
  pretxnclose hook: HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_PHASES_MOVED=1
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  txnclose hook: HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_PHASES_MOVED=1
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  commit hook: HG_HOOKNAME=commit
  HG_HOOKTYPE=commit
  HG_NODE=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  HG_PARENT1=0000000000000000000000000000000000000000
  
  commit.b hook: HG_HOOKNAME=commit.b
  HG_HOOKTYPE=commit
  HG_NODE=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  HG_PARENT1=0000000000000000000000000000000000000000
  

  $ hg clone . ../b
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../b

changegroup hooks can see env vars

  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > prechangegroup = sh -c "printenv.py --line prechangegroup"
  > changegroup = sh -c "printenv.py --line changegroup"
  > incoming = sh -c "printenv.py --line incoming"
  > EOF

pretxncommit and commit hooks can see both parents of merge

  $ cd ../a
  $ echo b >> a
  $ hg commit -m a1 -d "1 0"
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  pretxncommit hook: HG_HOOKNAME=pretxncommit
  HG_HOOKTYPE=pretxncommit
  HG_NODE=ab228980c14deea8b9555d91c9581127383e40fd
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  HG_PENDING=$TESTTMP/a
  
  1:ab228980c14d
  pretxnclose hook: HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  txnclose hook: HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  commit hook: HG_HOOKNAME=commit
  HG_HOOKTYPE=commit
  HG_NODE=ab228980c14deea8b9555d91c9581127383e40fd
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  
  commit.b hook: HG_HOOKNAME=commit.b
  HG_HOOKTYPE=commit
  HG_NODE=ab228980c14deea8b9555d91c9581127383e40fd
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  
  $ hg update -C 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo b > b
  $ hg add b
  $ hg commit -m b -d '1 0'
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  pretxncommit hook: HG_HOOKNAME=pretxncommit
  HG_HOOKTYPE=pretxncommit
  HG_NODE=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  HG_PENDING=$TESTTMP/a
  
  2:ee9deb46ab31
  pretxnclose hook: HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  created new head
  txnclose hook: HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  commit hook: HG_HOOKNAME=commit
  HG_HOOKTYPE=commit
  HG_NODE=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  
  commit.b hook: HG_HOOKNAME=commit.b
  HG_HOOKTYPE=commit
  HG_NODE=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT1=cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b
  
  $ hg merge 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m merge -d '2 0'
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT2=ab228980c14deea8b9555d91c9581127383e40fd
  
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  pretxncommit hook: HG_HOOKNAME=pretxncommit
  HG_HOOKTYPE=pretxncommit
  HG_NODE=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_PARENT1=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT2=ab228980c14deea8b9555d91c9581127383e40fd
  HG_PENDING=$TESTTMP/a
  
  3:07f3376c1e65
  pretxnclose hook: HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  txnclose hook: HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  commit hook: HG_HOOKNAME=commit
  HG_HOOKTYPE=commit
  HG_NODE=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_PARENT1=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT2=ab228980c14deea8b9555d91c9581127383e40fd
  
  commit.b hook: HG_HOOKNAME=commit.b
  HG_HOOKTYPE=commit
  HG_NODE=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_PARENT1=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_PARENT2=ab228980c14deea8b9555d91c9581127383e40fd
  

test generic hooks

  $ hg id
  pre-identify hook: HG_ARGS=id
  HG_HOOKNAME=pre-identify
  HG_HOOKTYPE=pre-identify
  HG_OPTS={'bookmarks': None, 'branch': None, 'id': None, 'insecure': None, 'num': None, 'remotecmd': '', 'rev': '', 'ssh': '', 'tags': None, 'template': ''}
  HG_PATS=[]
  
  abort: pre-identify hook exited with status 1
  [40]
  $ hg cat b
  pre-cat hook: HG_ARGS=cat b
  HG_HOOKNAME=pre-cat
  HG_HOOKTYPE=pre-cat
  HG_OPTS={'decode': None, 'exclude': [], 'include': [], 'output': '', 'rev': '', 'template': ''}
  HG_PATS=['b']
  
  b
  post-cat hook: HG_ARGS=cat b
  HG_HOOKNAME=post-cat
  HG_HOOKTYPE=post-cat
  HG_OPTS={'decode': None, 'exclude': [], 'include': [], 'output': '', 'rev': '', 'template': ''}
  HG_PATS=['b']
  HG_RESULT=0
  

  $ cd ../b
  $ hg pull ../a
  pulling from ../a
  searching for changes
  prechangegroup hook: HG_HOOKNAME=prechangegroup
  HG_HOOKTYPE=prechangegroup
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 2 changes to 2 files
  new changesets ab228980c14d:07f3376c1e65
  changegroup hook: HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=ab228980c14deea8b9555d91c9581127383e40fd
  HG_NODE_LAST=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  incoming hook: HG_HOOKNAME=incoming
  HG_HOOKTYPE=incoming
  HG_NODE=ab228980c14deea8b9555d91c9581127383e40fd
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  incoming hook: HG_HOOKNAME=incoming
  HG_HOOKTYPE=incoming
  HG_NODE=ee9deb46ab31e4cc3310f3cf0c3d668e4d8fffc2
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  incoming hook: HG_HOOKNAME=incoming
  HG_HOOKTYPE=incoming
  HG_NODE=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  (run 'hg update' to get a working copy)

tag hooks can see env vars

  $ cd ../a
  $ cat >> .hg/hgrc <<EOF
  > pretag = sh -c "printenv.py --line pretag"
  > tag = sh -c "HG_PARENT1= HG_PARENT2= printenv.py --line tag"
  > EOF
  $ hg tag -d '3 0' a
  pretag hook: HG_HOOKNAME=pretag
  HG_HOOKTYPE=pretag
  HG_LOCAL=0
  HG_NODE=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_TAG=a
  
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=07f3376c1e655977439df2a814e3cc14b27abac2
  
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  pretxncommit hook: HG_HOOKNAME=pretxncommit
  HG_HOOKTYPE=pretxncommit
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_PARENT1=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_PENDING=$TESTTMP/a
  
  4:539e4b31b6dc
  pretxnclose hook: HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  tag hook: HG_HOOKNAME=tag
  HG_HOOKTYPE=tag
  HG_LOCAL=0
  HG_NODE=07f3376c1e655977439df2a814e3cc14b27abac2
  HG_TAG=a
  
  txnclose hook: HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  commit hook: HG_HOOKNAME=commit
  HG_HOOKTYPE=commit
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_PARENT1=07f3376c1e655977439df2a814e3cc14b27abac2
  
  commit.b hook: HG_HOOKNAME=commit.b
  HG_HOOKTYPE=commit
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_PARENT1=07f3376c1e655977439df2a814e3cc14b27abac2
  
  $ hg tag -l la
  pretag hook: HG_HOOKNAME=pretag
  HG_HOOKTYPE=pretag
  HG_LOCAL=1
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_TAG=la
  
  tag hook: HG_HOOKNAME=tag
  HG_HOOKTYPE=tag
  HG_LOCAL=1
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_TAG=la
  

pretag hook can forbid tagging

  $ cat >> .hg/hgrc <<EOF
  > pretag.forbid = sh -c "printenv.py --line pretag.forbid 1"
  > EOF
  $ hg tag -d '4 0' fa
  pretag hook: HG_HOOKNAME=pretag
  HG_HOOKTYPE=pretag
  HG_LOCAL=0
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_TAG=fa
  
  pretag.forbid hook: HG_HOOKNAME=pretag.forbid
  HG_HOOKTYPE=pretag
  HG_LOCAL=0
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_TAG=fa
  
  abort: pretag.forbid hook exited with status 1
  [40]
  $ hg tag -l fla
  pretag hook: HG_HOOKNAME=pretag
  HG_HOOKTYPE=pretag
  HG_LOCAL=1
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_TAG=fla
  
  pretag.forbid hook: HG_HOOKNAME=pretag.forbid
  HG_HOOKTYPE=pretag
  HG_LOCAL=1
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_TAG=fla
  
  abort: pretag.forbid hook exited with status 1
  [40]

pretxncommit hook can see changeset, can roll back txn, changeset no
more there after

  $ cat >> .hg/hgrc <<EOF
  > pretxncommit.forbid0 = sh -c "hg tip -q"
  > pretxncommit.forbid1 = sh -c "printenv.py --line pretxncommit.forbid 1"
  > EOF
  $ echo z > z
  $ hg add z
  $ hg -q tip
  4:539e4b31b6dc
  $ hg commit -m 'fail' -d '4 0'
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  pretxncommit hook: HG_HOOKNAME=pretxncommit
  HG_HOOKTYPE=pretxncommit
  HG_NODE=6f611f8018c10e827fee6bd2bc807f937e761567
  HG_PARENT1=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_PENDING=$TESTTMP/a
  
  5:6f611f8018c1
  5:6f611f8018c1
  pretxncommit.forbid hook: HG_HOOKNAME=pretxncommit.forbid1
  HG_HOOKTYPE=pretxncommit
  HG_NODE=6f611f8018c10e827fee6bd2bc807f937e761567
  HG_PARENT1=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_PENDING=$TESTTMP/a
  
  transaction abort!
  txnabort Python hook: changes,txnid,txnname
  txnabort hook: HG_HOOKNAME=txnabort.1
  HG_HOOKTYPE=txnabort
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=commit
  
  rollback completed
  abort: pretxncommit.forbid1 hook exited with status 1
  [40]
  $ hg -q tip
  4:539e4b31b6dc

(Check that no 'changelog.i.a' file were left behind)

  $ ls -1 .hg/store/
  00changelog.i
  00manifest.i
  data
  fncache (repofncache !)
  journal.phaseroots
  phaseroots
  requires
  undo
  undo.backup.fncache (repofncache !)
  undo.backupfiles
  undo.phaseroots


precommit hook can prevent commit

  $ cat >> .hg/hgrc <<EOF
  > precommit.forbid = sh -c "printenv.py --line precommit.forbid 1"
  > EOF
  $ hg commit -m 'fail' -d '4 0'
  precommit hook: HG_HOOKNAME=precommit
  HG_HOOKTYPE=precommit
  HG_PARENT1=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  
  precommit.forbid hook: HG_HOOKNAME=precommit.forbid
  HG_HOOKTYPE=precommit
  HG_PARENT1=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  
  abort: precommit.forbid hook exited with status 1
  [40]
  $ hg -q tip
  4:539e4b31b6dc

preupdate hook can prevent update

  $ cat >> .hg/hgrc <<EOF
  > preupdate = sh -c "printenv.py --line preupdate"
  > EOF
  $ hg update 1
  preupdate hook: HG_HOOKNAME=preupdate
  HG_HOOKTYPE=preupdate
  HG_PARENT1=ab228980c14d
  
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved

update hook

  $ cat >> .hg/hgrc <<EOF
  > update = sh -c "printenv.py --line update"
  > EOF
  $ hg update
  preupdate hook: HG_HOOKNAME=preupdate
  HG_HOOKTYPE=preupdate
  HG_PARENT1=539e4b31b6dc
  
  update hook: HG_ERROR=0
  HG_HOOKNAME=update
  HG_HOOKTYPE=update
  HG_PARENT1=539e4b31b6dc
  
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

pushkey hook

  $ cat >> .hg/hgrc <<EOF
  > pushkey = sh -c "printenv.py --line pushkey"
  > EOF
  $ cd ../b
  $ hg bookmark -r null foo
  $ hg push -B foo ../a
  pushing to ../a
  searching for changes
  no changes found
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=push
  
  pretxnclose hook: HG_BOOKMARK_MOVED=1
  HG_BUNDLE2=1
  HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_SOURCE=push
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=push
  HG_URL=file:$TESTTMP/a
  
  pushkey hook: HG_BUNDLE2=1
  HG_HOOKNAME=pushkey
  HG_HOOKTYPE=pushkey
  HG_KEY=foo
  HG_NAMESPACE=bookmarks
  HG_NEW=0000000000000000000000000000000000000000
  HG_PUSHKEYCOMPAT=1
  HG_SOURCE=push
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=push
  HG_URL=file:$TESTTMP/a
  
  txnclose hook: HG_BOOKMARK_MOVED=1
  HG_BUNDLE2=1
  HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_SOURCE=push
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=push
  HG_URL=file:$TESTTMP/a
  
  exporting bookmark foo
  [1]
  $ cd ../a

listkeys hook

  $ cat >> .hg/hgrc <<EOF
  > listkeys = sh -c "printenv.py --line listkeys"
  > EOF
  $ hg bookmark -r null bar
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=bookmark
  
  pretxnclose hook: HG_BOOKMARK_MOVED=1
  HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=bookmark
  
  txnclose hook: HG_BOOKMARK_MOVED=1
  HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=bookmark
  
  $ cd ../b
  $ hg pull -B bar ../a
  pulling from ../a
  listkeys hook: HG_HOOKNAME=listkeys
  HG_HOOKTYPE=listkeys
  HG_NAMESPACE=bookmarks
  HG_VALUES={'bar': '0000000000000000000000000000000000000000', 'foo': '0000000000000000000000000000000000000000'}
  
  no changes found
  adding remote bookmark bar
  $ cd ../a

test that prepushkey can prevent incoming keys

  $ cat >> .hg/hgrc <<EOF
  > prepushkey = sh -c "printenv.py --line prepushkey.forbid 1"
  > EOF
  $ cd ../b
  $ hg bookmark -r null baz
  $ hg push -B baz ../a
  pushing to ../a
  searching for changes
  listkeys hook: HG_HOOKNAME=listkeys
  HG_HOOKTYPE=listkeys
  HG_NAMESPACE=phases
  HG_VALUES={'cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b': '1', 'publishing': 'True'}
  
  listkeys hook: HG_HOOKNAME=listkeys
  HG_HOOKTYPE=listkeys
  HG_NAMESPACE=bookmarks
  HG_VALUES={'bar': '0000000000000000000000000000000000000000', 'foo': '0000000000000000000000000000000000000000'}
  
  no changes found
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=push
  
  prepushkey.forbid hook: HG_BUNDLE2=1
  HG_HOOKNAME=prepushkey
  HG_HOOKTYPE=prepushkey
  HG_KEY=baz
  HG_NAMESPACE=bookmarks
  HG_NEW=0000000000000000000000000000000000000000
  HG_PUSHKEYCOMPAT=1
  HG_SOURCE=push
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=push
  HG_URL=file:$TESTTMP/a
  
  abort: prepushkey hook exited with status 1
  [40]
  $ cd ../a

test that prelistkeys can prevent listing keys

  $ cat >> .hg/hgrc <<EOF
  > prelistkeys = sh -c "printenv.py --line prelistkeys.forbid 1"
  > EOF
  $ hg bookmark -r null quux
  pretxnopen hook: HG_HOOKNAME=pretxnopen
  HG_HOOKTYPE=pretxnopen
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=bookmark
  
  pretxnclose hook: HG_BOOKMARK_MOVED=1
  HG_HOOKNAME=pretxnclose
  HG_HOOKTYPE=pretxnclose
  HG_PENDING=$TESTTMP/a
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=bookmark
  
  txnclose hook: HG_BOOKMARK_MOVED=1
  HG_HOOKNAME=txnclose
  HG_HOOKTYPE=txnclose
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=bookmark
  
  $ cd ../b
  $ hg pull -B quux ../a
  pulling from ../a
  prelistkeys.forbid hook: HG_HOOKNAME=prelistkeys
  HG_HOOKTYPE=prelistkeys
  HG_NAMESPACE=bookmarks
  
  abort: prelistkeys hook exited with status 1
  [40]
  $ cd ../a
  $ rm .hg/hgrc

prechangegroup hook can prevent incoming changes

  $ cd ../b
  $ hg -q tip
  3:07f3376c1e65
  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > prechangegroup.forbid = sh -c "printenv.py --line prechangegroup.forbid 1"
  > EOF
  $ hg pull ../a
  pulling from ../a
  searching for changes
  prechangegroup.forbid hook: HG_HOOKNAME=prechangegroup.forbid
  HG_HOOKTYPE=prechangegroup
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  abort: prechangegroup.forbid hook exited with status 1
  [40]

pretxnchangegroup hook can see incoming changes, can roll back txn,
incoming changes no longer there after

  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > pretxnchangegroup.forbid0 = hg tip -q
  > pretxnchangegroup.forbid1 = sh -c "printenv.py --line pretxnchangegroup.forbid 1"
  > EOF
  $ hg pull ../a
  pulling from ../a
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  4:539e4b31b6dc
  pretxnchangegroup.forbid hook: HG_HOOKNAME=pretxnchangegroup.forbid1
  HG_HOOKTYPE=pretxnchangegroup
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_NODE_LAST=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_PENDING=$TESTTMP/b
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  file:/*/$TESTTMP/a (glob)
  HG_URL=file:$TESTTMP/a
  
  transaction abort!
  rollback completed
  abort: pretxnchangegroup.forbid1 hook exited with status 1
  [40]
  $ hg -q tip
  3:07f3376c1e65

outgoing hooks can see env vars

  $ rm .hg/hgrc
  $ cat > ../a/.hg/hgrc <<EOF
  > [hooks]
  > preoutgoing = sh -c "printenv.py --line preoutgoing"
  > outgoing = sh -c "printenv.py --line outgoing"
  > EOF
  $ hg pull ../a
  pulling from ../a
  searching for changes
  preoutgoing hook: HG_HOOKNAME=preoutgoing
  HG_HOOKTYPE=preoutgoing
  HG_SOURCE=pull
  
  outgoing hook: HG_HOOKNAME=outgoing
  HG_HOOKTYPE=outgoing
  HG_NODE=539e4b31b6dc99b3cfbaa6b53cbc1c1f9a1e3a10
  HG_SOURCE=pull
  
  adding changesets
  adding manifests
  adding file changes
  adding remote bookmark quux
  added 1 changesets with 1 changes to 1 files
  new changesets 539e4b31b6dc
  (run 'hg update' to get a working copy)
  $ hg rollback
  repository tip rolled back to revision 3 (undo pull)

preoutgoing hook can prevent outgoing changes

  $ cat >> ../a/.hg/hgrc <<EOF
  > preoutgoing.forbid = sh -c "printenv.py --line preoutgoing.forbid 1"
  > EOF
  $ hg pull ../a
  pulling from ../a
  searching for changes
  preoutgoing hook: HG_HOOKNAME=preoutgoing
  HG_HOOKTYPE=preoutgoing
  HG_SOURCE=pull
  
  preoutgoing.forbid hook: HG_HOOKNAME=preoutgoing.forbid
  HG_HOOKTYPE=preoutgoing
  HG_SOURCE=pull
  
  abort: preoutgoing.forbid hook exited with status 1
  [40]

outgoing hooks work for local clones

  $ cd ..
  $ cat > a/.hg/hgrc <<EOF
  > [hooks]
  > preoutgoing = sh -c "printenv.py --line preoutgoing"
  > outgoing = sh -c "printenv.py --line outgoing"
  > EOF
  $ hg clone a c
  preoutgoing hook: HG_HOOKNAME=preoutgoing
  HG_HOOKTYPE=preoutgoing
  HG_SOURCE=clone
  
  outgoing hook: HG_HOOKNAME=outgoing
  HG_HOOKTYPE=outgoing
  HG_NODE=0000000000000000000000000000000000000000
  HG_SOURCE=clone
  
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ rm -rf c

preoutgoing hook can prevent outgoing changes for local clones

  $ cat >> a/.hg/hgrc <<EOF
  > preoutgoing.forbid = sh -c "printenv.py --line preoutgoing.forbid 1"
  > EOF
  $ hg clone a zzz
  preoutgoing hook: HG_HOOKNAME=preoutgoing
  HG_HOOKTYPE=preoutgoing
  HG_SOURCE=clone
  
  preoutgoing.forbid hook: HG_HOOKNAME=preoutgoing.forbid
  HG_HOOKTYPE=preoutgoing
  HG_SOURCE=clone
  
  abort: preoutgoing.forbid hook exited with status 1
  [40]

  $ cd "$TESTTMP/b"

  $ cat > hooktests.py <<EOF
  > from __future__ import print_function
  > from mercurial import (
  >     error,
  >     pycompat,
  > )
  > 
  > uncallable = 0
  > 
  > def printargs(ui, args):
  >     a = list(pycompat.byteskwargs(args).items())
  >     a.sort()
  >     ui.write(b'hook args:\n')
  >     for k, v in a:
  >        ui.write(b'  %s %s\n' % (k, v))
  > 
  > def passhook(ui, repo, **args):
  >     printargs(ui, args)
  > 
  > def failhook(ui, repo, **args):
  >     printargs(ui, args)
  >     return True
  > 
  > class LocalException(Exception):
  >     pass
  > 
  > def raisehook(**args):
  >     raise LocalException('exception from hook')
  > 
  > def aborthook(**args):
  >     raise error.Abort(b'raise abort from hook')
  > 
  > def brokenhook(**args):
  >     return 1 + {}
  > 
  > def verbosehook(ui, **args):
  >     ui.note(b'verbose output from hook\n')
  > 
  > def printtags(ui, repo, **args):
  >     ui.write(b'[%s]\n' % b', '.join(sorted(repo.tags())))
  > 
  > class container(object):
  >     unreachable = 1
  > EOF

  $ cat > syntaxerror.py << NO_CHECK_EOF
  > (foo
  > NO_CHECK_EOF

test python hooks

#if windows
  $ PYTHONPATH="$TESTTMP/b;$PYTHONPATH"
#else
  $ PYTHONPATH="$TESTTMP/b:$PYTHONPATH"
#endif
  $ export PYTHONPATH

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.broken = python:hooktests.brokenhook' >> ../a/.hg/hgrc
  $ hg pull ../a 2>&1 | grep 'raised an exception'
  error: preoutgoing.broken hook raised an exception: unsupported operand type(s) for +: 'int' and 'dict'

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.raise = python:hooktests.raisehook' >> ../a/.hg/hgrc
  $ hg pull ../a 2>&1 | grep 'raised an exception'
  error: preoutgoing.raise hook raised an exception: exception from hook

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.abort = python:hooktests.aborthook' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  error: preoutgoing.abort hook failed: raise abort from hook
  abort: raise abort from hook
  [255]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.fail = python:hooktests.failhook' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  hook args:
    hooktype preoutgoing
    source pull
  abort: preoutgoing.fail hook failed
  [40]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.uncallable = python:hooktests.uncallable' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  abort: preoutgoing.uncallable hook is invalid: "hooktests.uncallable" is not callable
  [255]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.nohook = python:hooktests.nohook' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  abort: preoutgoing.nohook hook is invalid: "hooktests.nohook" is not defined
  [255]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.nomodule = python:nomodule' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  abort: preoutgoing.nomodule hook is invalid: "nomodule" not in a module
  [255]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.badmodule = python:nomodule.nowhere' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  abort: preoutgoing.badmodule hook is invalid: import of "nomodule" failed
  (run with --traceback for stack trace)
  [255]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.unreachable = python:hooktests.container.unreachable' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  abort: preoutgoing.unreachable hook is invalid: import of "hooktests.container" failed
  (run with --traceback for stack trace)
  [255]

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.syntaxerror = python:syntaxerror.syntaxerror' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  abort: preoutgoing.syntaxerror hook is invalid: import of "syntaxerror" failed
  (run with --traceback for stack trace)
  [255]

  $ hg pull ../a --traceback 2>&1 | egrep 'pulling|searching|^exception|Traceback|SyntaxError|ImportError|ModuleNotFoundError|HookLoadError|abort'
  pulling from ../a
  searching for changes
  exception from first failed import attempt:
  Traceback (most recent call last):
  SyntaxError: * (glob)
  exception from second failed import attempt:
  Traceback (most recent call last): (py3 !)
  SyntaxError: * (glob) (py3 !)
  Traceback (most recent call last):
  ImportError: No module named hgext_syntaxerror (no-py3 !)
  ImportError: No module named 'hgext_syntaxerror' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'hgext_syntaxerror' (py36 !)
  Traceback (most recent call last):
  SyntaxError: * (glob) (py3 !)
  Traceback (most recent call last): (py3 !)
  ImportError: No module named 'hgext_syntaxerror' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'hgext_syntaxerror' (py36 !)
  Traceback (most recent call last): (py3 !)
  HookLoadError: preoutgoing.syntaxerror hook is invalid: import of "syntaxerror" failed (no-py3 !)
      raise error.HookLoadError( (py38 !)
  mercurial.error.HookLoadError: preoutgoing.syntaxerror hook is invalid: import of "syntaxerror" failed (py3 !)
  abort: preoutgoing.syntaxerror hook is invalid: import of "syntaxerror" failed

  $ echo '[hooks]' > ../a/.hg/hgrc
  $ echo 'preoutgoing.pass = python:hooktests.passhook' >> ../a/.hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  hook args:
    hooktype preoutgoing
    source pull
  adding changesets
  adding manifests
  adding file changes
  adding remote bookmark quux
  added 1 changesets with 1 changes to 1 files
  new changesets 539e4b31b6dc
  (run 'hg update' to get a working copy)

post- python hooks that fail to *run* don't cause an abort
  $ rm ../a/.hg/hgrc
  $ echo '[hooks]' > .hg/hgrc
  $ echo 'post-pull.broken = python:hooktests.brokenhook' >> .hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  no changes found
  error: post-pull.broken hook raised an exception: unsupported operand type(s) for +: 'int' and 'dict'
  (run with --traceback for stack trace)

but post- python hooks that fail to *load* do
  $ echo '[hooks]' > .hg/hgrc
  $ echo 'post-pull.nomodule = python:nomodule' >> .hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  no changes found
  abort: post-pull.nomodule hook is invalid: "nomodule" not in a module
  [255]

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'post-pull.badmodule = python:nomodule.nowhere' >> .hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  no changes found
  abort: post-pull.badmodule hook is invalid: import of "nomodule" failed
  (run with --traceback for stack trace)
  [255]

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'post-pull.nohook = python:hooktests.nohook' >> .hg/hgrc
  $ hg pull ../a
  pulling from ../a
  searching for changes
  no changes found
  abort: post-pull.nohook hook is invalid: "hooktests.nohook" is not defined
  [255]

make sure --traceback works

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'commit.abort = python:hooktests.aborthook' >> .hg/hgrc

  $ echo aa > a
  $ hg --traceback commit -d '0 0' -ma 2>&1 | grep '^Traceback'
  Traceback (most recent call last):

  $ cd ..
  $ hg init c
  $ cd c

  $ cat > hookext.py <<EOF
  > def autohook(ui, **args):
  >     ui.write(b'Automatically installed hook\n')
  > 
  > def reposetup(ui, repo):
  >     repo.ui.setconfig(b"hooks", b"commit.auto", autohook)
  > EOF
  $ echo '[extensions]' >> .hg/hgrc
  $ echo 'hookext = hookext.py' >> .hg/hgrc

  $ touch foo
  $ hg add foo
  $ hg ci -d '0 0' -m 'add foo'
  Automatically installed hook
  $ echo >> foo
  $ hg ci --debug -d '0 0' -m 'change foo'
  committing files:
  foo
  committing manifest
  committing changelog
  updating the branch cache
  committed changeset 1:52998019f6252a2b893452765fcb0a47351a5708
  calling hook commit.auto: hgext_hookext.autohook
  Automatically installed hook

  $ hg showconfig hooks
  hooks.commit.auto=<function autohook at *> (glob)

test python hook configured with python:[file]:[hook] syntax

  $ cd ..
  $ mkdir d
  $ cd d
  $ hg init repo
  $ mkdir hooks

  $ cd hooks
  $ cat > testhooks.py <<EOF
  > def testhook(ui, **args):
  >     ui.write(b'hook works\n')
  > EOF
  $ echo '[hooks]' > ../repo/.hg/hgrc
  $ echo "pre-commit.test = python:`pwd`/testhooks.py:testhook" >> ../repo/.hg/hgrc

  $ cd ../repo
  $ hg commit -d '0 0'
  hook works
  nothing changed
  [1]

  $ echo '[hooks]' > .hg/hgrc
  $ echo "update.ne = python:`pwd`/nonexistent.py:testhook" >> .hg/hgrc
  $ echo "pre-identify.npmd = python:`pwd`/:no_python_module_dir" >> .hg/hgrc

  $ hg up null
  loading update.ne hook failed:
  abort: $ENOENT$: '$TESTTMP/d/repo/nonexistent.py'
  [255]

  $ hg id
  loading pre-identify.npmd hook failed:
  abort: No module named repo (no-py3 !)
  abort: No module named 'repo' (py3 !)
  [255]

  $ cd ../../b

make sure --traceback works on hook import failure

  $ cat > importfail.py <<EOF
  > import somebogusmodule
  > # dereference something in the module to force demandimport to load it
  > somebogusmodule.whatever
  > EOF

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'precommit.importfail = python:importfail.whatever' >> .hg/hgrc

  $ echo a >> a
  $ hg --traceback commit -ma 2>&1 | egrep '^exception|ImportError|ModuleNotFoundError|Traceback|HookLoadError|abort'
  exception from first failed import attempt:
  Traceback (most recent call last):
  ImportError: No module named somebogusmodule (no-py3 !)
  ImportError: No module named 'somebogusmodule' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'somebogusmodule' (py36 !)
  exception from second failed import attempt:
  Traceback (most recent call last): (py3 !)
  ImportError: No module named 'somebogusmodule' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'somebogusmodule' (py36 !)
  Traceback (most recent call last): (py3 !)
  ImportError: No module named 'hgext_importfail' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'hgext_importfail' (py36 !)
  Traceback (most recent call last): (py3 !)
  ImportError: No module named 'somebogusmodule' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'somebogusmodule' (py36 !)
  Traceback (most recent call last):
  ImportError: No module named hgext_importfail (no-py3 !)
  ImportError: No module named 'hgext_importfail' (py3 no-py36 !)
  ModuleNotFoundError: No module named 'hgext_importfail' (py36 !)
  Traceback (most recent call last):
  HookLoadError: precommit.importfail hook is invalid: import of "importfail" failed (no-py3 !)
      raise error.HookLoadError( (py38 !)
  mercurial.error.HookLoadError: precommit.importfail hook is invalid: import of "importfail" failed (py3 !)
  abort: precommit.importfail hook is invalid: import of "importfail" failed

Issue1827: Hooks Update & Commit not completely post operation

commit and update hooks should run after command completion.  The largefiles
use demonstrates a recursive wlock, showing the hook doesn't run until the
final release (and dirstate flush).

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'commit = hg id' >> .hg/hgrc
  $ echo 'update = hg id' >> .hg/hgrc
  $ echo bb > a
  $ hg ci -ma
  223eafe2750c tip
  $ hg up 0 --config extensions.largefiles=
  The fsmonitor extension is incompatible with the largefiles extension and has been disabled. (fsmonitor !)
  cb9a9f314b8b
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

make sure --verbose (and --quiet/--debug etc.) are propagated to the local ui
that is passed to pre/post hooks

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'pre-identify = python:hooktests.verbosehook' >> .hg/hgrc
  $ hg id
  cb9a9f314b8b
  $ hg id --verbose
  calling hook pre-identify: hooktests.verbosehook
  verbose output from hook
  cb9a9f314b8b

Ensure hooks can be prioritized

  $ echo '[hooks]' > .hg/hgrc
  $ echo 'pre-identify.a = python:hooktests.verbosehook' >> .hg/hgrc
  $ echo 'pre-identify.b = python:hooktests.verbosehook' >> .hg/hgrc
  $ echo 'priority.pre-identify.b = 1' >> .hg/hgrc
  $ echo 'pre-identify.c = python:hooktests.verbosehook' >> .hg/hgrc
  $ hg id --verbose
  calling hook pre-identify.b: hooktests.verbosehook
  verbose output from hook
  calling hook pre-identify.a: hooktests.verbosehook
  verbose output from hook
  calling hook pre-identify.c: hooktests.verbosehook
  verbose output from hook
  cb9a9f314b8b

new tags must be visible in pretxncommit (issue3210)

  $ echo 'pretxncommit.printtags = python:hooktests.printtags' >> .hg/hgrc
  $ hg tag -f foo
  [a, foo, tip]

post-init hooks must not crash (issue4983)
This also creates the `to` repo for the next test block.

  $ cd ..
  $ cat << EOF >> hgrc-with-post-init-hook
  > [hooks]
  > post-init = sh -c "printenv.py --line post-init"
  > EOF
  $ HGRCPATH=hgrc-with-post-init-hook hg init to
  post-init hook: HG_ARGS=init to
  HG_HOOKNAME=post-init
  HG_HOOKTYPE=post-init
  HG_OPTS={'insecure': None, 'remotecmd': '', 'ssh': ''}
  HG_PATS=['to']
  HG_RESULT=0
  

new commits must be visible in pretxnchangegroup (issue3428)

  $ echo '[hooks]' >> to/.hg/hgrc
  $ echo 'prechangegroup = hg --traceback tip' >> to/.hg/hgrc
  $ echo 'pretxnchangegroup = hg --traceback tip' >> to/.hg/hgrc
  $ echo a >> to/a
  $ hg --cwd to ci -Ama
  adding a
  $ hg clone to from
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo aa >> from/a
  $ hg --cwd from ci -mb
  $ hg --cwd from push
  pushing to $TESTTMP/to
  searching for changes
  changeset:   0:cb9a9f314b8b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  
  adding changesets
  adding manifests
  adding file changes
  changeset:   1:9836a07b9b9d
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     b
  
  added 1 changesets with 1 changes to 1 files

pretxnclose hook failure should abort the transaction

  $ hg init txnfailure
  $ cd txnfailure
  $ touch a && hg commit -Aqm a
  $ cat >> .hg/hgrc <<EOF
  > [hooks]
  > pretxnclose.error = exit 1
  > EOF
  $ hg strip -r 0 --config extensions.strip=
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  saved backup bundle to * (glob)
  transaction abort!
  rollback completed
  strip failed, backup bundle stored in * (glob)
  abort: pretxnclose.error hook exited with status 1
  [40]
  $ hg recover
  no interrupted transaction available
  [1]
  $ cd ..

check whether HG_PENDING makes pending changes only in related
repositories visible to an external hook.

(emulate a transaction running concurrently by copied
.hg/store/00changelog.i.a in subsequent test)

  $ cat > $TESTTMP/savepending.sh <<EOF
  > cp .hg/store/00changelog.i.a  .hg/store/00changelog.i.a.saved
  > exit 1 # to avoid adding new revision for subsequent tests
  > EOF
  $ cd a
  $ hg tip -q
  4:539e4b31b6dc
  $ hg --config hooks.pretxnclose="sh $TESTTMP/savepending.sh" commit -m "invisible"
  transaction abort!
  rollback completed
  abort: pretxnclose hook exited with status 1
  [40]
  $ cp .hg/store/00changelog.i.a.saved .hg/store/00changelog.i.a

(check (in)visibility of new changeset while transaction running in
repo)

  $ cat > $TESTTMP/checkpending.sh <<EOF
  > echo '@a'
  > hg -R "$TESTTMP/a" tip -q
  > echo '@a/nested'
  > hg -R "$TESTTMP/a/nested" tip -q
  > exit 1 # to avoid adding new revision for subsequent tests
  > EOF
  $ hg init nested
  $ cd nested
  $ echo a > a
  $ hg add a
  $ hg --config hooks.pretxnclose="sh $TESTTMP/checkpending.sh" commit -m '#0'
  @a
  4:539e4b31b6dc
  @a/nested
  0:bf5e395ced2c
  transaction abort!
  rollback completed
  abort: pretxnclose hook exited with status 1
  [40]

Hook from untrusted hgrc are reported as failure
================================================

  $ cat << EOF > $TESTTMP/untrusted.py
  > from mercurial import scmutil, util
  > def uisetup(ui):
  >     class untrustedui(ui.__class__):
  >         def _trusted(self, fp, f):
  >             if util.normpath(fp.name).endswith(b'untrusted/.hg/hgrc'):
  >                 return False
  >             return super(untrustedui, self)._trusted(fp, f)
  >     ui.__class__ = untrustedui
  > EOF
  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > untrusted=$TESTTMP/untrusted.py
  > EOF
  $ hg init untrusted
  $ cd untrusted

Non-blocking hook
-----------------

  $ cat << EOF >> .hg/hgrc
  > [hooks]
  > txnclose.testing=echo txnclose hook called
  > EOF
  $ touch a && hg commit -Aqm a
  warning: untrusted hook txnclose.testing not executed
  $ hg log
  changeset:   0:3903775176ed
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  

Non-blocking hook
-----------------

  $ cat << EOF >> .hg/hgrc
  > [hooks]
  > pretxnclose.testing=echo pre-txnclose hook called
  > EOF
  $ touch b && hg commit -Aqm a
  transaction abort!
  rollback completed
  abort: untrusted hook pretxnclose.testing not executed
  (see 'hg help config.trusted')
  [40]
  $ hg log
  changeset:   0:3903775176ed
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  

unsetup the test
----------------

# touch the file to unconfuse chg with a diffrent mtime
  $ sleep 1
  $ touch $TESTTMP/untrusted.py
  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > untrusted=!
  > EOF

HGPLAIN setting in hooks
========================

  $ cat << EOF >> .hg/hgrc
  > [hooks]
  > pre-version.testing-default=sh -c "echo '### default ###' plain: \${HGPLAIN:-'<unset>'}"
  > pre-version.testing-yes=sh -c "echo '### yes #######' plain: \${HGPLAIN:-'<unset>'}"
  > pre-version.testing-yes:run-with-plain=yes
  > pre-version.testing-no=sh -c "echo '### no ########' plain: \${HGPLAIN:-'<unset>'}"
  > pre-version.testing-no:run-with-plain=no
  > pre-version.testing-auto=sh -c "echo '### auto ######' plain: \${HGPLAIN:-'<unset>'}"
  > pre-version.testing-auto:run-with-plain=auto
  > EOF

  $ (unset HGPLAIN; hg version --quiet)
  ### default ### plain: 1
  ### yes ####### plain: 1
  ### no ######## plain: <unset>
  ### auto ###### plain: <unset>
  Mercurial Distributed SCM (*) (glob)

  $ HGPLAIN=1 hg version --quiet
  ### default ### plain: 1
  ### yes ####### plain: 1
  ### no ######## plain: <unset>
  ### auto ###### plain: 1
  Mercurial Distributed SCM (*) (glob)
