#require serve ssl

Proper https client requires the built-in ssl from Python 2.6.

Disable the system configuration which may set stricter TLS requirements.
This test expects that legacy TLS versions are supported.

  $ OPENSSL_CONF=
  $ export OPENSSL_CONF

Make server certificates:

  $ CERTSDIR="$TESTDIR/sslcerts"
  $ cat "$CERTSDIR/priv.pem" "$CERTSDIR/pub.pem" >> server.pem
  $ PRIV=`pwd`/server.pem
  $ cat "$CERTSDIR/priv.pem" "$CERTSDIR/pub-not-yet.pem" > server-not-yet.pem
  $ cat "$CERTSDIR/priv.pem" "$CERTSDIR/pub-expired.pem" > server-expired.pem

  $ hg init test
  $ cd test
  $ echo foo>foo
  $ mkdir foo.d foo.d/bAr.hg.d foo.d/baR.d.hg
  $ echo foo>foo.d/foo
  $ echo bar>foo.d/bAr.hg.d/BaR
  $ echo bar>foo.d/baR.d.hg/bAR
  $ hg commit -A -m 1
  adding foo
  adding foo.d/bAr.hg.d/BaR
  adding foo.d/baR.d.hg/bAR
  adding foo.d/foo
  $ hg serve -p $HGPORT -d --pid-file=../hg0.pid --certificate=$PRIV
  $ cat ../hg0.pid >> $DAEMON_PIDS

cacert not found

  $ hg in --config web.cacerts=no-such.pem https://localhost:$HGPORT/
  abort: could not find web.cacerts: no-such.pem
  [255]

Test server address cannot be reused

  $ hg serve -p $HGPORT --certificate=$PRIV 2>&1
  abort: cannot start server at 'localhost:$HGPORT': $EADDRINUSE$
  [255]

  $ cd ..

Our test cert is not signed by a trusted CA. It should fail to verify if
we are able to load CA certs.

#if no-defaultcacertsloaded
  $ hg clone https://localhost:$HGPORT/ copy-pull
  (an attempt was made to load CA certificates but none were loaded; see https://mercurial-scm.org/wiki/SecureConnections for how to configure Mercurial to avoid this error)
  abort: error: *certificate verify failed* (glob)
  [100]
#endif

#if defaultcacertsloaded
  $ hg clone https://localhost:$HGPORT/ copy-pull
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]
#endif

Specifying a per-host certificate file that doesn't exist will abort.  The full
C:/path/to/msysroot will print on Windows.

  $ hg --config hostsecurity.localhost:verifycertsfile=/does/not/exist clone https://localhost:$HGPORT/
  abort: path specified by hostsecurity.localhost:verifycertsfile does not exist: */does/not/exist (glob)
  [255]

A malformed per-host certificate file will raise an error

  $ echo baddata > badca.pem
  $ hg --config hostsecurity.localhost:verifycertsfile=badca.pem clone https://localhost:$HGPORT/
  abort: error loading CA file badca.pem: * (glob)
  (file is empty or malformed?)
  [255]

A per-host certificate mismatching the server will fail verification

(modern ssl is able to discern whether the loaded cert is a CA cert)
  $ hg --config hostsecurity.localhost:verifycertsfile="$CERTSDIR/client-cert.pem" clone https://localhost:$HGPORT/
  (an attempt was made to load CA certificates but none were loaded; see https://mercurial-scm.org/wiki/SecureConnections for how to configure Mercurial to avoid this error)
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]

A per-host certificate matching the server's cert will be accepted

  $ hg --config hostsecurity.localhost:verifycertsfile="$CERTSDIR/pub.pem" clone -U https://localhost:$HGPORT/ perhostgood1
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 4 changes to 4 files
  new changesets 8b6053c928fe

A per-host certificate with multiple certs and one matching will be accepted

  $ cat "$CERTSDIR/client-cert.pem" "$CERTSDIR/pub.pem" > perhost.pem
  $ hg --config hostsecurity.localhost:verifycertsfile=perhost.pem clone -U https://localhost:$HGPORT/ perhostgood2
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 4 changes to 4 files
  new changesets 8b6053c928fe

Defining both per-host certificate and a fingerprint will print a warning

  $ hg --config hostsecurity.localhost:verifycertsfile="$CERTSDIR/pub.pem" --config hostsecurity.localhost:fingerprints=sha1:ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03 clone -U https://localhost:$HGPORT/ caandfingerwarning
  (hostsecurity.localhost:verifycertsfile ignored when host fingerprints defined; using host fingerprints for verification)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 4 changes to 4 files
  new changesets 8b6053c928fe

  $ DISABLECACERTS="--config devel.disableloaddefaultcerts=true"

Inability to verify peer certificate will result in abort

  $ hg clone https://localhost:$HGPORT/ copy-pull $DISABLECACERTS
  abort: unable to verify security of localhost (no loaded CA certificates); refusing to connect
  (see https://mercurial-scm.org/wiki/SecureConnections for how to configure Mercurial to avoid this error or set hostsecurity.localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e to trust this server)
  [150]

  $ hg clone --insecure https://localhost:$HGPORT/ copy-pull
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 4 changes to 4 files
  new changesets 8b6053c928fe
  updating to branch default
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg verify -R copy-pull -q
  $ cd test
  $ echo bar > bar
  $ hg commit -A -d '1 0' -m 2
  adding bar
  $ cd ..

pull without cacert

  $ cd copy-pull
  $ cat >> .hg/hgrc <<EOF
  > [hooks]
  > changegroup = sh -c "printenv.py --line changegroup"
  > EOF
  $ hg pull $DISABLECACERTS
  pulling from https://localhost:$HGPORT/
  abort: unable to verify security of localhost (no loaded CA certificates); refusing to connect
  (see https://mercurial-scm.org/wiki/SecureConnections for how to configure Mercurial to avoid this error or set hostsecurity.localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e to trust this server)
  [150]

  $ hg pull --insecure
  pulling from https://localhost:$HGPORT/
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 5fed3813f7f5
  changegroup hook: HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=5fed3813f7f5e1824344fdc9cf8f63bb662c292d
  HG_NODE_LAST=5fed3813f7f5e1824344fdc9cf8f63bb662c292d
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  https://localhost:$HGPORT/
  HG_URL=https://localhost:$HGPORT/
  
  (run 'hg update' to get a working copy)
  $ cd ..

cacert configured in local repo

  $ cp copy-pull/.hg/hgrc copy-pull/.hg/hgrc.bu
  $ echo "[web]" >> copy-pull/.hg/hgrc
  $ echo "cacerts=$CERTSDIR/pub.pem" >> copy-pull/.hg/hgrc
  $ hg -R copy-pull pull
  pulling from https://localhost:$HGPORT/
  searching for changes
  no changes found
  $ mv copy-pull/.hg/hgrc.bu copy-pull/.hg/hgrc

cacert configured globally, also testing expansion of environment
variables in the filename

  $ echo "[web]" >> $HGRCPATH
  $ echo 'cacerts=$P/pub.pem' >> $HGRCPATH
  $ P="$CERTSDIR" hg -R copy-pull pull
  pulling from https://localhost:$HGPORT/
  searching for changes
  no changes found
  $ P="$CERTSDIR" hg -R copy-pull pull --insecure
  pulling from https://localhost:$HGPORT/
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  searching for changes
  no changes found

empty cacert file

  $ touch emptycafile

  $ hg --config web.cacerts=emptycafile -R copy-pull pull
  pulling from https://localhost:$HGPORT/
  abort: error loading CA file emptycafile: * (glob)
  (file is empty or malformed?)
  [255]

cacert mismatch

  $ hg -R copy-pull pull --config web.cacerts="$CERTSDIR/pub.pem" \
  > https://$LOCALIP:$HGPORT/
  pulling from https://*:$HGPORT/ (glob)
  abort: $LOCALIP certificate error: certificate is for localhost (glob)
  (set hostsecurity.$LOCALIP:certfingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e config setting or use --insecure to connect insecurely)
  [150]
  $ hg -R copy-pull pull --config web.cacerts="$CERTSDIR/pub.pem" \
  > https://$LOCALIP:$HGPORT/ --insecure
  pulling from https://*:$HGPORT/ (glob)
  warning: connection security to $LOCALIP is disabled per current settings; communication is susceptible to eavesdropping and tampering (glob)
  searching for changes
  no changes found
  $ hg -R copy-pull pull --config web.cacerts="$CERTSDIR/pub-other.pem"
  pulling from https://localhost:$HGPORT/
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]
  $ hg -R copy-pull pull --config web.cacerts="$CERTSDIR/pub-other.pem" \
  > --insecure
  pulling from https://localhost:$HGPORT/
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  searching for changes
  no changes found

Test server cert which isn't valid yet

  $ hg serve -R test -p $HGPORT1 -d --pid-file=hg1.pid --certificate=server-not-yet.pem
  $ cat hg1.pid >> $DAEMON_PIDS
  $ hg -R copy-pull pull --config web.cacerts="$CERTSDIR/pub-not-yet.pem" \
  > https://localhost:$HGPORT1/
  pulling from https://localhost:$HGPORT1/
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]

Test server cert which no longer is valid

  $ hg serve -R test -p $HGPORT2 -d --pid-file=hg2.pid --certificate=server-expired.pem
  $ cat hg2.pid >> $DAEMON_PIDS
  $ hg -R copy-pull pull --config web.cacerts="$CERTSDIR/pub-expired.pem" \
  > https://localhost:$HGPORT2/
  pulling from https://localhost:$HGPORT2/
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]

Setting ciphers to an invalid value aborts
  $ P="$CERTSDIR" hg --config hostsecurity.ciphers=invalid -R copy-pull id https://localhost:$HGPORT/
  abort: could not set ciphers: No cipher can be selected.
  (change cipher string (invalid) in config)
  [255]

  $ P="$CERTSDIR" hg --config hostsecurity.localhost:ciphers=invalid -R copy-pull id https://localhost:$HGPORT/
  abort: could not set ciphers: No cipher can be selected.
  (change cipher string (invalid) in config)
  [255]

Changing the cipher string works

  $ P="$CERTSDIR" hg --config hostsecurity.ciphers=HIGH -R copy-pull id https://localhost:$HGPORT/
  5fed3813f7f5

Fingerprints

- works without cacerts (hostfingerprints)
  $ hg -R copy-pull id https://localhost:$HGPORT/ --insecure --config hostfingerprints.localhost=ec:d8:7c:d6:b3:86:d0:4f:c1:b8:b4:1c:9d:8f:5e:16:8e:ef:1c:03
  (SHA-1 fingerprint for localhost found in legacy [hostfingerprints] section; if you trust this fingerprint, remove the old SHA-1 fingerprint from [hostfingerprints] and add the following entry to the new [hostsecurity] section: localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e)
  5fed3813f7f5

- works without cacerts (hostsecurity)
  $ hg -R copy-pull id https://localhost:$HGPORT/ --config hostsecurity.localhost:fingerprints=sha1:ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03
  5fed3813f7f5

  $ hg -R copy-pull id https://localhost:$HGPORT/ --config hostsecurity.localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e
  5fed3813f7f5

- multiple fingerprints specified and first matches
  $ hg --config 'hostfingerprints.localhost=ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03, deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' -R copy-pull id https://localhost:$HGPORT/ --insecure
  (SHA-1 fingerprint for localhost found in legacy [hostfingerprints] section; if you trust this fingerprint, remove the old SHA-1 fingerprint from [hostfingerprints] and add the following entry to the new [hostsecurity] section: localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e)
  5fed3813f7f5

  $ hg --config 'hostsecurity.localhost:fingerprints=sha1:ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03, sha1:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' -R copy-pull id https://localhost:$HGPORT/
  5fed3813f7f5

- multiple fingerprints specified and last matches
  $ hg --config 'hostfingerprints.localhost=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef, ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03' -R copy-pull id https://localhost:$HGPORT/ --insecure
  (SHA-1 fingerprint for localhost found in legacy [hostfingerprints] section; if you trust this fingerprint, remove the old SHA-1 fingerprint from [hostfingerprints] and add the following entry to the new [hostsecurity] section: localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e)
  5fed3813f7f5

  $ hg --config 'hostsecurity.localhost:fingerprints=sha1:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef, sha1:ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03' -R copy-pull id https://localhost:$HGPORT/
  5fed3813f7f5

- multiple fingerprints specified and none match

  $ hg --config 'hostfingerprints.localhost=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef, aeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' -R copy-pull id https://localhost:$HGPORT/ --insecure
  abort: certificate for localhost has unexpected fingerprint ec:d8:7c:d6:b3:86:d0:4f:c1:b8:b4:1c:9d:8f:5e:16:8e:ef:1c:03
  (check hostfingerprint configuration)
  [150]

  $ hg --config 'hostsecurity.localhost:fingerprints=sha1:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef, sha1:aeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' -R copy-pull id https://localhost:$HGPORT/
  abort: certificate for localhost has unexpected fingerprint sha1:ec:d8:7c:d6:b3:86:d0:4f:c1:b8:b4:1c:9d:8f:5e:16:8e:ef:1c:03
  (check hostsecurity configuration)
  [150]

- fails when cert doesn't match hostname (port is ignored)
  $ hg -R copy-pull id https://localhost:$HGPORT1/ --config hostfingerprints.localhost=ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03
  abort: certificate for localhost has unexpected fingerprint f4:2f:5a:0c:3e:52:5b:db:e7:24:a8:32:1d:18:97:6d:69:b5:87:84
  (check hostfingerprint configuration)
  [150]


- ignores that certificate doesn't match hostname
  $ hg -R copy-pull id https://$LOCALIP:$HGPORT/ --config hostfingerprints.$LOCALIP=ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03
  (SHA-1 fingerprint for $LOCALIP found in legacy [hostfingerprints] section; if you trust this fingerprint, remove the old SHA-1 fingerprint from [hostfingerprints] and add the following entry to the new [hostsecurity] section: $LOCALIP:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e)
  5fed3813f7f5

Ports used by next test. Kill servers.

  $ killdaemons.py $DAEMON_PIDS

#if tls1.2
Start servers running supported TLS versions

  $ cd test
  $ hg serve -p $HGPORT -d --pid-file=../hg0.pid --certificate=$PRIV \
  > --config devel.server-insecure-exact-protocol=tls1.0
  $ cat ../hg0.pid >> $DAEMON_PIDS
  $ hg serve -p $HGPORT1 -d --pid-file=../hg1.pid --certificate=$PRIV \
  > --config devel.server-insecure-exact-protocol=tls1.1
  $ cat ../hg1.pid >> $DAEMON_PIDS
  $ hg serve -p $HGPORT2 -d --pid-file=../hg2.pid --certificate=$PRIV \
  > --config devel.server-insecure-exact-protocol=tls1.2
  $ cat ../hg2.pid >> $DAEMON_PIDS
#if tls1.3
  $ hg serve -p $HGPORT3 -d --pid-file=../hg3.pid --certificate=$PRIV \
  > --config devel.server-insecure-exact-protocol=tls1.3
  $ cat ../hg3.pid >> $DAEMON_PIDS
#endif
  $ cd ..

Clients talking same TLS versions work

  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.0 --config hostsecurity.ciphers="DEFAULT:@SECLEVEL=0" id https://localhost:$HGPORT/
  5fed3813f7f5
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.1 --config hostsecurity.ciphers="DEFAULT:@SECLEVEL=0" id https://localhost:$HGPORT1/
  5fed3813f7f5
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.2 id https://localhost:$HGPORT2/
  5fed3813f7f5
#if tls1.3
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.3 id https://localhost:$HGPORT3/
  5fed3813f7f5
#endif

Clients requiring newer TLS version than what server supports fail

  $ P="$CERTSDIR" hg id https://localhost:$HGPORT/
  (could not negotiate a common security protocol (tls1.2+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]

  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.1 id https://localhost:$HGPORT/
  (could not negotiate a common security protocol (tls1.1+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.2 id https://localhost:$HGPORT/
  (could not negotiate a common security protocol (tls1.2+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.2 id https://localhost:$HGPORT1/
  (could not negotiate a common security protocol (tls1.2+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]

#if tls1.3
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.3 id https://localhost:$HGPORT/
  (could not negotiate a common security protocol (tls1.3+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.3 id https://localhost:$HGPORT1/
  (could not negotiate a common security protocol (tls1.3+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]
  $ P="$CERTSDIR" hg --config hostsecurity.minimumprotocol=tls1.3 id https://localhost:$HGPORT2/
  (could not negotiate a common security protocol (tls1.3+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]
#endif


--insecure will allow TLS 1.0 connections and override configs

  $ hg --config hostsecurity.minimumprotocol=tls1.2 id --insecure https://localhost:$HGPORT1/
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  5fed3813f7f5

#if tls1.3
  $ hg --config hostsecurity.minimumprotocol=tls1.3 id --insecure https://localhost:$HGPORT2/
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  5fed3813f7f5
#endif

The per-host config option overrides the default

  $ P="$CERTSDIR" hg id https://localhost:$HGPORT/ \
  > --config hostsecurity.ciphers="DEFAULT:@SECLEVEL=0" \
  > --config hostsecurity.minimumprotocol=tls1.2 \
  > --config hostsecurity.localhost:minimumprotocol=tls1.0
  5fed3813f7f5

The per-host config option by itself works

  $ P="$CERTSDIR" hg id https://localhost:$HGPORT/ \
  > --config hostsecurity.localhost:minimumprotocol=tls1.2
  (could not negotiate a common security protocol (tls1.2+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]

.hg/hgrc file [hostsecurity] settings are applied to remote ui instances (issue5305)

  $ cat >> copy-pull/.hg/hgrc << EOF
  > [hostsecurity]
  > localhost:minimumprotocol=tls1.2
  > EOF
  $ P="$CERTSDIR" hg -R copy-pull id https://localhost:$HGPORT/
  (could not negotiate a common security protocol (tls1.2+) with localhost; the likely cause is Mercurial is configured to be more secure than the server can support)
  (consider contacting the operator of this server and ask them to support modern TLS protocol versions; or, set hostsecurity.localhost:minimumprotocol=tls1.0 to allow use of legacy, less secure protocols when communicating with this server)
  (see https://mercurial-scm.org/wiki/SecureConnections for more info)
  abort: error: .*(unsupported protocol|wrong ssl version|alert protocol version).* (re)
  [100]

  $ killdaemons.py $DAEMON_PIDS
#endif

Prepare for connecting through proxy

  $ hg serve -R test -p $HGPORT -d --pid-file=hg0.pid --certificate=$PRIV
  $ cat hg0.pid >> $DAEMON_PIDS
  $ hg serve -R test -p $HGPORT2 -d --pid-file=hg2.pid --certificate=server-expired.pem
  $ cat hg2.pid >> $DAEMON_PIDS
tinyproxy.py doesn't fully detach, so killing it may result in extra output
from the shell. So don't kill it.
  $ tinyproxy.py $HGPORT1 localhost >proxy.log </dev/null 2>&1 &
  $ while [ ! -f proxy.pid ]; do sleep 0; done
  $ cat proxy.pid >> $DAEMON_PIDS

  $ echo "[http_proxy]" >> copy-pull/.hg/hgrc
  $ echo "always=True" >> copy-pull/.hg/hgrc
  $ echo "[hostfingerprints]" >> copy-pull/.hg/hgrc
  $ echo "localhost =" >> copy-pull/.hg/hgrc

Test unvalidated https through proxy

  $ http_proxy=http://localhost:$HGPORT1/ hg -R copy-pull pull --insecure
  pulling from https://localhost:$HGPORT/
  warning: connection security to localhost is disabled per current settings; communication is susceptible to eavesdropping and tampering
  searching for changes
  no changes found

Test https with cacert and fingerprint through proxy

  $ http_proxy=http://localhost:$HGPORT1/ hg -R copy-pull pull \
  > --config web.cacerts="$CERTSDIR/pub.pem"
  pulling from https://localhost:$HGPORT/
  searching for changes
  no changes found
  $ http_proxy=http://localhost:$HGPORT1/ hg -R copy-pull pull https://localhost:$HGPORT/ --config hostfingerprints.localhost=ecd87cd6b386d04fc1b8b41c9d8f5e168eef1c03 --trace
  pulling from https://*:$HGPORT/ (glob)
  (SHA-1 fingerprint for localhost found in legacy [hostfingerprints] section; if you trust this fingerprint, remove the old SHA-1 fingerprint from [hostfingerprints] and add the following entry to the new [hostsecurity] section: localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e)
  searching for changes
  no changes found

Test https with cert problems through proxy

  $ http_proxy=http://localhost:$HGPORT1/ hg -R copy-pull pull \
  > --config web.cacerts="$CERTSDIR/pub-other.pem"
  pulling from https://localhost:$HGPORT/
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]
  $ http_proxy=http://localhost:$HGPORT1/ hg -R copy-pull pull \
  > --config web.cacerts="$CERTSDIR/pub-expired.pem" https://localhost:$HGPORT2/
  pulling from https://localhost:$HGPORT2/
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  abort: error: *certificate verify failed* (glob)
  [100]

Test when proxy can't connect to server

  $ http_proxy=http://localhost:$HGPORT1/ hg -R copy-pull pull --insecure https://localhost:0/
  pulling from https://localhost:0/
  abort: error: Tunnel connection failed: 404 (\$ECONNREFUSED\$|\$EADDRNOTAVAIL\$) (re)
  [100]


  $ killdaemons.py hg0.pid

  $ cd test

Missing certificate file(s) are detected

  $ hg serve -p $HGPORT --certificate=/missing/certificate \
  > --config devel.servercafile=$PRIV --config devel.serverrequirecert=true
  abort: referenced certificate file (*/missing/certificate) does not exist (glob)
  [255]

  $ hg serve -p $HGPORT --certificate=$PRIV \
  > --config devel.servercafile=/missing/cafile --config devel.serverrequirecert=true
  abort: referenced certificate file (*/missing/cafile) does not exist (glob)
  [255]

Start hgweb that requires client certificates:

  $ hg serve -p $HGPORT -d --pid-file=../hg0.pid --certificate=$PRIV \
  > --config devel.servercafile=$PRIV --config devel.serverrequirecert=true
  $ cat ../hg0.pid >> $DAEMON_PIDS
  $ cd ..

without client certificate:

  $ P="$CERTSDIR" hg id https://localhost:$HGPORT/
  abort: error: .*(\$ECONNRESET\$|certificate required|handshake failure|EOF occurred).* (re)
  [100]

with client certificate:

  $ cat << EOT >> $HGRCPATH
  > [auth]
  > l.prefix = localhost
  > l.cert = $CERTSDIR/client-cert.pem
  > l.key = $CERTSDIR/client-key.pem
  > EOT

  $ P="$CERTSDIR" hg id https://localhost:$HGPORT/ \
  > --config auth.l.key="$CERTSDIR/client-key-decrypted.pem"
  5fed3813f7f5

  $ printf '1234\n' | env P="$CERTSDIR" hg id https://localhost:$HGPORT/ \
  > --config ui.interactive=True --config ui.nontty=True
  passphrase for */client-key.pem: 5fed3813f7f5 (glob)

  $ env P="$CERTSDIR" hg id https://localhost:$HGPORT/
  abort: error: * (glob)
  [100]

Missing certficate and key files result in error

  $ hg id https://localhost:$HGPORT/ --config auth.l.cert=/missing/cert
  abort: certificate file (*/missing/cert) does not exist; cannot connect to localhost (glob)
  (restore missing file or fix references in Mercurial config)
  [255]

  $ hg id https://localhost:$HGPORT/ --config auth.l.key=/missing/key
  abort: certificate file (*/missing/key) does not exist; cannot connect to localhost (glob)
  (restore missing file or fix references in Mercurial config)
  [255]
