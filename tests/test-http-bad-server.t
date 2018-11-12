#require serve zstd

Client version is embedded in HTTP request and is effectively dynamic. Pin the
version so behavior is deterministic.

  $ cat > fakeversion.py << EOF
  > from mercurial import util
  > util.version = lambda: '4.2'
  > EOF

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > fakeversion = `pwd`/fakeversion.py
  > [format]
  > sparse-revlog = no
  > [devel]
  > legacy.exchange = phases
  > EOF

  $ hg init server0
  $ cd server0
  $ touch foo
  $ hg -q commit -A -m initial

Also disable compression because zstd is optional and causes output to vary
and because debugging partial responses is hard when compression is involved

  $ cat > .hg/hgrc << EOF
  > [extensions]
  > badserver = $TESTDIR/badserverext.py
  > [server]
  > compressionengines = none
  > EOF

Failure to accept() socket should result in connection related error message

  $ hg serve --config badserver.closebeforeaccept=true -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: $ECONNRESET$ (?)
  abort: error: $EADDRNOTAVAIL$ (?)
  [255]

(The server exits on its own, but there is a race between that and starting a new server.
So ensure the process is dead.)

  $ killdaemons.py $DAEMON_PIDS

Failure immediately after accept() should yield connection related error message

  $ hg serve --config badserver.closeafteraccept=true -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS

TODO: this usually outputs good results, but sometimes emits abort:
error: '' on FreeBSD and OS X.
What we ideally want are:

abort: error: $ECONNRESET$

The flakiness in this output was observable easily with
--runs-per-test=20 on macOS 10.12 during the freeze for 4.2.
  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: * (glob)
  [255]

  $ killdaemons.py $DAEMON_PIDS

Failure to read all bytes in initial HTTP request should yield connection related error message

  $ hg serve --config badserver.closeafterrecvbytes=1 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: bad HTTP status line: ''
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(1 from 65537) -> (1) G
  read limit reached; closing socket

  $ rm -f error.log

Same failure, but server reads full HTTP request line

  $ hg serve --config badserver.closeafterrecvbytes=40 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS
  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: bad HTTP status line: ''
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(40 from 65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(7 from -1) -> (7) Accept-
  read limit reached; closing socket

  $ rm -f error.log

Failure on subsequent HTTP request on the same socket (cmd?batch)

  $ hg serve --config badserver.closeafterrecvbytes=210,223 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS
  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: bad HTTP status line: ''
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(210 from 65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(177 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(150 from -1) -> (35) accept: application/mercurial-0.1\r\n
  readline(115 from -1) -> (*) host: localhost:$HGPORT\r\n (glob)
  readline(* from -1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n (glob)
  readline(* from -1) -> (2) \r\n (glob)
  write(36) -> HTTP/1.1 200 Script output follows\r\n
  write(23) -> Server: badhttpserver\r\n
  write(37) -> Date: $HTTP_DATE$\r\n
  write(41) -> Content-Type: application/mercurial-0.1\r\n
  write(21) -> Content-Length: 450\r\n
  write(2) -> \r\n
  write(450) -> batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(4? from 65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n (glob)
  readline(1? from -1) -> (1?) Accept-Encoding* (glob)
  read limit reached; closing socket
  readline(223 from 65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(197 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(170 from -1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(141 from -1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(100 from -1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(39 from -1) -> (35) accept: application/mercurial-0.1\r\n
  readline(4 from -1) -> (4) host
  read limit reached; closing socket

  $ rm -f error.log

Failure to read getbundle HTTP request

  $ hg serve --config badserver.closeafterrecvbytes=308,317,304 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS
  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: error: bad HTTP status line: ''
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(1 from -1) -> (1) x (?)
  readline(1 from -1) -> (1) x (?)
  readline(308 from 65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(275 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(248 from -1) -> (35) accept: application/mercurial-0.1\r\n
  readline(213 from -1) -> (*) host: localhost:$HGPORT\r\n (glob)
  readline(* from -1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n (glob)
  readline(* from -1) -> (2) \r\n (glob)
  write(36) -> HTTP/1.1 200 Script output follows\r\n
  write(23) -> Server: badhttpserver\r\n
  write(37) -> Date: $HTTP_DATE$\r\n
  write(41) -> Content-Type: application/mercurial-0.1\r\n
  write(21) -> Content-Length: 450\r\n
  write(2) -> \r\n
  write(450) -> batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(13? from 65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n (glob)
  readline(1?? from -1) -> (27) Accept-Encoding: identity\r\n (glob)
  readline(8? from -1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n (glob)
  readline(5? from -1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n (glob)
  readline(1? from -1) -> (1?) x-hgproto-1:* (glob)
  read limit reached; closing socket
  readline(317 from 65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(291 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(264 from -1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(235 from -1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(194 from -1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(133 from -1) -> (35) accept: application/mercurial-0.1\r\n
  readline(98 from -1) -> (*) host: localhost:$HGPORT\r\n (glob)
  readline(* from -1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n (glob)
  readline(* from -1) -> (2) \r\n (glob)
  write(36) -> HTTP/1.1 200 Script output follows\r\n
  write(23) -> Server: badhttpserver\r\n
  write(37) -> Date: $HTTP_DATE$\r\n
  write(41) -> Content-Type: application/mercurial-0.1\r\n
  write(20) -> Content-Length: 42\r\n
  write(2) -> \r\n
  write(42) -> 96ee1d7354c4ad7372047672c36a1f561e3a6a4c\n;
  readline(* from 65537) -> (*) GET /?cmd=getbundle HTTP* (glob)
  read limit reached; closing socket
  readline(304 from 65537) -> (30) GET /?cmd=getbundle HTTP/1.1\r\n
  readline(274 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(247 from -1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(218 from -1) -> (218) x-hgarg-1: bookmarks=1&bundlecaps=HG20%2Cbundle2%3DHG20%250Abookmarks%250Achangegroup%253D01%252C02%250Adigests%253Dmd5%252Csha1%252Csha512%250Aerror%253Dabort%252Cunsupportedcontent%252Cpushraced%252Cpushkey%250Ahgtag
  read limit reached; closing socket

  $ rm -f error.log

Now do a variation using POST to send arguments

  $ hg serve --config experimental.httppostargs=true --config badserver.closeafterrecvbytes=329,344 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: bad HTTP status line: ''
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(329 from 65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(296 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(269 from -1) -> (35) accept: application/mercurial-0.1\r\n
  readline(234 from -1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(* from -1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n (glob)
  readline(* from -1) -> (2) \r\n (glob)
  write(36) -> HTTP/1.1 200 Script output follows\r\n
  write(23) -> Server: badhttpserver\r\n
  write(37) -> Date: $HTTP_DATE$\r\n
  write(41) -> Content-Type: application/mercurial-0.1\r\n
  write(21) -> Content-Length: 463\r\n
  write(2) -> \r\n
  write(463) -> batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx httppostargs known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(1?? from 65537) -> (27) POST /?cmd=batch HTTP/1.1\r\n (glob)
  readline(1?? from -1) -> (27) Accept-Encoding: identity\r\n (glob)
  readline(1?? from -1) -> (41) content-type: application/mercurial-0.1\r\n (glob)
  readline(6? from -1) -> (33) vary: X-HgArgs-Post,X-HgProto-1\r\n (glob)
  readline(3? from -1) -> (19) x-hgargs-post: 28\r\n (glob)
  readline(1? from -1) -> (1?) x-hgproto-1: * (glob)
  read limit reached; closing socket
  readline(344 from 65537) -> (27) POST /?cmd=batch HTTP/1.1\r\n
  readline(317 from -1) -> (27) Accept-Encoding: identity\r\n
  readline(290 from -1) -> (41) content-type: application/mercurial-0.1\r\n
  readline(249 from -1) -> (33) vary: X-HgArgs-Post,X-HgProto-1\r\n
  readline(216 from -1) -> (19) x-hgargs-post: 28\r\n
  readline(197 from -1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(136 from -1) -> (35) accept: application/mercurial-0.1\r\n
  readline(101 from -1) -> (20) content-length: 28\r\n
  readline(81 from -1) -> (*) host: localhost:$HGPORT\r\n (glob)
  readline(* from -1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n (glob)
  readline(* from -1) -> (2) \r\n (glob)
  read(* from 28) -> (*) cmds=* (glob)
  read limit reached, closing socket
  write(36) -> HTTP/1.1 500 Internal Server Error\r\n

  $ rm -f error.log

Now move on to partial server responses

Server sends a single character from the HTTP response line

  $ hg serve --config badserver.closeaftersendbytes=1 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  abort: error: bad HTTP status line: H
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(1 from 36) -> (0) H
  write limit reached; closing socket
  write(36) -> HTTP/1.1 500 Internal Server Error\r\n

  $ rm -f error.log

Server sends an incomplete capabilities response body

  $ hg serve --config badserver.closeaftersendbytes=180 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  abort: HTTP request error (incomplete response; expected 450 bytes got 20)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (144) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (121) Server: badhttpserver\r\n
  write(37 from 37) -> (84) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (43) Content-Type: application/mercurial-0.1\r\n
  write(21 from 21) -> (22) Content-Length: 450\r\n
  write(2 from 2) -> (20) \r\n
  write(20 from 450) -> (0) batch branchmap bund
  write limit reached; closing socket

  $ rm -f error.log

Server sends incomplete headers for batch request

  $ hg serve --config badserver.closeaftersendbytes=728 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

TODO this output is horrible

  $ hg clone http://localhost:$HGPORT/ clone
  abort: 'http://localhost:$HGPORT/' does not appear to be an hg repository:
  ---%<--- (applicat)
  
  ---%<---
  !
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (692) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (669) Server: badhttpserver\r\n
  write(37 from 37) -> (632) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (591) Content-Type: application/mercurial-0.1\r\n
  write(21 from 21) -> (570) Content-Length: 450\r\n
  write(2 from 2) -> (568) \r\n
  write(450 from 450) -> (118) batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (82) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (59) Server: badhttpserver\r\n
  write(37 from 37) -> (22) Date: $HTTP_DATE$\r\n
  write(22 from 41) -> (0) Content-Type: applicat
  write limit reached; closing socket
  write(36) -> HTTP/1.1 500 Internal Server Error\r\n

  $ rm -f error.log

Server sends an incomplete HTTP response body to batch request

  $ hg serve --config badserver.closeaftersendbytes=793 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

TODO client spews a stack due to uncaught ValueError in batch.results()
#if no-chg
  $ hg clone http://localhost:$HGPORT/ clone 2> /dev/null
  [1]
#else
  $ hg clone http://localhost:$HGPORT/ clone 2> /dev/null
  [255]
#endif

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (757) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (734) Server: badhttpserver\r\n
  write(37 from 37) -> (697) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (656) Content-Type: application/mercurial-0.1\r\n
  write(21 from 21) -> (635) Content-Length: 450\r\n
  write(2 from 2) -> (633) \r\n
  write(450 from 450) -> (183) batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (147) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (124) Server: badhttpserver\r\n
  write(37 from 37) -> (87) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (46) Content-Type: application/mercurial-0.1\r\n
  write(20 from 20) -> (26) Content-Length: 42\r\n
  write(2 from 2) -> (24) \r\n
  write(24 from 42) -> (0) 96ee1d7354c4ad7372047672
  write limit reached; closing socket

  $ rm -f error.log

Server sends incomplete headers for getbundle response

  $ hg serve --config badserver.closeaftersendbytes=940 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

TODO this output is terrible

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: 'http://localhost:$HGPORT/' does not appear to be an hg repository:
  ---%<--- (application/mercuri)
  
  ---%<---
  !
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (904) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (881) Server: badhttpserver\r\n
  write(37 from 37) -> (844) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (803) Content-Type: application/mercurial-0.1\r\n
  write(21 from 21) -> (782) Content-Length: 450\r\n
  write(2 from 2) -> (780) \r\n
  write(450 from 450) -> (330) batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (294) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (271) Server: badhttpserver\r\n
  write(37 from 37) -> (234) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (193) Content-Type: application/mercurial-0.1\r\n
  write(20 from 20) -> (173) Content-Length: 42\r\n
  write(2 from 2) -> (171) \r\n
  write(42 from 42) -> (129) 96ee1d7354c4ad7372047672c36a1f561e3a6a4c\n;
  readline(65537) -> (30) GET /?cmd=getbundle HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (461) x-hgarg-1: bookmarks=1&bundlecaps=HG20%2Cbundle2%3DHG20%250Abookmarks%250Achangegroup%253D01%252C02%250Adigests%253Dmd5%252Csha1%252Csha512%250Aerror%253Dabort%252Cunsupportedcontent%252Cpushraced%252Cpushkey%250Ahgtagsfnodes%250Alistkeys%250Apushkey%250Aremote-changegroup%253Dhttp%252Chttps%250Arev-branch-cache%250Astream%253Dv2&cg=1&common=0000000000000000000000000000000000000000&heads=96ee1d7354c4ad7372047672c36a1f561e3a6a4c&listkeys=phases%2Cbookmarks\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (93) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (70) Server: badhttpserver\r\n
  write(37 from 37) -> (33) Date: $HTTP_DATE$\r\n
  write(33 from 41) -> (0) Content-Type: application/mercuri
  write limit reached; closing socket
  write(36) -> HTTP/1.1 500 Internal Server Error\r\n

  $ rm -f error.log

Server stops before it sends transfer encoding

  $ hg serve --config badserver.closeaftersendbytes=973 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: stream ended unexpectedly (got 0 bytes, expected 1)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -4 error.log
  write(41 from 41) -> (25) Content-Type: application/mercurial-0.2\r\n
  write(25 from 28) -> (0) Transfer-Encoding: chunke
  write limit reached; closing socket
  write(36) -> HTTP/1.1 500 Internal Server Error\r\n

  $ rm -f error.log

Server sends empty HTTP body for getbundle

  $ hg serve --config badserver.closeaftersendbytes=978 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: HTTP request error (incomplete response)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (942) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (919) Server: badhttpserver\r\n
  write(37 from 37) -> (882) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (841) Content-Type: application/mercurial-0.1\r\n
  write(21 from 21) -> (820) Content-Length: 450\r\n
  write(2 from 2) -> (818) \r\n
  write(450 from 450) -> (368) batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (332) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (309) Server: badhttpserver\r\n
  write(37 from 37) -> (272) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (231) Content-Type: application/mercurial-0.1\r\n
  write(20 from 20) -> (211) Content-Length: 42\r\n
  write(2 from 2) -> (209) \r\n
  write(42 from 42) -> (167) 96ee1d7354c4ad7372047672c36a1f561e3a6a4c\n;
  readline(65537) -> (30) GET /?cmd=getbundle HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (461) x-hgarg-1: bookmarks=1&bundlecaps=HG20%2Cbundle2%3DHG20%250Abookmarks%250Achangegroup%253D01%252C02%250Adigests%253Dmd5%252Csha1%252Csha512%250Aerror%253Dabort%252Cunsupportedcontent%252Cpushraced%252Cpushkey%250Ahgtagsfnodes%250Alistkeys%250Apushkey%250Aremote-changegroup%253Dhttp%252Chttps%250Arev-branch-cache%250Astream%253Dv2&cg=1&common=0000000000000000000000000000000000000000&heads=96ee1d7354c4ad7372047672c36a1f561e3a6a4c&listkeys=phases%2Cbookmarks\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (131) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (108) Server: badhttpserver\r\n
  write(37 from 37) -> (71) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (30) Content-Type: application/mercurial-0.2\r\n
  write(28 from 28) -> (2) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (0) \r\n
  write limit reached; closing socket
  write(36) -> HTTP/1.1 500 Internal Server Error\r\n

  $ rm -f error.log

Server sends partial compression string

  $ hg serve --config badserver.closeaftersendbytes=1002 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: HTTP request error (incomplete response)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ cat error.log
  readline(65537) -> (33) GET /?cmd=capabilities HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (966) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (943) Server: badhttpserver\r\n
  write(37 from 37) -> (906) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (865) Content-Type: application/mercurial-0.1\r\n
  write(21 from 21) -> (844) Content-Length: 450\r\n
  write(2 from 2) -> (842) \r\n
  write(450 from 450) -> (392) batch branchmap $USUAL_BUNDLE2_CAPS_NO_PHASES$ changegroupsubset compression=none getbundle httpheader=1024 httpmediatype=0.1rx,0.1tx,0.2tx known lookup pushkey streamreqs=generaldelta,revlogv1 unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  readline(65537) -> (26) GET /?cmd=batch HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (41) x-hgarg-1: cmds=heads+%3Bknown+nodes%3D\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (356) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (333) Server: badhttpserver\r\n
  write(37 from 37) -> (296) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (255) Content-Type: application/mercurial-0.1\r\n
  write(20 from 20) -> (235) Content-Length: 42\r\n
  write(2 from 2) -> (233) \r\n
  write(42 from 42) -> (191) 96ee1d7354c4ad7372047672c36a1f561e3a6a4c\n;
  readline(65537) -> (30) GET /?cmd=getbundle HTTP/1.1\r\n
  readline(-1) -> (27) Accept-Encoding: identity\r\n
  readline(-1) -> (29) vary: X-HgArg-1,X-HgProto-1\r\n
  readline(-1) -> (461) x-hgarg-1: bookmarks=1&bundlecaps=HG20%2Cbundle2%3DHG20%250Abookmarks%250Achangegroup%253D01%252C02%250Adigests%253Dmd5%252Csha1%252Csha512%250Aerror%253Dabort%252Cunsupportedcontent%252Cpushraced%252Cpushkey%250Ahgtagsfnodes%250Alistkeys%250Apushkey%250Aremote-changegroup%253Dhttp%252Chttps%250Arev-branch-cache%250Astream%253Dv2&cg=1&common=0000000000000000000000000000000000000000&heads=96ee1d7354c4ad7372047672c36a1f561e3a6a4c&listkeys=phases%2Cbookmarks\r\n
  readline(-1) -> (61) x-hgproto-1: 0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull\r\n
  readline(-1) -> (35) accept: application/mercurial-0.1\r\n
  readline(-1) -> (2?) host: localhost:$HGPORT\r\n (glob)
  readline(-1) -> (49) user-agent: mercurial/proto-1.0 (Mercurial 4.2)\r\n
  readline(-1) -> (2) \r\n
  write(36 from 36) -> (155) HTTP/1.1 200 Script output follows\r\n
  write(23 from 23) -> (132) Server: badhttpserver\r\n
  write(37 from 37) -> (95) Date: $HTTP_DATE$\r\n
  write(41 from 41) -> (54) Content-Type: application/mercurial-0.2\r\n
  write(28 from 28) -> (26) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (24) \r\n
  write(6 from 6) -> (18) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (9) 4\r\nnone\r\n
  write(9 from 9) -> (0) 4\r\nHG20\r\n
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server sends partial bundle2 header magic

  $ hg serve --config badserver.closeaftersendbytes=999 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: HTTP request error (incomplete response; expected 4 bytes got 3)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -7 error.log
  write(28 from 28) -> (23) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (21) \r\n
  write(6 from 6) -> (15) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (6) 4\r\nnone\r\n
  write(6 from 9) -> (0) 4\r\nHG2
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server sends incomplete bundle2 stream params length

  $ hg serve --config badserver.closeaftersendbytes=1008 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: HTTP request error (incomplete response; expected 4 bytes got 3)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -8 error.log
  write(28 from 28) -> (32) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (30) \r\n
  write(6 from 6) -> (24) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (15) 4\r\nnone\r\n
  write(9 from 9) -> (6) 4\r\nHG20\r\n
  write(6 from 9) -> (0) 4\\r\\n\x00\x00\x00 (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Servers stops after bundle2 stream params header

  $ hg serve --config badserver.closeaftersendbytes=1011 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: HTTP request error (incomplete response)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -8 error.log
  write(28 from 28) -> (35) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (33) \r\n
  write(6 from 6) -> (27) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (18) 4\r\nnone\r\n
  write(9 from 9) -> (9) 4\r\nHG20\r\n
  write(9 from 9) -> (0) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server stops sending after bundle2 part header length

  $ hg serve --config badserver.closeaftersendbytes=1020 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  abort: HTTP request error (incomplete response)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -9 error.log
  write(28 from 28) -> (44) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (42) \r\n
  write(6 from 6) -> (36) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (27) 4\r\nnone\r\n
  write(9 from 9) -> (18) 4\r\nHG20\r\n
  write(9 from 9) -> (9) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (0) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server stops sending after bundle2 part header

  $ hg serve --config badserver.closeaftersendbytes=1067 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  adding changesets
  transaction abort!
  rollback completed
  abort: HTTP request error (incomplete response)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -10 error.log
  write(28 from 28) -> (91) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (89) \r\n
  write(6 from 6) -> (83) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (74) 4\r\nnone\r\n
  write(9 from 9) -> (65) 4\r\nHG20\r\n
  write(9 from 9) -> (56) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (47) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write(47 from 47) -> (0) 29\\r\\n\x0bCHANGEGROUP\x00\x00\x00\x00\x01\x01\x07\x02	\x01version02nbchanges1\\r\\n (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server stops after bundle2 part payload chunk size

  $ hg serve --config badserver.closeaftersendbytes=1088 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  adding changesets
  transaction abort!
  rollback completed
  abort: HTTP request error (incomplete response; expected 466 bytes got 7)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -11 error.log
  write(2 from 2) -> (110) \r\n
  write(6 from 6) -> (104) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (95) 4\r\nnone\r\n
  write(9 from 9) -> (86) 4\r\nHG20\r\n
  write(9 from 9) -> (77) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (68) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write(47 from 47) -> (21) 29\\r\\n\x0bCHANGEGROUP\x00\x00\x00\x00\x01\x01\x07\x02	\x01version02nbchanges1\\r\\n (esc)
  write(9 from 9) -> (12) 4\\r\\n\x00\x00\x01\xd2\\r\\n (esc)
  write(12 from 473) -> (0) 1d2\\r\\n\x00\x00\x00\xb2\x96\xee\x1d (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server stops sending in middle of bundle2 payload chunk

  $ hg serve --config badserver.closeaftersendbytes=1549 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  adding changesets
  transaction abort!
  rollback completed
  abort: HTTP request error (incomplete response)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -12 error.log
  write(28 from 28) -> (573) Transfer-Encoding: chunked\r\n
  write(2 from 2) -> (571) \r\n
  write(6 from 6) -> (565) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (556) 4\r\nnone\r\n
  write(9 from 9) -> (547) 4\r\nHG20\r\n
  write(9 from 9) -> (538) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (529) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write(47 from 47) -> (482) 29\\r\\n\x0bCHANGEGROUP\x00\x00\x00\x00\x01\x01\x07\x02	\x01version02nbchanges1\\r\\n (esc)
  write(9 from 9) -> (473) 4\\r\\n\x00\x00\x01\xd2\\r\\n (esc)
  write(473 from 473) -> (0) 1d2\\r\\n\x00\x00\x00\xb2\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>6a3df4de388f3c4f8e28f4f9a814299a3cbb5f50\\ntest\\n0 0\\nfoo\\n\\ninitial\x00\x00\x00\x00\x00\x00\x00\xa1j=\xf4\xde8\x8f<O\x8e(\xf4\xf9\xa8\x14)\x9a<\xbb_P\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00b80de5d138758541c5f05265ad144ab9fa86d1db\\n\x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00h\xb8\\r\xe5\xd18u\x85A\xc5\xf0Re\xad\x14J\xb9\xfa\x86\xd1\xdb\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\\r\\n (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server stops sending after 0 length payload chunk size

  $ hg serve --config badserver.closeaftersendbytes=1580 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  transaction abort!
  rollback completed
  abort: HTTP request error (incomplete response; expected 32 bytes got 9)
  (this may be an intermittent network failure; if the error persists, consider contacting the network or server operator)
  [255]

  $ killdaemons.py $DAEMON_PIDS

  $ tail -13 error.log
  write(6 from 6) -> (596) 1\\r\\n\x04\\r\\n (esc)
  write(9 from 9) -> (587) 4\r\nnone\r\n
  write(9 from 9) -> (578) 4\r\nHG20\r\n
  write(9 from 9) -> (569) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (560) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write(47 from 47) -> (513) 29\\r\\n\x0bCHANGEGROUP\x00\x00\x00\x00\x01\x01\x07\x02	\x01version02nbchanges1\\r\\n (esc)
  write(9 from 9) -> (504) 4\\r\\n\x00\x00\x01\xd2\\r\\n (esc)
  write(473 from 473) -> (31) 1d2\\r\\n\x00\x00\x00\xb2\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>6a3df4de388f3c4f8e28f4f9a814299a3cbb5f50\\ntest\\n0 0\\nfoo\\n\\ninitial\x00\x00\x00\x00\x00\x00\x00\xa1j=\xf4\xde8\x8f<O\x8e(\xf4\xf9\xa8\x14)\x9a<\xbb_P\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00b80de5d138758541c5f05265ad144ab9fa86d1db\\n\x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00h\xb8\\r\xe5\xd18u\x85A\xc5\xf0Re\xad\x14J\xb9\xfa\x86\xd1\xdb\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (22) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (13) 4\\r\\n\x00\x00\x00 \\r\\n (esc)
  write(13 from 38) -> (0) 20\\r\\n\x08LISTKEYS (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log

Server stops sending after 0 part bundle part header (indicating end of bundle2 payload)
This is before the 0 size chunked transfer part that signals end of HTTP response.

#  $ hg serve --config badserver.closeaftersendbytes=1755 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ hg serve --config badserver.closeaftersendbytes=1862 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 96ee1d7354c4
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ killdaemons.py $DAEMON_PIDS

  $ tail -22 error.log
  write(9 from 9) -> (851) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (842) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write(47 from 47) -> (795) 29\\r\\n\x0bCHANGEGROUP\x00\x00\x00\x00\x01\x01\x07\x02	\x01version02nbchanges1\\r\\n (esc)
  write(9 from 9) -> (786) 4\\r\\n\x00\x00\x01\xd2\\r\\n (esc)
  write(473 from 473) -> (313) 1d2\\r\\n\x00\x00\x00\xb2\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>6a3df4de388f3c4f8e28f4f9a814299a3cbb5f50\\ntest\\n0 0\\nfoo\\n\\ninitial\x00\x00\x00\x00\x00\x00\x00\xa1j=\xf4\xde8\x8f<O\x8e(\xf4\xf9\xa8\x14)\x9a<\xbb_P\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00b80de5d138758541c5f05265ad144ab9fa86d1db\\n\x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00h\xb8\\r\xe5\xd18u\x85A\xc5\xf0Re\xad\x14J\xb9\xfa\x86\xd1\xdb\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (304) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (295) 4\\r\\n\x00\x00\x00 \\r\\n (esc)
  write(38 from 38) -> (257) 20\\r\\n\x08LISTKEYS\x00\x00\x00\x01\x01\x00	\x06namespacephases\\r\\n (esc)
  write(9 from 9) -> (248) 4\\r\\n\x00\x00\x00:\\r\\n (esc)
  write(64 from 64) -> (184) 3a\r\n96ee1d7354c4ad7372047672c36a1f561e3a6a4c	1\npublishing	True\r\n
  write(9 from 9) -> (175) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (166) 4\\r\\n\x00\x00\x00#\\r\\n (esc)
  write(41 from 41) -> (125) 23\\r\\n\x08LISTKEYS\x00\x00\x00\x02\x01\x00		namespacebookmarks\\r\\n (esc)
  write(9 from 9) -> (116) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (107) 4\\r\\n\x00\x00\x00\x1d\\r\\n (esc)
  write(35 from 35) -> (72) 1d\\r\\n\x16cache:rev-branch-cache\x00\x00\x00\x03\x00\x00\\r\\n (esc)
  write(9 from 9) -> (63) 4\\r\\n\x00\x00\x00'\\r\\n (esc)
  write(45 from 45) -> (18) 27\\r\\n\x00\x00\x00\x07\x00\x00\x00\x01\x00\x00\x00\x00default\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\\r\\n (esc)
  write(9 from 9) -> (9) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (0) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log
  $ rm -rf clone

Server sends a size 0 chunked-transfer size without terminating \r\n

  $ hg serve --config badserver.closeaftersendbytes=1865 -p $HGPORT -d --pid-file=hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT/ clone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 96ee1d7354c4
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ killdaemons.py $DAEMON_PIDS

  $ tail -23 error.log
  write(9 from 9) -> (854) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (845) 4\\r\\n\x00\x00\x00)\\r\\n (esc)
  write(47 from 47) -> (798) 29\\r\\n\x0bCHANGEGROUP\x00\x00\x00\x00\x01\x01\x07\x02	\x01version02nbchanges1\\r\\n (esc)
  write(9 from 9) -> (789) 4\\r\\n\x00\x00\x01\xd2\\r\\n (esc)
  write(473 from 473) -> (316) 1d2\\r\\n\x00\x00\x00\xb2\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00>6a3df4de388f3c4f8e28f4f9a814299a3cbb5f50\\ntest\\n0 0\\nfoo\\n\\ninitial\x00\x00\x00\x00\x00\x00\x00\xa1j=\xf4\xde8\x8f<O\x8e(\xf4\xf9\xa8\x14)\x9a<\xbb_P\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-foo\x00b80de5d138758541c5f05265ad144ab9fa86d1db\\n\x00\x00\x00\x00\x00\x00\x00\x07foo\x00\x00\x00h\xb8\\r\xe5\xd18u\x85A\xc5\xf0Re\xad\x14J\xb9\xfa\x86\xd1\xdb\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\x00\x00\x00\x00\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (307) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (298) 4\\r\\n\x00\x00\x00 \\r\\n (esc)
  write(38 from 38) -> (260) 20\\r\\n\x08LISTKEYS\x00\x00\x00\x01\x01\x00	\x06namespacephases\\r\\n (esc)
  write(9 from 9) -> (251) 4\\r\\n\x00\x00\x00:\\r\\n (esc)
  write(64 from 64) -> (187) 3a\r\n96ee1d7354c4ad7372047672c36a1f561e3a6a4c	1\npublishing	True\r\n
  write(9 from 9) -> (178) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (169) 4\\r\\n\x00\x00\x00#\\r\\n (esc)
  write(41 from 41) -> (128) 23\\r\\n\x08LISTKEYS\x00\x00\x00\x02\x01\x00		namespacebookmarks\\r\\n (esc)
  write(9 from 9) -> (119) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (110) 4\\r\\n\x00\x00\x00\x1d\\r\\n (esc)
  write(35 from 35) -> (75) 1d\\r\\n\x16cache:rev-branch-cache\x00\x00\x00\x03\x00\x00\\r\\n (esc)
  write(9 from 9) -> (66) 4\\r\\n\x00\x00\x00'\\r\\n (esc)
  write(45 from 45) -> (21) 27\\r\\n\x00\x00\x00\x07\x00\x00\x00\x01\x00\x00\x00\x00default\x96\xee\x1dsT\xc4\xadsr\x04vr\xc3j\x1fV\x1e:jL\\r\\n (esc)
  write(9 from 9) -> (12) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(9 from 9) -> (3) 4\\r\\n\x00\x00\x00\x00\\r\\n (esc)
  write(3 from 5) -> (0) 0\r\n
  write limit reached; closing socket
  write(27) -> 15\r\nInternal Server Error\r\n

  $ rm -f error.log
  $ rm -rf clone
