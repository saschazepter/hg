#require no-chg

persistent-nodemap is not enabled by default. It is not relevant for this test
so disable it.

  $ . $TESTDIR/wireprotohelpers.sh

  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-persistent-nodemap = no
  > [web]
  > push_ssl = false
  > allow_push = *
  > EOF

  $ hg init server
  $ cd server
  $ touch a
  $ hg -q commit -A -m initial
  $ cd ..

  $ hg serve -R server -p $HGPORT -d --pid-file hg.pid
  $ cat hg.pid >> $DAEMON_PIDS

compression formats are advertised in compression capability

#if zstd
  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=capabilities' | tr ' ' '\n' | grep '^compression=zstd,zlib$' > /dev/null
#else
  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=capabilities' | tr ' ' '\n' | grep '^compression=zlib$' > /dev/null
#endif

  $ killdaemons.py

server.compressionengines can replace engines list wholesale

  $ hg serve --config server.compressionengines=none -R server -p $HGPORT -d --pid-file hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=capabilities' | tr ' ' '\n' | grep '^compression=none$' > /dev/null

  $ killdaemons.py

Order of engines can also change

  $ hg serve --config server.compressionengines=none,zlib -R server -p $HGPORT -d --pid-file hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=capabilities' | tr ' ' '\n' | grep '^compression=none,zlib$' > /dev/null

  $ killdaemons.py

Start a default server again

  $ hg serve -R server -p $HGPORT -d --pid-file hg.pid
  $ cat hg.pid > $DAEMON_PIDS

Server should send application/mercurial-0.1 to clients if no Accept is used

  $ get-with-headers.py --headeronly $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' -
  200 Script output follows
  content-type: application/mercurial-0.1
  date: $HTTP_DATE$
  server: testing stub value
  transfer-encoding: chunked

Server should send application/mercurial-0.1 when client says it wants it

  $ get-with-headers.py --hgproto '0.1' --headeronly $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' -
  200 Script output follows
  content-type: application/mercurial-0.1
  date: $HTTP_DATE$
  server: testing stub value
  transfer-encoding: chunked

Server should send application/mercurial-0.2 when client says it wants it

  $ get-with-headers.py --hgproto '0.2' --headeronly $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' -
  200 Script output follows
  content-type: application/mercurial-0.2
  date: $HTTP_DATE$
  server: testing stub value
  transfer-encoding: chunked

  $ get-with-headers.py --hgproto '0.1 0.2' --headeronly $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' -
  200 Script output follows
  content-type: application/mercurial-0.2
  date: $HTTP_DATE$
  server: testing stub value
  transfer-encoding: chunked

Requesting a compression format that server doesn't support results will fall back to 0.1

  $ get-with-headers.py --hgproto '0.2 comp=aa' --headeronly $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' -
  200 Script output follows
  content-type: application/mercurial-0.1
  date: $HTTP_DATE$
  server: testing stub value
  transfer-encoding: chunked

#if zstd
zstd is used if available

  $ get-with-headers.py --hgproto '0.2 comp=zstd' $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' > resp
  $ f --size --hexdump --bytes 36 --sha1 resp
  resp: size=248, sha1=f11b5c098c638068b3d5fe2f9e6241bf5228
  0000: 32 30 30 20 53 63 72 69 70 74 20 6f 75 74 70 75 |200 Script outpu|
  0010: 74 20 66 6f 6c 6c 6f 77 73 0a 0a 04 7a 73 74 64 |t follows...zstd|
  0020: 28 b5 2f fd                                     |(./.|

#endif

application/mercurial-0.2 is not yet used on non-streaming responses

  $ get-with-headers.py --hgproto '0.2' $LOCALIP:$HGPORT '?cmd=heads' -
  200 Script output follows
  content-length: 41
  content-type: application/mercurial-0.1
  date: $HTTP_DATE$
  server: testing stub value
  
  e93700bd72895c5addab234c56d4024b487a362f

Now test protocol preference usage

  $ killdaemons.py
  $ hg serve --config server.compressionengines=none,zlib -R server -p $HGPORT -d --pid-file hg.pid
  $ cat hg.pid > $DAEMON_PIDS

No Accept will send 0.1+zlib, even though "none" is preferred b/c "none" isn't supported on 0.1

  $ get-with-headers.py --headeronly $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000' Content-Type
  200 Script output follows
  content-type: application/mercurial-0.1

  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000'  > resp
  $ f --size --hexdump --bytes 28 --sha1 resp
  resp: size=227, sha1=35a4c074da74f32f5440da3cbf04
  0000: 32 30 30 20 53 63 72 69 70 74 20 6f 75 74 70 75 |200 Script outpu|
  0010: 74 20 66 6f 6c 6c 6f 77 73 0a 0a 78             |t follows..x|

Explicit 0.1 will send zlib because "none" isn't supported on 0.1

  $ get-with-headers.py --hgproto '0.1' $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000'  > resp
  $ f --size --hexdump --bytes 28 --sha1 resp
  resp: size=227, sha1=35a4c074da74f32f5440da3cbf04
  0000: 32 30 30 20 53 63 72 69 70 74 20 6f 75 74 70 75 |200 Script outpu|
  0010: 74 20 66 6f 6c 6c 6f 77 73 0a 0a 78             |t follows..x|

0.2 with no compression will get "none" because that is server's preference
(spec says ZL and UN are implicitly supported)

  $ get-with-headers.py --hgproto '0.2' $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000'  > resp
  $ f --size --hexdump --bytes 32 --sha1 resp
  resp: size=432, sha1=ac931b412ec185a02e0e5bcff98dac83
  0000: 32 30 30 20 53 63 72 69 70 74 20 6f 75 74 70 75 |200 Script outpu|
  0010: 74 20 66 6f 6c 6c 6f 77 73 0a 0a 04 6e 6f 6e 65 |t follows...none|

Client receives server preference even if local order doesn't match

  $ get-with-headers.py --hgproto '0.2 comp=zlib,none' $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000'  > resp
  $ f --size --hexdump --bytes 32 --sha1 resp
  resp: size=432, sha1=ac931b412ec185a02e0e5bcff98dac83
  0000: 32 30 30 20 53 63 72 69 70 74 20 6f 75 74 70 75 |200 Script outpu|
  0010: 74 20 66 6f 6c 6c 6f 77 73 0a 0a 04 6e 6f 6e 65 |t follows...none|

Client receives only supported format even if not server preferred format

  $ get-with-headers.py --hgproto '0.2 comp=zlib' $LOCALIP:$HGPORT '?cmd=getbundle&heads=e93700bd72895c5addab234c56d4024b487a362f&common=0000000000000000000000000000000000000000'  > resp
  $ f --size --hexdump --bytes 33 --sha1 resp
  resp: size=232, sha1=a1c727f0c9693ca15742a75c30419bc36
  0000: 32 30 30 20 53 63 72 69 70 74 20 6f 75 74 70 75 |200 Script outpu|
  0010: 74 20 66 6f 6c 6c 6f 77 73 0a 0a 04 7a 6c 69 62 |t follows...zlib|
  0020: 78                                              |x|

  $ killdaemons.py
  $ cd ..

Test listkeys for listing namespaces

  $ hg init empty
  $ hg -R empty serve -p $HGPORT -d --pid-file hg.pid
  $ cat hg.pid > $DAEMON_PIDS

  $ hg --verbose debugwireproto http://$LOCALIP:$HGPORT << EOF
  > command listkeys
  >     namespace namespaces
  > EOF
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: *\r\n (glob)
  s>     \r\n
  s>     batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset compression=\$BUNDLE2_COMPRESSIONS\$ getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash (re)
  sending listkeys command
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /?cmd=listkeys HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     vary: X-HgArg-1,X-HgProto-1\r\n
  s>     x-hgarg-1: namespace=namespaces\r\n
  s>     x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: 30\r\n
  s>     \r\n
  s>     bookmarks\t\n
  s>     namespaces\t\n
  s>     phases\t
  response: {
    b'bookmarks': b'',
    b'namespaces': b'',
    b'phases': b''
  }
  (sent 2 HTTP requests and * bytes; received * bytes in responses) (glob)

Same thing, but with "httprequest" command

  $ hg --verbose debugwireproto --peer raw http://$LOCALIP:$HGPORT << EOF
  > httprequest GET ?cmd=listkeys
  >     user-agent: test
  >     x-hgarg-1: namespace=namespaces
  > EOF
  using raw connection to peer
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /?cmd=listkeys HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     user-agent: test\r\n
  s>     x-hgarg-1: namespace=namespaces\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: 30\r\n
  s>     \r\n
  s>     bookmarks\t\n
  s>     namespaces\t\n
  s>     phases\t
  $ killdaemons.py

HTTP client follows HTTP redirect on handshake to new repo

  $ cd $TESTTMP

  $ hg init redirector
  $ hg init redirected
  $ cd redirected
  $ touch foo
  $ hg -q commit -A -m initial
  $ cd ..

  $ cat > paths.conf << EOF
  > [paths]
  > / = $TESTTMP/*
  > EOF

  $ cat > redirectext.py << EOF
  > from mercurial import extensions, wireprotoserver
  > def wrappedcallhttp(orig, repo, req, res, proto, cmd):
  >     path = req.advertisedurl[len(req.advertisedbaseurl):]
  >     if not path.startswith(b'/redirector'):
  >         return orig(repo, req, res, proto, cmd)
  >     relpath = path[len(b'/redirector'):]
  >     res.status = b'301 Redirect'
  >     newurl = b'%s/redirected%s' % (req.baseurl, relpath)
  >     if not repo.ui.configbool(b'testing', b'redirectqs', True) and b'?' in newurl:
  >         newurl = newurl[0:newurl.index(b'?')]
  >     res.headers[b'Location'] = newurl
  >     res.headers[b'Content-Type'] = b'text/plain'
  >     res.setbodybytes(b'redirected')
  >     return True
  > 
  > extensions.wrapfunction(wireprotoserver, '_callhttp', wrappedcallhttp)
  > EOF

  $ hg --config extensions.redirect=$TESTTMP/redirectext.py \
  >    --config server.compressionengines=zlib \
  >     serve --web-conf paths.conf --pid-file hg.pid -p $HGPORT -d
  $ cat hg.pid > $DAEMON_PIDS

Verify our HTTP 301 is served properly

  $ hg --verbose debugwireproto --peer raw http://$LOCALIP:$HGPORT << EOF
  > httprequest GET /redirector?cmd=capabilities
  >     user-agent: test
  > EOF
  using raw connection to peer
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirector?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     user-agent: test\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 301 Redirect\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Location: http://$LOCALIP:$HGPORT/redirected?cmd=capabilities\r\n (glob)
  s>     Content-Type: text/plain\r\n
  s>     Content-Length: 10\r\n
  s>     \r\n
  s>     redirected
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     user-agent: test\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: \d+\\r\\n (re)
  s>     \r\n
  s>     batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset compression=\$BUNDLE2_COMPRESSIONS\$ getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash (re)

Test with the HTTP peer

  $ hg --verbose debugwireproto http://$LOCALIP:$HGPORT/redirector << EOF
  > command heads
  > EOF
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirector?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 301 Redirect\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Location: http://$LOCALIP:$HGPORT/redirected?cmd=capabilities\r\n (glob)
  s>     Content-Type: text/plain\r\n
  s>     Content-Length: 10\r\n
  s>     \r\n
  s>     redirected
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: \d+\\r\\n (re)
  s>     \r\n
  real URL is http://$LOCALIP:$HGPORT/redirected (glob)
  s>     batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset compression=\$BUNDLE2_COMPRESSIONS\$ getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash (re)
  sending heads command
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected?cmd=heads HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     vary: X-HgProto-1\r\n
  s>     x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: 41\r\n
  s>     \r\n
  s>     96ee1d7354c4ad7372047672c36a1f561e3a6a4c\n
  response: [
    b'\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL'
  ]
  (sent 3 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ killdaemons.py

Now test a variation where we strip the query string from the redirect URL.
(SCM Manager apparently did this and clients would recover from it)

  $ hg --config extensions.redirect=$TESTTMP/redirectext.py \
  >    --config server.compressionengines=zlib \
  >    --config testing.redirectqs=false \
  >     serve --web-conf paths.conf --pid-file hg.pid -p $HGPORT -d
  $ cat hg.pid > $DAEMON_PIDS

  $ hg --verbose debugwireproto --peer raw http://$LOCALIP:$HGPORT << EOF
  > httprequest GET /redirector?cmd=capabilities
  >     user-agent: test
  > EOF
  using raw connection to peer
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirector?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     user-agent: test\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 301 Redirect\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Location: http://$LOCALIP:$HGPORT/redirected\r\n (glob)
  s>     Content-Type: text/plain\r\n
  s>     Content-Length: 10\r\n
  s>     \r\n
  s>     redirected
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     user-agent: test\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     ETag: W/"*"\r\n (glob)
  s>     Content-Type: text/html; charset=ascii\r\n
  s>     Transfer-Encoding: chunked\r\n
  s>     \r\n
  s>     414\r\n
  s>     <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n
  s>     <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en-US">\n
  s>     <head>\n
  s>     <link rel="icon" href="/redirected/static/hgicon.png" type="image/png" />\n
  s>     <meta name="robots" content="index, nofollow" />\n
  s>     <link rel="stylesheet" href="/redirected/static/style-paper.css" type="text/css" />\n
  s>     <script type="text/javascript" src="/redirected/static/mercurial.js"></script>\n
  s>     \n
  s>     <title>redirected: log</title>\n
  s>     <link rel="alternate" type="application/atom+xml"\n
  s>        href="/redirected/atom-log" title="Atom feed for redirected" />\n
  s>     <link rel="alternate" type="application/rss+xml"\n
  s>        href="/redirected/rss-log" title="RSS feed for redirected" />\n
  s>     </head>\n
  s>     <body>\n
  s>     \n
  s>     <div class="container">\n
  s>     <div class="menu">\n
  s>     <div class="logo">\n
  s>     <a href="https://mercurial-scm.org/">\n
  s>     <img src="/redirected/static/hglogo.png" alt="mercurial" /></a>\n
  s>     </div>\n
  s>     <ul>\n
  s>     <li class="active">log</li>\n
  s>     <li><a href="/redirected/graph/tip">graph</a></li>\n
  s>     <li><a href="/redirected/tags">tags</a></li>\n
  s>     <li><a href="
  s>     \r\n
  s>     810\r\n
  s>     /redirected/bookmarks">bookmarks</a></li>\n
  s>     <li><a href="/redirected/branches">branches</a></li>\n
  s>     </ul>\n
  s>     <ul>\n
  s>     <li><a href="/redirected/rev/tip">changeset</a></li>\n
  s>     <li><a href="/redirected/file/tip">browse</a></li>\n
  s>     </ul>\n
  s>     <ul>\n
  s>     \n
  s>     </ul>\n
  s>     <ul>\n
  s>      <li><a href="/redirected/help">help</a></li>\n
  s>     </ul>\n
  s>     <div class="atom-logo">\n
  s>     <a href="/redirected/atom-log" title="subscribe to atom feed">\n
  s>     <img class="atom-logo" src="/redirected/static/feed-icon-14x14.png" alt="atom feed" />\n
  s>     </a>\n
  s>     </div>\n
  s>     </div>\n
  s>     \n
  s>     <div class="main">\n
  s>     <h2 class="breadcrumb"><a href="/">Mercurial</a> &gt; <a href="/redirected">redirected</a> </h2>\n
  s>     <h3>log</h3>\n
  s>     \n
  s>     \n
  s>     <form class="search" action="/redirected/log">\n
  s>     \n
  s>     <p><input name="rev" id="search1" type="text" size="30" value="" /></p>\n
  s>     <div id="hint">Find changesets by keywords (author, files, the commit message), revision\n
  s>     number or hash, or <a href="/redirected/help/revsets">revset expression</a>.</div>\n
  s>     </form>\n
  s>     \n
  s>     <div class="navigate">\n
  s>     <a href="/redirected/shortlog/tip?revcount=30">less</a>\n
  s>     <a href="/redirected/shortlog/tip?revcount=120">more</a>\n
  s>     | rev 0: <a href="/redirected/shortlog/96ee1d7354c4">(0)</a> <a href="/redirected/shortlog/tip">tip</a> \n
  s>     </div>\n
  s>     \n
  s>     <table class="bigtable">\n
  s>     <thead>\n
  s>      <tr>\n
  s>       <th class="age">age</th>\n
  s>       <th class="author">author</th>\n
  s>       <th class="description">description</th>\n
  s>      </tr>\n
  s>     </thead>\n
  s>     <tbody class="stripes2">\n
  s>      <tr>\n
  s>       <td class="age">Thu, 01 Jan 1970 00:00:00 +0000</td>\n
  s>       <td class="author">test</td>\n
  s>       <td class="description">\n
  s>        <a href="/redirected/rev/96ee1d7354c4">initial</a>\n
  s>        <span class="phase">draft</span> <span class="branchhead">default</span> <span class="tag">tip</span> \n
  s>       </td>\n
  s>      </tr>\n
  s>     \n
  s>     </tbody>\n
  s>     </table>\n
  s>     \n
  s>     <div class="navigate">\n
  s>     <a href="/redirected/shortlog/tip?revcount=30">less</a>\n
  s>     <a href="/redirected/shortlog/tip?revcount=120">more</a>\n
  s>     | rev 0: <a href="/redirected/shortlog/96ee1d7354c4">(0)</a> <a href="/redirected/shortlog/tip">tip</a> \n
  s>     </div>\n
  s>     \n
  s>     <script type="text/javascript">\n
  s>         ajaxScrollInit(\n
  s>                 \'/redirected/shortlog/%next%\',\n
  s>                 \'\', <!-- NEXTHASH\n
  s>                 function (htmlText) {
  s>     \r\n
  s>     14a\r\n
  s>     \n
  s>                     var m = htmlText.match(/\'(\\w+)\', <!-- NEXTHASH/);\n
  s>                     return m ? m[1] : null;\n
  s>                 },\n
  s>                 \'.bigtable > tbody\',\n
  s>                 \'<tr class="%class%">\\\n
  s>                 <td colspan="3" style="text-align: center;">%text%</td>\\\n
  s>                 </tr>\'\n
  s>         );\n
  s>     </script>\n
  s>     \n
  s>     </div>\n
  s>     </div>\n
  s>     \n
  s>     \n
  s>     \n
  s>     </body>\n
  s>     </html>\n
  s>     \n
  s>     \r\n
  s>     0\r\n
  s>     \r\n

  $ hg --verbose debugwireproto http://$LOCALIP:$HGPORT/redirector << EOF
  > command heads
  > EOF
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirector?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 301 Redirect\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Location: http://$LOCALIP:$HGPORT/redirected\r\n (glob)
  s>     Content-Type: text/plain\r\n
  s>     Content-Length: 10\r\n
  s>     \r\n
  s>     redirected
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     ETag: W/"*"\r\n (glob)
  s>     Content-Type: text/html; charset=ascii\r\n
  s>     Transfer-Encoding: chunked\r\n
  s>     \r\n
  real URL is http://$LOCALIP:$HGPORT/redirected (glob)
  s>     414\r\n
  s>     <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n
  s>     <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en-US">\n
  s>     <head>\n
  s>     <link rel="icon" href="/redirected/static/hgicon.png" type="image/png" />\n
  s>     <meta name="robots" content="index, nofollow" />\n
  s>     <link rel="stylesheet" href="/redirected/static/style-paper.css" type="text/css" />\n
  s>     <script type="text/javascript" src="/redirected/static/mercurial.js"></script>\n
  s>     \n
  s>     <title>redirected: log</title>\n
  s>     <link rel="alternate" type="application/atom+xml"\n
  s>        href="/redirected/atom-log" title="Atom feed for redirected" />\n
  s>     <link rel="alternate" type="application/rss+xml"\n
  s>        href="/redirected/rss-log" title="RSS feed for redirected" />\n
  s>     </head>\n
  s>     <body>\n
  s>     \n
  s>     <div class="container">\n
  s>     <div class="menu">\n
  s>     <div class="logo">\n
  s>     <a href="https://mercurial-scm.org/">\n
  s>     <img src="/redirected/static/hglogo.png" alt="mercurial" /></a>\n
  s>     </div>\n
  s>     <ul>\n
  s>     <li class="active">log</li>\n
  s>     <li><a href="/redirected/graph/tip">graph</a></li>\n
  s>     <li><a href="/redirected/tags">tags</a
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected?cmd=capabilities HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: \d+\\r\\n (re)
  s>     \r\n
  real URL is http://$LOCALIP:$HGPORT/redirected (glob)
  s>     batch branchmap \$USUAL_BUNDLE2_CAPS\$ changegroupsubset compression=\$BUNDLE2_COMPRESSIONS\$ getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=[^ ,]+(,[^ ,]+)* unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash (re)
  sending heads command
  s> setsockopt(6, 1, 1) -> None (?)
  s>     GET /redirected?cmd=heads HTTP/1.1\r\n
  s>     Accept-Encoding: identity\r\n
  s>     vary: X-HgProto-1\r\n
  s>     x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  s>     accept: application/mercurial-0.1\r\n
  s>     host: $LOCALIP:$HGPORT\r\n (glob)
  s>     user-agent: Mercurial debugwireproto\r\n
  s>     \r\n
  s> makefile('rb', None)
  s>     HTTP/1.1 200 Script output follows\r\n
  s>     Server: testing stub value\r\n
  s>     Date: $HTTP_DATE$\r\n
  s>     Content-Type: application/mercurial-0.1\r\n
  s>     Content-Length: 41\r\n
  s>     \r\n
  s>     96ee1d7354c4ad7372047672c36a1f561e3a6a4c\n
  response: [
    b'\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL'
  ]
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)
