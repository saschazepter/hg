#testcases skip-detection fail-if-detected

Test situations that "should" only be reproducible:
- on networked filesystems, or
- user using `hg debuglocks` to eliminate the lock file, or
- something (that doesn't respect the lock file) writing to the .hg directory
while we're running


Initial setup
-------------

  $ hg init base-repo
  $ cd base-repo

  $ cat > "$TESTTMP_FORWARD_SLASH/waitlock_editor.sh" <<EOF
  >     [ -n "\${WAITLOCK_ANNOUNCE:-}" ] && touch "\${WAITLOCK_ANNOUNCE}"
  >     f="\${WAITLOCK_FILE}"
  >     start=\`date +%s\`
  >     timeout=20
  >     "$RUNTESTDIR_FORWARD_SLASH/testlib/wait-on-file" "\$timeout" "\$f"
  >     if [ \$# -gt 1 ]; then
  >         cat "\$@"
  >     fi
  > EOF

Things behave differently if we don't already have a 00changelog.i file when
this all starts, so let's make one.

  $ echo r0 > r0
  $ hg commit -qAm 'r0'

  $ cd ..
  $ cp -R base-repo main-client
  $ cp -R base-repo racing-client

  $ mkdir sync
  $ EDITOR_STARTED="$TESTTMP_FORWARD_SLASH/sync/.editor_started"
  $ MISCHIEF_MANAGED="$TESTTMP_FORWARD_SLASH/sync/.mischief_managed"
  $ JOBS_FINISHED="$TESTTMP_FORWARD_SLASH/sync/.jobs_finished"

Actual test
-----------

Start an hg commit that will take a while

  $ cd main-client

#if fail-if-detected
  $ cat >> $HGRCPATH << EOF
  > [debug]
  > revlog.verifyposition.changelog = fail
  > EOF
#endif

  $ echo foo > foo
  $ (
  >    unset HGEDITOR;
  >    WAITLOCK_ANNOUNCE="${EDITOR_STARTED}" \
  >    WAITLOCK_FILE="${MISCHIEF_MANAGED}" \
  >    hg commit -qAm 'r1 (foo)' --edit foo \
  >    --config ui.editor="sh $TESTTMP/waitlock_editor.sh" \
  >    > .foo_commit_out 2>&1 ;\
  >    touch "${JOBS_FINISHED}"
  > ) &

Wait for the "editor" to actually start
  $ sh "$RUNTESTDIR_FORWARD_SLASH/testlib/wait-on-file" 20 "${EDITOR_STARTED}"

Do a concurrent edition
  $ cd ../racing-client
  $ touch ../pre-race
  $ sleep 10
  $ echo bar > bar
  $ hg --repository ../racing-client commit -qAm 'r2 (bar)' bar
  $ hg --repository ../racing-client debugrevlogindex -c
     rev linkrev nodeid       p1           p2
       0       0 222799e2f90b 000000000000 000000000000
       1       1 6f124f6007a0 222799e2f90b 000000000000
  $ hg --repository ../racing-client debugrevlogindex -m
     rev linkrev nodeid       p1           p2
       0       0 7b7020262a56 000000000000 000000000000
       1       1 ad3fe36d86d9 7b7020262a56 000000000000


We simulate an network FS race by overwriting raced repo content with the new
content of the files changed in the racing repository

  $ for x in `find . -type f -newer ../pre-race`; do
  >    cp $x ../main-client/$x
  > done
  $ cd ../main-client

Awaken the editor from that first commit
  $ touch "${MISCHIEF_MANAGED}"
And wait for it to finish
  $ WAITLOCK_FILE="${JOBS_FINISHED}" sh "$TESTTMP_FORWARD_SLASH/waitlock_editor.sh"

#if skip-detection
(Ensure there was no output)
  $ cat .foo_commit_out
And observe a corrupted repository -- rev 2's linkrev is 1, which should never
happen for the changelog (the linkrev should always refer to itself).
  $ hg debugrevlogindex -c
     rev linkrev nodeid       p1           p2
       0       0 222799e2f90b 000000000000 000000000000
       1       1 6f124f6007a0 222799e2f90b 000000000000
       2       1 ac80e6205bb2 222799e2f90b 000000000000

TODO: Figure out why the middle entry is missing on Windows.
  $ hg debugrevlogindex -m
     rev linkrev nodeid       p1           p2
       0       0 7b7020262a56 000000000000 000000000000
       1       1 ad3fe36d86d9 7b7020262a56 000000000000 (no-windows !)
       2       1 d93163bb8ce3 7b7020262a56 000000000000 (no-windows !)
       1       1 d93163bb8ce3 7b7020262a56 000000000000 (windows !)

#endif

#if fail-if-detected
  $ cat .foo_commit_out
  note: commit message saved in .hg/last-message.txt
  note: use 'hg commit --logfile .hg/last-message.txt --edit' to reuse it
  transaction abort!
  rollback completed
  abort: 00changelog.i: file cursor at position 128, expected 64
And no corruption in the changelog.
  $ hg debugrevlogindex -c
     rev linkrev nodeid       p1           p2
       0       0 222799e2f90b 000000000000 000000000000
       1       1 6f124f6007a0 222799e2f90b 000000000000 (missing-correct-output !)

And, because of transactions, there's none in the manifestlog either.

TODO: Figure out why this is different on Windows.
  $ hg debugrevlogindex -m
     rev linkrev nodeid       p1           p2
       0       0 7b7020262a56 000000000000 000000000000
       1       1 ad3fe36d86d9 7b7020262a56 000000000000 (no-windows !)
       1       1 ad3fe36d86d9 7b7020262a56 000000000000 (missing-correct-output windows !)
#endif

