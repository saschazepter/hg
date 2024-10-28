#require no-msys

  $ hg init test
  $ cat >hgweb.cgi <<HGWEB
  > #!$PYTHON
  > from mercurial import demandimport; demandimport.enable()
  > from mercurial.hgweb import hgweb
  > from mercurial.hgweb import wsgicgi
  > application = hgweb(b"test", b"Empty test repository")
  > wsgicgi.launch(application)
  > HGWEB
  $ chmod 755 hgweb.cgi

Check that non-ASCII bytes roundtrip correctly.

  $ . "$TESTDIR/cgienv"
  $ PATH_INFO="/rev/$(python -c 'import sys; sys.stdout.buffer.write(b"\xe2\x80\x94")')"; export PATH_INFO
  $ QUERY_STRING="style=raw"; export QUERY_STRING
  $ "$PYTHON" ./hgweb.cgi | grep error
  error: unknown revision '\xe2\x80\x94' (esc)
