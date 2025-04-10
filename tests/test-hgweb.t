#require serve

Some tests for hgweb. Tests static files, plain files and different 404's.

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

  $ (get-with-headers.py localhost:$HGPORT 'file/tip/?style=raw')
  200 Script output follows
  
  
  drwxr-xr-x da
  -rw-r--r-- 4 foo
  
  
  $ (get-with-headers.py localhost:$HGPORT 'file/tip/da?style=raw')
  200 Script output follows
  
  
  -rw-r--r-- 4 foo
  
  

plain file

  $ get-with-headers.py localhost:$HGPORT 'file/tip/foo?style=raw'
  200 Script output follows
  
  foo

should give a 404 - static file that does not exist

  $ get-with-headers.py localhost:$HGPORT 'static/bogus'
  404 Not Found
  
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en-US">
  <head>
  <link rel="icon" href="/static/hgicon.png" type="image/png" />
  <meta name="robots" content="index, nofollow" />
  <link rel="stylesheet" href="/static/style-paper.css" type="text/css" />
  <script type="text/javascript" src="/static/mercurial.js"></script>
  
  <title>test: error</title>
  </head>
  <body>
  
  <div class="container">
  <div class="menu">
  <div class="logo">
  <a href="https://mercurial-scm.org/">
  <img src="/static/hglogo.png" width=75 height=90 border=0 alt="mercurial" /></a>
  </div>
  <ul>
  <li><a href="/shortlog">log</a></li>
  <li><a href="/graph">graph</a></li>
  <li><a href="/tags">tags</a></li>
  <li><a href="/bookmarks">bookmarks</a></li>
  <li><a href="/branches">branches</a></li>
  </ul>
  <ul>
  <li><a href="/help">help</a></li>
  </ul>
  </div>
  
  <div class="main">
  
  <h2 class="breadcrumb"><a href="/">Mercurial</a> </h2>
  <h3>error</h3>
  
  
  <form class="search" action="/log">
  
  <p><input name="rev" id="search1" type="text" size="30" value="" /></p>
  <div id="hint">Find changesets by keywords (author, files, the commit message), revision
  number or hash, or <a href="/help/revsets">revset expression</a>.</div>
  </form>
  
  <div class="description">
  <p>
  An error occurred while processing your request:
  </p>
  <p>
  Not Found
  </p>
  </div>
  </div>
  </div>
  
  
  
  </body>
  </html>
  
  [1]

should give a 404 - bad revision

  $ get-with-headers.py localhost:$HGPORT 'file/spam/foo?style=raw'
  404 Not Found
  
  
  error: revision not found: spam
  [1]

should give a 400 - bad command

  $ get-with-headers.py localhost:$HGPORT 'file/tip/foo?cmd=spam&style=raw'
  400* (glob)
  
  
  error: method not found
  [1]

  $ get-with-headers.py --headeronly localhost:$HGPORT '?cmd=spam'
  400 method not found
  [1]

should give a 400 - bad command as a part of url path (issue4071)

  $ get-with-headers.py --headeronly localhost:$HGPORT 'spam'
  400 method not found
  [1]

  $ get-with-headers.py --headeronly localhost:$HGPORT 'raw-spam'
  400 method not found
  [1]

  $ get-with-headers.py --headeronly localhost:$HGPORT 'spam/tip/foo'
  400 method not found
  [1]

should give a 404 - file does not exist

  $ get-with-headers.py localhost:$HGPORT 'file/tip/bork?style=raw'
  404 Not Found
  
  
  error: bork@2ef0ac749a14e4f57a5a822464a0902c6f7f448f: not found in manifest
  [1]
  $ get-with-headers.py localhost:$HGPORT 'file/tip/bork'
  404 Not Found
  
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en-US">
  <head>
  <link rel="icon" href="/static/hgicon.png" type="image/png" />
  <meta name="robots" content="index, nofollow" />
  <link rel="stylesheet" href="/static/style-paper.css" type="text/css" />
  <script type="text/javascript" src="/static/mercurial.js"></script>
  
  <title>test: error</title>
  </head>
  <body>
  
  <div class="container">
  <div class="menu">
  <div class="logo">
  <a href="https://mercurial-scm.org/">
  <img src="/static/hglogo.png" width=75 height=90 border=0 alt="mercurial" /></a>
  </div>
  <ul>
  <li><a href="/shortlog">log</a></li>
  <li><a href="/graph">graph</a></li>
  <li><a href="/tags">tags</a></li>
  <li><a href="/bookmarks">bookmarks</a></li>
  <li><a href="/branches">branches</a></li>
  </ul>
  <ul>
  <li><a href="/help">help</a></li>
  </ul>
  </div>
  
  <div class="main">
  
  <h2 class="breadcrumb"><a href="/">Mercurial</a> </h2>
  <h3>error</h3>
  
  
  <form class="search" action="/log">
  
  <p><input name="rev" id="search1" type="text" size="30" value="" /></p>
  <div id="hint">Find changesets by keywords (author, files, the commit message), revision
  number or hash, or <a href="/help/revsets">revset expression</a>.</div>
  </form>
  
  <div class="description">
  <p>
  An error occurred while processing your request:
  </p>
  <p>
  bork@2ef0ac749a14e4f57a5a822464a0902c6f7f448f: not found in manifest
  </p>
  </div>
  </div>
  </div>
  
  
  
  </body>
  </html>
  
  [1]
  $ get-with-headers.py localhost:$HGPORT 'diff/tip/bork?style=raw'
  404 Not Found
  
  
  error: bork@2ef0ac749a14e4f57a5a822464a0902c6f7f448f: not found in manifest
  [1]

try bad style

  $ (get-with-headers.py localhost:$HGPORT 'file/tip/?style=foobar')
  200 Script output follows
  
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en-US">
  <head>
  <link rel="icon" href="/static/hgicon.png" type="image/png" />
  <meta name="robots" content="index, nofollow" />
  <link rel="stylesheet" href="/static/style-paper.css" type="text/css" />
  <script type="text/javascript" src="/static/mercurial.js"></script>
  
  <title>test: 2ef0ac749a14 /</title>
  </head>
  <body>
  
  <div class="container">
  <div class="menu">
  <div class="logo">
  <a href="https://mercurial-scm.org/">
  <img src="/static/hglogo.png" alt="mercurial" /></a>
  </div>
  <ul>
  <li><a href="/shortlog/tip">log</a></li>
  <li><a href="/graph/tip">graph</a></li>
  <li><a href="/tags">tags</a></li>
  <li><a href="/bookmarks">bookmarks</a></li>
  <li><a href="/branches">branches</a></li>
  </ul>
  <ul>
  <li><a href="/rev/tip">changeset</a></li>
  <li class="active">browse</li>
  </ul>
  <ul>
  
  </ul>
  <ul>
   <li><a href="/help">help</a></li>
  </ul>
  </div>
  
  <div class="main">
  <h2 class="breadcrumb"><a href="/">Mercurial</a> </h2>
  <h3>
   directory / @ 0:<a href="/rev/2ef0ac749a14">2ef0ac749a14</a>
   <span class="phase">draft</span> <span class="branchhead">default</span> <span class="tag">tip</span> <span class="tag">@</span> <span class="tag">a b c</span> <span class="tag">d/e/f</span> 
  </h3>
  
  
  <form class="search" action="/log">
  
  <p><input name="rev" id="search1" type="text" size="30" value="" /></p>
  <div id="hint">Find changesets by keywords (author, files, the commit message), revision
  number or hash, or <a href="/help/revsets">revset expression</a>.</div>
  </form>
  
  <table class="bigtable">
  <thead>
  <tr>
    <th class="name">name</th>
    <th class="size">size</th>
    <th class="permissions">permissions</th>
  </tr>
  </thead>
  <tbody class="stripes2">
  
  
  <tr class="fileline">
  <td class="name">
  <a href="/file/tip/da">
  <img src="/static/coal-folder.png" alt="dir."/> da/
  </a>
  <a href="/file/tip/da/">
  
  </a>
  </td>
  <td class="size"></td>
  <td class="permissions">drwxr-xr-x</td>
  </tr>
  
  <tr class="fileline">
  <td class="filename">
  <a href="/file/tip/foo">
  <img src="/static/coal-file.png" alt="file"/> foo
  </a>
  </td>
  <td class="size">4</td>
  <td class="permissions">-rw-r--r--</td>
  </tr>
  </tbody>
  </table>
  </div>
  </div>
  
  
  </body>
  </html>
  

stop and restart

  $ killdaemons.py
  $ hg serve -p $HGPORT -d --pid-file=hg.pid -A access.log
  $ cat hg.pid >> $DAEMON_PIDS

Test the access/error files are opened in append mode

  $ "$PYTHON" -c "print(len(open('access.log', 'rb').readlines()), 'log lines written')"
  14 log lines written

static file

  $ get-with-headers.py --twice localhost:$HGPORT 'static/style-gitweb.css' - date etag server
  200 Script output follows
  content-length: 9074
  content-type: text/css
  
  body { font-family: sans-serif; font-size: 12px; border:solid #d9d8d1; border-width:1px; margin:10px; background: white; color: black; }
  a { color:#0000cc; }
  a:hover, a:visited, a:active { color:#880000; }
  div.page_header { height:25px; padding:8px; font-size:18px; font-weight:bold; background-color:#d9d8d1; }
  div.page_header a:visited { color:#0000cc; }
  div.page_header a:hover { color:#880000; }
  div.page_nav {
      padding:8px;
      display: flex;
      justify-content: space-between;
      align-items: center;
  }
  div.page_nav a:visited { color:#0000cc; }
  div.extra_nav {
      padding: 8px;
  }
  div.extra_nav a:visited {
      color: #0000cc;
  }
  div.page_path { padding:8px; border:solid #d9d8d1; border-width:0px 0px 1px}
  div.page_footer { padding:4px 8px; background-color: #d9d8d1; }
  div.page_footer_text { float:left; color:#555555; font-style:italic; }
  div.page_body { padding:8px; }
  div.title, a.title {
  	display:block; padding:6px 8px;
  	font-weight:bold; background-color:#edece6; text-decoration:none; color:#000000;
  }
  a.title:hover { background-color: #d9d8d1; }
  div.title_text { padding:6px 0px; border: solid #d9d8d1; border-width:0px 0px 1px; }
  div.log_body { padding:8px 8px 8px 150px; }
  .age { white-space:nowrap; }
  a.title span.age { position:relative; float:left; width:142px; font-style:italic; }
  div.log_link {
  	padding:0px 8px;
  	font-size:10px; font-family:sans-serif; font-style:normal;
  	position:relative; float:left; width:136px;
  }
  div.list_head { padding:6px 8px 4px; border:solid #d9d8d1; border-width:1px 0px 0px; font-style:italic; }
  a.list { text-decoration:none; color:#000000; }
  a.list:hover { text-decoration:underline; color:#880000; }
  table { padding:8px 4px; }
  th { padding:2px 5px; font-size:12px; text-align:left; }
  .parity0 { background-color:#ffffff; }
  tr.dark, .parity1, pre.sourcelines.stripes > :nth-child(4n+4) { background-color:#f6f6f0; }
  tr.light:hover, .parity0:hover, tr.dark:hover, .parity1:hover,
  pre.sourcelines.stripes > :nth-child(4n+2):hover,
  pre.sourcelines.stripes > :nth-child(4n+4):hover,
  pre.sourcelines.stripes > :nth-child(4n+1):hover + :nth-child(4n+2),
  pre.sourcelines.stripes > :nth-child(4n+3):hover + :nth-child(4n+4) { background-color:#edece6; }
  td { padding:2px 5px; font-size:12px; vertical-align:top; }
  td.closed { background-color: #99f; }
  td.link { padding:2px 5px; font-family:sans-serif; font-size:10px; }
  td.indexlinks { white-space: nowrap; }
  td.indexlinks a {
    padding: 2px 5px; line-height: 10px;
    border: 1px solid;
    color: #ffffff; background-color: #7777bb;
    border-color: #aaaadd #333366 #333366 #aaaadd;
    font-weight: bold;  text-align: center; text-decoration: none;
    font-size: 10px;
  }
  td.indexlinks a:hover { background-color: #6666aa; }
  div.pre { font-family:monospace; font-size:12px; white-space:pre; }
  
  .search {
      margin-right: 8px;
  }
  
  div#hint {
    position: absolute;
    display: none;
    width: 250px;
    padding: 5px;
    background: #ffc;
    border: 1px solid yellow;
    border-radius: 5px;
    z-index: 15;
  }
  
  #searchform:hover div#hint { display: block; }
  
  tr.thisrev a { color:#999999; text-decoration: none; }
  tr.thisrev pre { color:#009900; }
  td.annotate {
    white-space: nowrap;
  }
  div.annotate-info {
    z-index: 5;
    display: none;
    position: absolute;
    background-color: #FFFFFF;
    border: 1px solid #d9d8d1;
    text-align: left;
    color: #000000;
    padding: 5px;
  }
  div.annotate-info a { color: #0000FF; text-decoration: underline; }
  td.annotate:hover div.annotate-info { display: inline; }
  
  #diffopts-form {
    padding-left: 8px;
    display: none;
  }
  
  .linenr { color:#999999; text-decoration:none }
  div.rss_logo { float: right; white-space: nowrap; }
  div.rss_logo a {
  	padding:3px 6px; line-height:10px;
  	border:1px solid; border-color:#fcc7a5 #7d3302 #3e1a01 #ff954e;
  	color:#ffffff; background-color:#ff6600;
  	font-weight:bold; font-family:sans-serif; font-size:10px;
  	text-align:center; text-decoration:none;
  }
  div.rss_logo a:hover { background-color:#ee5500; }
  pre { margin: 0; }
  span.logtags span {
  	padding: 0px 4px;
  	font-size: 10px;
  	font-weight: normal;
  	border: 1px solid;
  	background-color: #ffaaff;
  	border-color: #ffccff #ff00ee #ff00ee #ffccff;
  }
  span.logtags span.phasetag {
  	background-color: #dfafff;
  	border-color: #e2b8ff #ce48ff #ce48ff #e2b8ff;
  }
  span.logtags span.obsoletetag {
  	background-color: #dddddd;
  	border-color: #e4e4e4 #a3a3a3 #a3a3a3 #e4e4e4;
  }
  span.logtags span.instabilitytag {
  	background-color: #ffb1c0;
  	border-color: #ffbbc8 #ff4476 #ff4476 #ffbbc8;
  }
  span.logtags span.tagtag {
  	background-color: #ffffaa;
  	border-color: #ffffcc #ffee00 #ffee00 #ffffcc;
  }
  span.logtags span.branchtag {
  	background-color: #aaffaa;
  	border-color: #ccffcc #00cc33 #00cc33 #ccffcc;
  }
  span.logtags span.inbranchtag {
  	background-color: #d5dde6;
  	border-color: #e3ecf4 #9398f4 #9398f4 #e3ecf4;
  }
  span.logtags span.bookmarktag {
  	background-color: #afdffa;
  	border-color: #ccecff #46ace6 #46ace6 #ccecff;
  }
  span.difflineplus { color:#008800; }
  span.difflineminus { color:#cc0000; }
  span.difflineat { color:#990099; }
  div.diffblocks { counter-reset: lineno; }
  div.diffblock { counter-increment: lineno; }
  pre.sourcelines { position: relative; counter-reset: lineno; }
  pre.sourcelines > span {
  	display: inline-block;
  	box-sizing: border-box;
  	width: 100%;
  	padding: 0 0 0 5em;
  	counter-increment: lineno;
  	vertical-align: top;
  }
  pre.sourcelines > span:before {
  	-moz-user-select: -moz-none;
  	-khtml-user-select: none;
  	-webkit-user-select: none;
  	-ms-user-select: none;
  	user-select: none;
  	display: inline-block;
  	margin-left: -6em;
  	width: 4em;
  	color: #999;
  	text-align: right;
  	content: counters(lineno,".");
  	float: left;
  }
  pre.sourcelines > a {
  	display: inline-block;
  	position: absolute;
  	left: 0px;
  	width: 4em;
  	height: 1em;
  }
  tr:target td,
  pre.sourcelines > span:target,
  pre.sourcelines.stripes > span:target {
  	background-color: #bfdfff;
  }
  
  .description {
      font-family: monospace;
      white-space: pre;
  }
  
  /* Followlines */
  tbody.sourcelines > tr.followlines-selected,
  pre.sourcelines > span.followlines-selected {
    background-color: #99C7E9 !important;
  }
  
  div#followlines {
    background-color: #FFF;
    border: 1px solid #d9d8d1;
    padding: 5px;
    position: fixed;
  }
  
  div.followlines-cancel {
    text-align: right;
  }
  
  div.followlines-cancel > button {
    line-height: 80%;
    padding: 0;
    border: 0;
    border-radius: 2px;
    background-color: inherit;
    font-weight: bold;
  }
  
  div.followlines-cancel > button:hover {
    color: #FFFFFF;
    background-color: #CF1F1F;
  }
  
  div.followlines-link {
    margin: 2px;
    margin-top: 4px;
    font-family: sans-serif;
  }
  
  .btn-followlines {
    position: absolute;
    display: none;
    cursor: pointer;
    box-sizing: content-box;
    font-size: 11px;
    width: 13px;
    height: 13px;
    border-radius: 3px;
    margin: 0px;
    margin-top: -2px;
    padding: 0px;
    background-color: #E5FDE5;
    border: 1px solid #9BC19B;
    font-family: monospace;
    text-align: center;
    line-height: 5px;
  }
  
  span.followlines-select .btn-followlines {
    margin-left: -1.6em;
  }
  
  .btn-followlines:hover {
    transform: scale(1.1, 1.1);
  }
  
  .btn-followlines .followlines-plus {
    color: green;
  }
  
  .btn-followlines .followlines-minus {
    color: red;
  }
  
  .btn-followlines-end {
    background-color: #ffdcdc;
  }
  
  .sourcelines tr:hover .btn-followlines,
  .sourcelines span.followlines-select:hover > .btn-followlines {
    display: inline;
  }
  
  .btn-followlines-hidden,
  .sourcelines tr:hover .btn-followlines-hidden {
    display: none;
  }
  
  /* Graph */
  div#wrapper {
  	position: relative;
  	margin: 0;
  	padding: 0;
  	margin-top: 3px;
  }
  
  canvas {
  	position: absolute;
  	z-index: 5;
  	top: -0.9em;
  	margin: 0;
  }
  
  ul#graphnodes {
  	list-style: none inside none;
  	padding: 0;
  	margin: 0;
  }
  
  ul#graphnodes li {
  	position: relative;
  	height: 37px;
  	overflow: visible;
  	padding-top: 2px;
  }
  
  ul#graphnodes li .fg {
  	position: absolute;
  	z-index: 10;
  }
  
  ul#graphnodes li .info {
  	font-size: 100%;
  	font-style: italic;
  }
  
  /* Comparison */
  .legend {
      padding: 1.5% 0 1.5% 0;
  }
  
  .legendinfo {
      border: 1px solid #d9d8d1;
      font-size: 80%;
      text-align: center;
      padding: 0.5%;
  }
  
  .equal {
      background-color: #ffffff;
  }
  
  .delete {
      background-color: #faa;
      color: #333;
  }
  
  .insert {
      background-color: #ffa;
  }
  
  .replace {
      background-color: #e8e8e8;
  }
  
  .comparison {
      overflow-x: auto;
  }
  
  .header th {
      text-align: center;
  }
  
  .block {
      border-top: 1px solid #d9d8d1;
  }
  
  .scroll-loading {
    -webkit-animation: change_color 1s linear 0s infinite alternate;
    -moz-animation: change_color 1s linear 0s infinite alternate;
    -o-animation: change_color 1s linear 0s infinite alternate;
    animation: change_color 1s linear 0s infinite alternate;
  }
  
  @-webkit-keyframes change_color {
    from { background-color: #A0CEFF; } to {  }
  }
  @-moz-keyframes change_color {
    from { background-color: #A0CEFF; } to {  }
  }
  @-o-keyframes change_color {
    from { background-color: #A0CEFF; } to {  }
  }
  @keyframes change_color {
    from { background-color: #A0CEFF; } to {  }
  }
  
  .scroll-loading-error {
      background-color: #FFCCCC !important;
  }
  
  #doc {
      margin: 0 8px;
  }
  304 Not Modified
  

phase changes are refreshed (issue4061)

  $ echo bar >> foo
  $ hg ci -msecret --secret
  $ get-with-headers.py localhost:$HGPORT 'log?style=raw'
  200 Script output follows
  
  
  # HG changelog
  # Node ID 2ef0ac749a14e4f57a5a822464a0902c6f7f448f
  
  changeset:   2ef0ac749a14e4f57a5a822464a0902c6f7f448f
  revision:    0
  user:        test
  date:        Thu, 01 Jan 1970 00:00:00 +0000
  summary:     base
  branch:      default
  tag:         tip
  bookmark:    @
  bookmark:    a b c
  bookmark:    d/e/f
  
  
  $ hg phase --draft tip
  $ get-with-headers.py localhost:$HGPORT 'log?style=raw'
  200 Script output follows
  
  
  # HG changelog
  # Node ID a084749e708a9c4c0a5b652a2a446322ce290e04
  
  changeset:   a084749e708a9c4c0a5b652a2a446322ce290e04
  revision:    1
  user:        test
  date:        Thu, 01 Jan 1970 00:00:00 +0000
  summary:     secret
  branch:      default
  tag:         tip
  
  changeset:   2ef0ac749a14e4f57a5a822464a0902c6f7f448f
  revision:    0
  user:        test
  date:        Thu, 01 Jan 1970 00:00:00 +0000
  summary:     base
  bookmark:    @
  bookmark:    a b c
  bookmark:    d/e/f
  
  

access bookmarks

  $ get-with-headers.py localhost:$HGPORT 'rev/@?style=paper' | grep -E '^200|changeset 0:'
  200 Script output follows
   changeset 0:<a href="/rev/2ef0ac749a14?style=paper">2ef0ac749a14</a>

  $ get-with-headers.py localhost:$HGPORT 'rev/%40?style=paper' | grep -E '^200|changeset 0:'
  200 Script output follows
   changeset 0:<a href="/rev/2ef0ac749a14?style=paper">2ef0ac749a14</a>

  $ get-with-headers.py localhost:$HGPORT 'rev/a%20b%20c?style=paper' | grep -E '^200|changeset 0:'
  200 Script output follows
   changeset 0:<a href="/rev/2ef0ac749a14?style=paper">2ef0ac749a14</a>

  $ get-with-headers.py localhost:$HGPORT 'rev/d%252Fe%252Ff?style=paper' | grep -E '^200|changeset 0:'
  200 Script output follows
   changeset 0:<a href="/rev/2ef0ac749a14?style=paper">2ef0ac749a14</a>

no '[up]' entry in file view when in root directory

  $ get-with-headers.py localhost:$HGPORT 'file/tip?style=paper' | grep -F '[up]'
  [1]
  $ get-with-headers.py localhost:$HGPORT 'file/tip/da?style=paper' | grep -F '[up]'
  <a href="/file/tip/?style=paper">[up]</a>
  $ get-with-headers.py localhost:$HGPORT 'file/tip?style=coal' | grep -F '[up]'
  [1]
  $ get-with-headers.py localhost:$HGPORT 'file/tip/da?style=coal' | grep -F '[up]'
  <a href="/file/tip/?style=coal">[up]</a>
  $ get-with-headers.py localhost:$HGPORT 'file/tip?style=gitweb' | grep -F '[up]'
  [1]
  $ get-with-headers.py localhost:$HGPORT 'file/tip/da?style=gitweb' | grep -F '[up]'
  <a href="/file/tip/?style=gitweb">[up]</a>
  $ get-with-headers.py localhost:$HGPORT 'file/tip?style=monoblue' | grep -F '[up]'
  [1]
  $ get-with-headers.py localhost:$HGPORT 'file/tip/da?style=monoblue' | grep -F '[up]'
  <a href="/file/tip/?style=monoblue">[up]</a>
  $ get-with-headers.py localhost:$HGPORT 'file/tip?style=spartan' | grep -F '[up]'
  [1]
  $ get-with-headers.py localhost:$HGPORT 'file/tip/da?style=spartan' | grep -F '[up]'
  <a href="/file/tip/?style=spartan">[up]</a>

no style can be loaded from directories other than the specified paths

  $ mkdir -p x/templates/fallback
  $ cat <<EOF > x/templates/fallback/map
  > default = 'shortlog'
  > shortlog = 'fall back to default\n'
  > mimetype = 'text/plain'
  > EOF
  $ cat <<EOF > x/map
  > default = 'shortlog'
  > shortlog = 'access to outside of templates directory\n'
  > mimetype = 'text/plain'
  > EOF

  $ killdaemons.py
  $ hg serve -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log \
  > --config web.style=fallback --config web.templates=x/templates
  $ cat hg.pid >> $DAEMON_PIDS

  $ get-with-headers.py localhost:$HGPORT "?style=`pwd`/x"
  200 Script output follows
  
  fall back to default

  $ get-with-headers.py localhost:$HGPORT '?style=..'
  200 Script output follows
  
  fall back to default

  $ get-with-headers.py localhost:$HGPORT '?style=./..'
  200 Script output follows
  
  fall back to default

  $ get-with-headers.py localhost:$HGPORT '?style=.../.../'
  200 Script output follows
  
  fall back to default

  $ killdaemons.py

Test signal-safe-lock in web and non-web processes

  $ cat <<'EOF' > disablesig.py
  > import signal
  > from mercurial import error, extensions
  > def disabledsig(orig, signalnum, handler):
  >     if signalnum == signal.SIGTERM:
  >         raise error.Abort(b'SIGTERM cannot be replaced')
  >     try:
  >         return orig(signalnum, handler)
  >     except ValueError:
  >         raise error.Abort(b'signal.signal() called in thread?')
  > def uisetup(ui):
  >    extensions.wrapfunction(signal, 'signal', disabledsig)
  > EOF

 by default, signal interrupt should be disabled while making a lock file

  $ hg debuglock -s --config extensions.disablesig=disablesig.py
  abort: SIGTERM cannot be replaced
  [255]

 but in hgweb, it isn't disabled since some WSGI servers complains about
 unsupported signal.signal() calls (see issue5889)

  $ hg serve --config extensions.disablesig=disablesig.py \
  > --config web.allow-push='*' --config web.push_ssl=False \
  > -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ hg clone -q http://localhost:$HGPORT/ repo
  $ hg bookmark -R repo foo

 push would fail if signal.signal() were called

  $ hg push -R repo -B foo
  pushing to http://localhost:$HGPORT/
  searching for changes
  no changes found
  exporting bookmark foo
  [1]

  $ rm -R repo
  $ killdaemons.py

errors

  $ cat errors.log | "$PYTHON" $TESTDIR/filtertraceback.py
  $ rm -f errors.log

Uncaught exceptions result in a logged error and canned HTTP response

  $ hg serve --config extensions.hgweberror=$TESTDIR/hgweberror.py -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ get-with-headers.py localhost:$HGPORT 'raiseerror' transfer-encoding content-type
  500 Internal Server Error
  transfer-encoding: chunked
  
  Internal Server Error (no-eol)
  [1]

  $ killdaemons.py
  $ cat errors.log | "$PYTHON" $TESTDIR/filtertraceback.py
  .* Exception happened during processing request '/raiseerror': (re)
  Traceback (most recent call last):
  AttributeError: I am an uncaught error!
  

Uncaught exception after partial content sent

  $ hg serve --config extensions.hgweberror=$TESTDIR/hgweberror.py -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ get-with-headers.py localhost:$HGPORT 'raiseerror?partialresponse=1' transfer-encoding content-type
  200 Script output follows
  transfer-encoding: chunked
  content-type: text/plain
  
  partial content
  Internal Server Error (no-eol)

  $ killdaemons.py

HTTP 304 works with hgwebdir (issue5844)

  $ cat > hgweb.conf << EOF
  > [paths]
  > /repo = $TESTTMP/test
  > EOF

  $ hg serve --web-conf hgweb.conf -p $HGPORT -d --pid-file hg.pid -E error.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ get-with-headers.py --twice --headeronly localhost:$HGPORT 'repo/static/style.css' - date etag server
  200 Script output follows
  content-length: 2677
  content-type: text/css
  304 Not Modified

  $ killdaemons.py

  $ cd ..
