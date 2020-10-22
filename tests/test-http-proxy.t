#require serve

  $ hg init a
  $ cd a
  $ echo a > a
  $ hg ci -Ama -d '1123456789 0'
  adding a
  $ hg serve --config server.uncompressed=True -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid >> $DAEMON_PIDS
  $ cd ..
  $ tinyproxy.py $HGPORT1 localhost 2>proxy.log >/dev/null </dev/null &
  $ while [ ! -f proxy.pid ]; do sleep 0; done
  $ cat proxy.pid >> $DAEMON_PIDS

url for proxy, stream

  $ http_proxy=http://localhost:$HGPORT1/ hg --config http_proxy.always=True clone --stream http://localhost:$HGPORT/ b
  streaming all changes
  6 files to transfer, 412 bytes of data (reporevlogstore !)
  4 files to transfer, 330 bytes of data (reposimplestore !)
  transferred * bytes in * seconds (*/sec) (glob)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd b
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 1 changesets with 1 changes to 1 files
  $ cd ..

url for proxy, pull

  $ http_proxy=http://localhost:$HGPORT1/ hg --config http_proxy.always=True clone http://localhost:$HGPORT/ b-pull
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 83180e7845de
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd b-pull
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 1 changesets with 1 changes to 1 files
  $ cd ..

host:port for proxy

  $ http_proxy=localhost:$HGPORT1 hg clone --config http_proxy.always=True http://localhost:$HGPORT/ c
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 83180e7845de
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

proxy url with user name and password

  $ http_proxy=http://user:passwd@localhost:$HGPORT1 hg clone --config http_proxy.always=True http://localhost:$HGPORT/ d
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 83180e7845de
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

url with user name and password

  $ http_proxy=http://user:passwd@localhost:$HGPORT1 hg clone --config http_proxy.always=True http://user:passwd@localhost:$HGPORT/ e
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 83180e7845de
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

bad host:port for proxy ("Protocol not supported" can happen on
misconfigured hosts)

  $ http_proxy=localhost:$HGPORT2 hg clone --config http_proxy.always=True http://localhost:$HGPORT/ f
  abort: error: (Connection refused|Protocol not supported|.* actively refused it|\$EADDRNOTAVAIL\$|No route to host) (re)
  [100]

do not use the proxy if it is in the no list

  $ http_proxy=localhost:$HGPORT1 hg clone --config http_proxy.no=localhost http://localhost:$HGPORT/ g
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 83180e7845de
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat proxy.log
  * - - [*] "GET http://localhost:$HGPORT/?cmd=capabilities HTTP/1.1" - - (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=batch HTTP/1.1" - - x-hgarg-1:cmds=heads+%3Bknown+nodes%3D x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=getbundle HTTP/1.1" - - x-hgarg-1:bookmarks=1&$USUAL_BUNDLE_CAPS$&cg=0&common=0000000000000000000000000000000000000000&heads=83180e7845de420a1bb46896fd5fe05294f8d629&listkeys=bookmarks&stream=1 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  * - - [*] "GET http://localhost:$HGPORT/?cmd=capabilities HTTP/1.1" - - (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=batch HTTP/1.1" - - x-hgarg-1:cmds=heads+%3Bknown+nodes%3D x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=getbundle HTTP/1.1" - - x-hgarg-1:bookmarks=1&$USUAL_BUNDLE_CAPS$&cg=1&common=0000000000000000000000000000000000000000&heads=83180e7845de420a1bb46896fd5fe05294f8d629&listkeys=bookmarks&phases=1 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  * - - [*] "GET http://localhost:$HGPORT/?cmd=capabilities HTTP/1.1" - - (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=batch HTTP/1.1" - - x-hgarg-1:cmds=heads+%3Bknown+nodes%3D x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=getbundle HTTP/1.1" - - x-hgarg-1:bookmarks=1&$USUAL_BUNDLE_CAPS$&cg=1&common=0000000000000000000000000000000000000000&heads=83180e7845de420a1bb46896fd5fe05294f8d629&listkeys=bookmarks&phases=1 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  * - - [*] "GET http://localhost:$HGPORT/?cmd=capabilities HTTP/1.1" - - (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=batch HTTP/1.1" - - x-hgarg-1:cmds=heads+%3Bknown+nodes%3D x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=getbundle HTTP/1.1" - - x-hgarg-1:bookmarks=1&$USUAL_BUNDLE_CAPS$&cg=1&common=0000000000000000000000000000000000000000&heads=83180e7845de420a1bb46896fd5fe05294f8d629&listkeys=bookmarks&phases=1 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  * - - [*] "GET http://localhost:$HGPORT/?cmd=capabilities HTTP/1.1" - - (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=batch HTTP/1.1" - - x-hgarg-1:cmds=heads+%3Bknown+nodes%3D x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET http://localhost:$HGPORT/?cmd=getbundle HTTP/1.1" - - x-hgarg-1:bookmarks=1&$USUAL_BUNDLE_CAPS$&cg=1&common=0000000000000000000000000000000000000000&heads=83180e7845de420a1bb46896fd5fe05294f8d629&listkeys=bookmarks&phases=1 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
