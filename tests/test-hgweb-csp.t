#require serve

  $ cat > web.conf << EOF
  > [paths]
  > / = $TESTTMP/*
  > EOF

  $ hg init repo1
  $ cd repo1
  $ touch foo
  $ hg -q commit -A -m initial
  $ cd ..

  $ hg serve -p $HGPORT -d --pid-file=hg.pid --web-conf web.conf
  $ cat hg.pid >> $DAEMON_PIDS

repo index should not send Content-Security-Policy header by default

  $ get-with-headers.py --headeronly localhost:$HGPORT '' content-security-policy etag
  200 Script output follows

static page should not send CSP by default

  $ get-with-headers.py --headeronly localhost:$HGPORT static/mercurial.js content-security-policy etag
  200 Script output follows

repo page should not send CSP by default, should send ETag

  $ get-with-headers.py --headeronly localhost:$HGPORT repo1 content-security-policy etag
  200 Script output follows
  etag: W/"*" (glob)

  $ killdaemons.py

Configure CSP without nonce

  $ cat >> web.conf << EOF
  > [web]
  > csp = script-src https://example.com/ 'unsafe-inline'
  > EOF

  $ hg serve -p $HGPORT -d --pid-file=hg.pid --web-conf web.conf
  $ cat hg.pid > $DAEMON_PIDS

repo index should send Content-Security-Policy header when enabled

  $ get-with-headers.py --headeronly localhost:$HGPORT '' content-security-policy etag
  200 Script output follows
  content-security-policy: script-src https://example.com/ 'unsafe-inline'

static page should send CSP when enabled

  $ get-with-headers.py --headeronly localhost:$HGPORT static/mercurial.js content-security-policy etag
  200 Script output follows
  content-security-policy: script-src https://example.com/ 'unsafe-inline'

  $ get-with-headers.py --twice --headeronly localhost:$HGPORT repo1/static/style.css content-security-policy
  200 Script output follows
  content-security-policy: script-src https://example.com/ 'unsafe-inline'
  304 Not Modified
  content-security-policy: script-src https://example.com/ 'unsafe-inline'

repo page should send CSP by default, include etag w/o nonce

  $ get-with-headers.py --headeronly localhost:$HGPORT repo1 content-security-policy etag
  200 Script output follows
  content-security-policy: script-src https://example.com/ 'unsafe-inline'
  etag: W/"*" (glob)

no inline scripts in html

  $ get-with-headers.py localhost:$HGPORT repo1/graph/tip | grep -E 'content-security-policy|<script'
  <script type="text/javascript" src="/repo1/static/mercurial.js"></script>
  <script id="graph-data" type="application/json">[{"edges": [], "graphnode": "@o", "node": "96ee1d7354c4", "vertex": [0, 1]}]</script>

Configure CSP with nonce placeholder

  $ killdaemons.py
  $ cat >> web.conf << EOF
  > csp = image-src 'self'; script-src https://example.com/ 'nonce-%nonce%'
  > EOF

  $ hg serve -p $HGPORT -d --pid-file=hg.pid --web-conf web.conf
  $ cat hg.pid > $DAEMON_PIDS

nonce should be substituted in CSP header

  $ get-with-headers.py --headeronly localhost:$HGPORT '' content-security-policy etag
  200 Script output follows
  content-security-policy: image-src 'self'; script-src https://example.com/ 'nonce-*' (glob)

nonce should be included in CSP for static pages

  $ get-with-headers.py --headeronly localhost:$HGPORT static/mercurial.js content-security-policy etag
  200 Script output follows
  content-security-policy: image-src 'self'; script-src https://example.com/ 'nonce-*' (glob)

repo page should have ETag

  $ get-with-headers.py --headeronly localhost:$HGPORT repo1 content-security-policy etag
  200 Script output follows
  content-security-policy: image-src 'self'; script-src https://example.com/ 'nonce-*' (glob)
  etag: W/"*" (glob)

no nonce attributes in script tags

  $ get-with-headers.py localhost:$HGPORT repo1/graph/tip content-security-policy | grep -E 'content-security-policy|<script'
  content-security-policy: image-src 'self'; script-src https://example.com/ 'nonce-*' (glob)
  <script type="text/javascript" src="/repo1/static/mercurial.js"></script>
  <script id="graph-data" type="application/json">[{"edges": [], "graphnode": "@o", "node": "96ee1d7354c4", "vertex": [0, 1]}]</script>

hgweb_mod w/o hgwebdir works as expected

  $ killdaemons.py

  $ hg serve -R repo1 -p $HGPORT -d --pid-file=hg.pid --config "web.csp=image-src 'self'; script-src https://example.com/ 'nonce-%nonce%'"
  $ cat hg.pid > $DAEMON_PIDS

static page sends CSP

  $ get-with-headers.py --headeronly localhost:$HGPORT static/mercurial.js content-security-policy etag
  200 Script output follows
  content-security-policy: image-src 'self'; script-src https://example.com/ 'nonce-*' (glob)
  etag: W/"*" (glob)

no nonce in script tags

  $ get-with-headers.py localhost:$HGPORT graph/tip content-security-policy | grep -E 'content-security-policy|<script'
  content-security-policy: image-src 'self'; script-src https://example.com/ 'nonce-*' (glob)
  <script type="text/javascript" src="/static/mercurial.js"></script>
  <script id="graph-data" type="application/json">[{"edges": [], "graphnode": "@o", "node": "96ee1d7354c4", "vertex": [0, 1]}]</script>
