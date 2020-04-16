#require unix-permissions no-root reporevlogstore

  $ cat > $TESTTMP/dumpjournal.py <<EOF
  > import sys
  > for entry in sys.stdin.read().split('\n'):
  >     if entry:
  >         print(entry.split('\x00')[0])
  > EOF

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "mq=">> $HGRCPATH

  $ teststrip() {
  >   hg -q up -C $1
  >   echo % before update $1, strip $2
  >   hg parents
  >   chmod -$3 $4
  >   hg strip $2 2>&1 | sed 's/\(bundle\).*/\1/' | sed 's/Permission denied.*\.hg\/store\/\(.*\)/Permission denied \.hg\/store\/\1/'
  >   echo % after update $1, strip $2
  >   chmod +$3 $4
  >   hg verify
  >   echo % journal contents
  >   if [ -f .hg/store/journal ]; then
  >       cat .hg/store/journal | "$PYTHON" $TESTTMP/dumpjournal.py
  >   else
  >       echo "(no journal)"
  >   fi
  >   if ls .hg/store/journal >/dev/null 2>&1; then
  >     hg recover --verify
  >   fi
  >   ls .hg/strip-backup/* >/dev/null 2>&1 && hg unbundle -q .hg/strip-backup/*
  >   rm -rf .hg/strip-backup
  > }

  $ hg init test
  $ cd test
  $ echo a > a
  $ hg -q ci -m "a" -A
  $ echo b > b
  $ hg -q ci -m "b" -A
  $ echo b2 >> b
  $ hg -q ci -m "b2" -A
  $ echo c > c
  $ hg -q ci -m "c" -A
  $ teststrip 0 2 w .hg/store/data/b.i
  % before update 0, strip 2
  changeset:   0:cb9a9f314b8b
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  
  saved backup bundle
  transaction abort!
  failed to truncate data/b.i
  rollback failed - please run hg recover
  (failure reason: [Errno *] Permission denied .hg/store/data/b.i') (glob)
  strip failed, backup bundle
  abort: Permission denied .hg/store/data/b.i'
  % after update 0, strip 2
  abandoned transaction found - run hg recover
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
   b@?: rev 1 points to nonexistent changeset 2
   (expected 1)
   b@?: 736c29771fba not in manifests
  warning: orphan data file 'data/c.i'
  checked 2 changesets with 3 changes to 2 files
  2 warnings encountered!
  2 integrity errors encountered!
  % journal contents
  00changelog.i
  00manifest.i
  data/b.i
  data/c.i
  rolling back interrupted transaction
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 2 files
  $ teststrip 0 2 r .hg/store/data/b.i
  % before update 0, strip 2
  changeset:   0:cb9a9f314b8b
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  
  abort: Permission denied .hg/store/data/b.i'
  % after update 0, strip 2
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 4 changes to 3 files
  % journal contents
  (no journal)
  $ teststrip 0 2 w .hg/store/00manifest.i
  % before update 0, strip 2
  changeset:   0:cb9a9f314b8b
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     a
  
  saved backup bundle
  transaction abort!
  failed to truncate 00manifest.i
  rollback failed - please run hg recover
  (failure reason: [Errno *] Permission denied .hg/store/00manifest.i') (glob)
  strip failed, backup bundle
  abort: Permission denied .hg/store/00manifest.i'
  % after update 0, strip 2
  abandoned transaction found - run hg recover
  checking changesets
  checking manifests
   manifest@?: rev 2 points to nonexistent changeset 2
   manifest@?: 3362547cdf64 not in changesets
   manifest@?: rev 3 points to nonexistent changeset 3
   manifest@?: 265a85892ecb not in changesets
  crosschecking files in changesets and manifests
   c@3: in manifest but not in changeset
  checking files
   b@?: rev 1 points to nonexistent changeset 2
   (expected 1)
   c@?: rev 0 points to nonexistent changeset 3
  checked 2 changesets with 4 changes to 3 files
  1 warnings encountered!
  7 integrity errors encountered!
  (first damaged changeset appears to be 3)
  % journal contents
  00changelog.i
  00manifest.i
  data/b.i
  data/c.i
  rolling back interrupted transaction
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 2 files

  $ cd ..
