Retrying a push after an authentication challenge
=================================================

When the server lets anonymous users read but asks for authentication on push,
the 401 response is received for the `unbundle` request itself, after its body
has been sent. The retry with credentials must send that body again.

With `httppostargs`, the body combines the command arguments and the bundle,
and that combined body must be rewound before the retry too.

  $ cat > $TESTTMP/pushauth.py << EOF
  > # Small extension to raise credential request only for a request that
  > # contains a body.
  > # This lets the test check that the retry don't forget the body
  > # in the second request
  > import base64
  > from mercurial.hgweb import common
  > def perform_authentication(hgweb, req, op):
  >     if op != b'push':
  >         return
  >     auth = req.headers.get(b'Authorization')
  >     if not auth:
  >         raise common.ErrorResponse(
  >             common.HTTP_UNAUTHORIZED,
  >             b'who',
  >             [(b'WWW-Authenticate', b'Basic Realm="mercurial"')],
  >         )
  >     credentials = base64.b64decode(auth.split()[1]).split(b':', 1)
  >     if credentials != [b'babar', b'celeste']:
  >         raise common.ErrorResponse(common.HTTP_FORBIDDEN, b'no')
  > def extsetup(ui):
  >     common.permhooks.insert(0, perform_authentication)
  > EOF

  $ hg init server
  $ cd server
  $ echo zephir > zephir
  $ hg commit -Aqm 'initial'
  $ cd ..
  $ hg clone -q server client
  $ cd client
  $ echo arthur > arthur
  $ hg commit -Aqm 'second'
  $ cd ..

  $ hg serve -R server \
  >   --config extensions.pushauth=$TESTTMP/pushauth.py \
  >   -p $HGPORT \
  >   -d \
  >   --pid-file=hg.pid \
  >   -A access.log \
  >   -E errors.log \
  >   --config web.push_ssl=False \
  >   --config web.allow_push=* \
  >   --config experimental.httppostargs=yes
  $ cat hg.pid >> $DAEMON_PIDS

Push with credentials
---------------------

Reading is anonymous, so the client only learns that authentication is needed
when the server rejects the `unbundle` request.

  $ hg -R client push http://babar:celeste@localhost:$HGPORT/ \
  >   --config http.timeout=60
  pushing to http://babar:***@localhost:$HGPORT/
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files

  $ killdaemons.py
  $ cat access.log
  $LOCALIP - - [$LOGDATE$] "GET /?cmd=capabilities HTTP/1.1" 200 - (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=batch HTTP/1.1" 200 - x-hgargs-post:68 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=listkeys HTTP/1.1" 200 - x-hgargs-post:16 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=listkeys HTTP/1.1" 200 - x-hgargs-post:19 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET /?cmd=branchmap HTTP/1.1" 200 - x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=listkeys HTTP/1.1" 200 - x-hgargs-post:19 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=unbundle HTTP/1.1" 401 - x-hgargs-post:16 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=unbundle HTTP/1.1" 200 - x-hgargs-post:16 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "POST /?cmd=listkeys HTTP/1.1" 200 - x-hgargs-post:16 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $ cat errors.log | head -n 1
