#require serve

Some tests for hgweb responding to HEAD requests

  $ hg init test
  $ cd test
  $ mkdir da
  $ echo foo > da/foo
  $ echo foo > foo
  $ hg ci -Ambase
  adding da/foo
  adding foo
  $ hg bookmark -r0 '@'
  $ hg bookmark -r0 'a b c'
  $ hg bookmark -r0 'd/e/f'
  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

manifest

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/tip/?style=raw' - date etag server
  200 Script output follows
  content-type: text/plain; charset=ascii
  
  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/tip/da?style=raw' - date etag server
  200 Script output follows
  content-type: text/plain; charset=ascii
  

plain file

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/tip/foo?style=raw' - date etag server
  200 Script output follows
  content-disposition: inline; filename="foo"
  content-length: 4
  content-type: application/binary
  

should give a 404 - static file that does not exist

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'static/bogus' - date etag server
  404 Not Found
  content-type: text/html; charset=ascii
  
  [1]

should give a 404 - bad revision

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/spam/foo?style=raw' - date etag server
  404 Not Found
  content-type: text/plain; charset=ascii
  
  [1]

should give a 400 - bad command

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/tip/foo?cmd=spam&style=raw' - date etag server
  400* (glob)
  content-type: text/plain; charset=ascii
  
  [1]

should give a 404 - file does not exist

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/tip/bork?style=raw' - date etag server
  404 Not Found
  content-type: text/plain; charset=ascii
  
  [1]

try bad style

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'file/tip/?style=foobar' - date etag server
  200 Script output follows
  content-type: text/html; charset=ascii
  

log

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'log?style=raw' - date etag server
  200 Script output follows
  content-type: text/plain; charset=ascii
  

access bookmarks

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'rev/@?style=paper' - date etag server
  200 Script output follows
  content-type: text/html; charset=ascii
  

static file

  $ get-with-headers.py localhost:$HGPORT --method=HEAD 'static/style-gitweb.css' - date etag server
  200 Script output follows
  content-length: 9074
  content-type: text/css
  

  $ killdaemons.py

  $ cd ..
