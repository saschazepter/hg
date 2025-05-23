#require serve ssl

  $ wait_log() {
  >     pattern="$1"
  >     for s in $TESTDIR/seq.py 10; do
  >         if grep "$pattern" $TESTTMP/log > /dev/null ; then
  >             break
  >         fi
  >         sleep 1
  >     done
  > }

Set up SMTP server:

  $ CERTSDIR="$TESTDIR/sslcerts"
  $ cat "$CERTSDIR/priv.pem" "$CERTSDIR/pub.pem" >> server.pem

  $ "$PYTHON" "$TESTDIR/dummysmtpd.py" -p $HGPORT --pid-file a.pid --logfile log -d \
  > --tls smtps --certificate `pwd`/server.pem
  $ cat a.pid >> $DAEMON_PIDS

Set up repository:

  $ hg init t
  $ cd t
  $ cat <<EOF >> .hg/hgrc
  > [extensions]
  > patchbomb =
  > [email]
  > method = smtp
  > [smtp]
  > host = localhost
  > port = $HGPORT
  > tls = smtps
  > EOF

  $ echo a > a
  $ hg commit -Ama -d '1 0'
  adding a

Utility functions:

  $ DISABLECACERTS=
  $ try () {
  >   hg email $DISABLECACERTS -f quux -t foo -c bar -r tip "$@"
  > }

Our test cert is not signed by a trusted CA. It should fail to verify if
we are able to load CA certs:

#if no-defaultcacertsloaded
  $ try
  this patch series consists of 1 patches.
  
  
  (an attempt was made to load CA certificates but none were loaded; see https://mercurial-scm.org/wiki/SecureConnections for how to configure Mercurial to avoid this error)
  (?i)abort: .*?certificate.verify.failed.* (re)
  [255]

  $ wait_log "ssl error:"
  $ cat ../log
  * ssl error: * (glob)
  $ : > ../log

#endif

#if defaultcacertsloaded
  $ try
  this patch series consists of 1 patches.
  
  
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  (?i)abort: .*?certificate.verify.failed.* (re)
  [255]

  $ wait_log "ssl error:"
  $ cat ../log
  * ssl error: * (glob)
  $ : > ../log

#endif

  $ DISABLECACERTS="--config devel.disableloaddefaultcerts=true"

Without certificates:

  $ try --debug
  this patch series consists of 1 patches.
  
  
  (using smtps)
  sending mail: smtp host localhost, port * (glob)
  (verifying remote certificate)
  abort: unable to verify security of localhost (no loaded CA certificates); refusing to connect
  (see https://mercurial-scm.org/wiki/SecureConnections for how to configure Mercurial to avoid this error or set hostsecurity.localhost:fingerprints=sha256:20:de:b3:ad:b4:cd:a5:42:f0:74:41:1c:a2:70:1e:da:6e:c0:5c:16:9e:e7:22:0f:f1:b7:e5:6e:e4:92:af:7e to trust this server)
  [150]

  $ wait_log "no hello:"
  $ cat ../log
  connection from * (glob)
  no hello: (b''|EOF) (re)
  $ : > ../log

With global certificates:

  $ try --debug --config web.cacerts="$CERTSDIR/pub.pem"
  this patch series consists of 1 patches.
  
  
  (using smtps)
  sending mail: smtp host localhost, port * (glob)
  (verifying remote certificate)
  sending [PATCH] a ...

  $ cat ../log
  connection from * (glob)
  * from=quux to=foo, bar (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <*@test-hostname> (glob)
  X-Mercurial-Series-Id: <*@test-hostname> (glob)
  User-Agent: Mercurial-patchbomb* (glob)
  Date: * (glob)
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 0000000000000000000000000000000000000000 -r 8580ff50825a50c8f716709acdf8de0deddcd6ab a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  $ : > ../log

With invalid certificates:

  $ try --config web.cacerts="$CERTSDIR/pub-other.pem"
  this patch series consists of 1 patches.
  
  
  (the full certificate chain may not be available locally; see "hg help debugssl") (windows !)
  (?i)abort: .*?certificate.verify.failed.* (re)
  [255]

  $ wait_log "ssl error:"
  $ cat ../log
  * ssl error: * (glob)
  $ : > ../log

  $ cd ..
