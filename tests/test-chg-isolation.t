#require chg systemd-run linux-unshare

Timeout copied from test-chg.t.
  $ CHGTIMEOUT=`expr $HGTEST_TIMEOUT / 6`
  $ export CHGTIMEOUT

Create repo
  $ hg init repo
  $ cd repo

Add a file so we have something to grep on
  $ touch the_file
  $ hg add the_file

Enable debug output
  $ CHGDEBUG=
  $ export CHGDEBUG

This deletes all chg sockets, unlike chg --kill-chg-daemon which only deletes
the main one. We need this to isolate test cases from each other. Note that
run-tests.py sets CHGSOCKNAME based on a per-thread temp dir, so this will not
interfere with anything outside this test file.
  $ kill_chg_servers() { rm "$CHGSOCKNAME"-*; }

Demonstrate how server is shared
  $ kill_chg_servers
  $ chg status 2>&1 | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ chg status 2>&1 | grep -E "start|the_file"
  A the_file

Test cgroups
------------

Server is shared within a cgroup
  $ kill_chg_servers
  $ systemd-run --user --scope sh -c 'chg status 2>&1; chg status 2>&1' | grep -E "start|the_file"
  Running *as unit: * (glob)
  chg: debug: * start cmdserver at * (glob)
  A the_file
  A the_file

Server is not shared between cgroups (new, new)
  $ kill_chg_servers
  $ systemd-run --user --scope sh -c 'chg status 2>&1' | grep -E "start|the_file"
  Running *as unit: * (glob)
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ systemd-run --user --scope sh -c 'chg status 2>&1' | grep -E "start|the_file"
  Running *as unit: * (glob)
  chg: debug: * start cmdserver at * (glob)
  A the_file

Server is not shared between cgroups (new, current)
  $ kill_chg_servers
  $ systemd-run --user --scope sh -c 'chg status 2>&1' | grep -E "start|the_file"
  Running *as unit: * (glob)
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ chg status 2>&1 | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file

Server is not shared between cgroups (current, new)
  $ kill_chg_servers
  $ chg status 2>&1 | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ systemd-run --user --scope sh -c 'chg status 2>&1' | grep -E "start|the_file"
  Running *as unit: * (glob)
  chg: debug: * start cmdserver at * (glob)
  A the_file

Test namespaces
---------------

Server is shared within a namespace
  $ kill_chg_servers
  $ unshare --user sh -c 'chg status 2>&1; chg status 2>&1' | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
  A the_file

Server is not shared between namespaces (new, new)
  $ kill_chg_servers
  $ unshare --user sh -c 'chg status 2>&1' | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ unshare --user sh -c 'chg status 2>&1' | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file

Server is not shared between namespaces (new, current)
  $ kill_chg_servers
  $ unshare --user sh -c 'chg status 2>&1' | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ chg status 2>&1 | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file

Server is not shared between namespaces (current, new)
  $ kill_chg_servers
  $ chg status 2>&1 | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
  $ unshare --user sh -c 'chg status 2>&1' | grep -E "start|the_file"
  chg: debug: * start cmdserver at * (glob)
  A the_file
