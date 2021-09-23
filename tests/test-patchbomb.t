Note for future hackers of patchbomb: this file is a bit heavy on
wildcards in test expectations due to how many things like hostnames
tend to make it into outputs. As a result, you may need to perform the
following regular expression substitutions:
Mercurial-patchbomb/.* -> Mercurial-patchbomb/* (glob)
/mixed; boundary="===+[0-9]+==" -> /mixed; boundary="===*== (glob)"
--===+[0-9]+=+--$ -> --===*=-- (glob)
--===+[0-9]+=+$ -> --===*= (glob)

  $ cat > prune-blank-after-boundary.py <<EOF
  > from __future__ import absolute_import, print_function
  > import sys
  > skipblank = False
  > trim = lambda x: x.strip(' \r\n')
  > for l in sys.stdin:
  >     if trim(l).endswith('=--') or trim(l).endswith('=='):
  >         skipblank = True
  >         print(l, end='')
  >         continue
  >     if not trim(l) and skipblank:
  >         continue
  >     skipblank = False
  >     print(l, end='')
  > EOF
  $ filterboundary() {
  >     "$PYTHON" "$TESTTMP/prune-blank-after-boundary.py"
  > }
  $ echo "[extensions]" >> $HGRCPATH
  $ echo "patchbomb=" >> $HGRCPATH

  $ hg init t
  $ cd t
  $ echo a > a
  $ hg commit -Ama -d '1 0'
  adding a

  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -r tip
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.60@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  

If --to is specified on the command line, it should override any
email.to config setting. Same for --cc:

  $ hg email --date '1970-1-1 0:1' -n -f quux --to foo --cc bar -r tip \
  >   --config email.to=bob@example.com --config email.cc=alice@example.com
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.60@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  

  $ hg --config ui.interactive=1 email --confirm -n -f quux -t foo -c bar -r tip<<EOF
  > n
  > EOF
  this patch series consists of 1 patches.
  
  
  Final summary:
  
  From: quux
  To: foo
  Cc: bar
  Subject: [PATCH] a
   a |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  are you sure you want to send (yn)? n
  abort: patchbomb canceled
  [255]

  $ hg --config ui.interactive=1 --config patchbomb.confirm=true email -n -f quux -t foo -c bar -r tip<<EOF
  > n
  > EOF
  this patch series consists of 1 patches.
  
  
  Final summary:
  
  From: quux
  To: foo
  Cc: bar
  Subject: [PATCH] a
   a |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  are you sure you want to send (yn)? n
  abort: patchbomb canceled
  [255]


Test diff.git is respected
  $ hg --config diff.git=True email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -r tip
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.60@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
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
  
  diff --git a/a b/a
  new file mode 100644
  --- /dev/null
  +++ b/a
  @@ -0,0 +1,1 @@
  +a
  


Test breaking format changes aren't
  $ hg --config diff.noprefix=True email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -r tip
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.60@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  

  $ echo b > b
  $ hg commit -Amb -d '2 0'
  adding b

  $ hg email --date '1970-1-1 0:2' -n -f quux -t foo -c bar -s test -r 0:tip
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 2] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2] test
  Message-Id: <patchbomb.120@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:02:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 2] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.121@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.121@test-hostname>
  In-Reply-To: <patchbomb.120@test-hostname>
  References: <patchbomb.120@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:02:01 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.122@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.121@test-hostname>
  In-Reply-To: <patchbomb.120@test-hostname>
  References: <patchbomb.120@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:02:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  

.hg/last-email.txt

  $ cat > editor.sh << '__EOF__'
  > echo "a precious introductory message" > "$1"
  > __EOF__
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg email -n -t foo -s test -r 0:tip > /dev/null
  $ cat .hg/last-email.txt
  a precious introductory message

  $ hg email -m test.mbox -f quux -t foo -c bar -s test 0:tip \
  > --config extensions.progress= --config progress.assume-tty=1 \
  > --config progress.delay=0 --config progress.refresh=0 \
  > --config progress.width=60 \
  > --config extensions.mocktime=$TESTDIR/mocktime.py
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  \r (no-eol) (esc)
  sending [                                             ] 0/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  sending [============>                            ] 1/3 01s\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  sending [==========================>              ] 2/3 01s\r (no-eol) (esc)
                                                              \r (esc)
  sending [PATCH 0 of 2] test ...
  sending [PATCH 1 of 2] a ...
  sending [PATCH 2 of 2] b ...

  $ cd ..

  $ hg clone -q t t2
  $ cd t2
  $ echo c > c
  $ hg commit -Amc -d '3 0'
  adding c

  $ cat > description <<EOF
  > a multiline
  > 
  > description
  > EOF


test bundle and description:
  $ hg email --date '1970-1-1 0:3' -n -f quux -t foo \
  >  -c bar -s test -r tip -b --desc description | filterboundary
  searching for changes
  1 changesets found
  
  displaying test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: test
  Message-Id: <patchbomb.180@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:03:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  a multiline
  
  description
  
  --===*= (glob)
  Content-Type: application/x-mercurial-bundle
  MIME-Version: 1.0
  Content-Disposition: attachment; filename="bundle.hg"
  Content-Transfer-Encoding: base64
  
  SEcyMAAAAA5Db21wcmVzc2lvbj1CWkJaaDkxQVkmU1l91TAVAAAN////vFcSXL9/8H7R09C/578I
  Ak0E4pe4SIIIgQSgGEQOcLABGYYNKgJgmhpp6mmjIZMCZNMhpgBBpkaYJpo9QaZMg02iaY2lCImK
  emk02kmEAeoA0D01ANBoHqHqADTaj1NAAyZqA0Gg0KiYnqaepk0eoNDTCGj1A0eoyBoGjRkYBqAB
  poNMmhkBhENSP0knlYZbqyEIYxkFdpDUS6roBDMgAGhkAqd92kEcgyeMo2MM366gpLNHjfKrhJPN
  vdBCHAEDsYzAvzkHKxy5KWBAmh5e1nFttGChpsxrgmutRG0YrsSLWEBH9h95cbZEKFeUKYykRXHa
  Bkt2OSgELsqqnWKeMudBR+YSZCOSHrwPz7B/Gfou7/L6QV6S0IgclBCitBVHMxMFq/vGwp5WHezM
  JwhKTnH0OkMbmVjrAkQKR7VM2aNSXn+GzLOCzOQm0AJ1TLCpdSgnfFPcY7mGxAOyHXS1YEFVi5O9
  I4EVBBd8VRgN4n1MAm8l6QQ+yB60hkeX/0ZZmKoQRINkEBxEDZU2HjIZMcwWRvZtbRIa5kgkGIb/
  SkImFwIkDtQxyX+LuSKcKEg+6pgKgA==
  --===============*==-- (glob)

with a specific bundle type
(binary part must be different)

  $ hg email --date '1970-1-1 0:3' -n -f quux -t foo \
  >  -c bar -s test -r tip -b --desc description \
  > --config patchbomb.bundletype=gzip-v1 | filterboundary
  searching for changes
  1 changesets found
  
  displaying test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: test
  Message-Id: <patchbomb.180@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:03:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  a multiline
  
  description
  
  --===*= (glob)
  Content-Type: application/x-mercurial-bundle
  MIME-Version: 1.0
  Content-Disposition: attachment; filename="bundle.hg"
  Content-Transfer-Encoding: base64
  
  SEcxMEdaeJxjYGBY8V9n/iLGbtFfJZuNk/euDCpWfrRy/vTrevFCx1/4t7J5LdeL0ix0Opx3kwEL
  wKYXKqUJwqnG5sYWSWmmJsaWlqYWaRaWJpaWiWamZpYWRgZGxolJiabmSQbmZqlcQMV6QGwCxGzG
  CgZcySARUyA2A2LGZKiZ3Y+Lu786z4z4MWXmsrAZCsqrl1az5y21PMcjpbThzWeXGT+/nutbmvvz
  zXYS3BoGxdrJDIYmlimJJiZpRokmqYYmaSYWFknmSSkmhqbmliamiZYWxuYmBhbJBgZcUBNZQe5K
  Epm7xF/LT+RLx/a9juFTomaYO/Rgsx4rwBN+IMCUDLOKAQBrsmti
   (?)
  --===============*==-- (glob)

utf-8 patch:
  $ "$PYTHON" -c 'fp = open("utf", "wb"); fp.write(b"h\xC3\xB6mma!\n"); fp.close();'
  $ hg commit -A -d '4 0' \
  >   --encoding "utf-8" \
  >   -m `"$PYTHON" -c 'import sys; getattr(sys.stdout, "buffer", sys.stdout).write(b"\xc3\xa7a")'`
  adding description
  adding utf

no mime encoding for email --test:
  $ hg email --date '1970-1-1 0:4' -f quux -t foo -c bar -r tip -n
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] ?a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="iso-8859-1"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH] ?a
  X-Mercurial-Node: f81ef97829467e868fc405fccbcfa66217e4d3e6
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <f81ef97829467e868fc4.240@test-hostname>
  X-Mercurial-Series-Id: <f81ef97829467e868fc4.240@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:04:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID f81ef97829467e868fc405fccbcfa66217e4d3e6
  # Parent  ff2c9fa2018b15fa74b33363bda9527323e2a99f
  ?a
  
  diff -r ff2c9fa2018b -r f81ef9782946 description
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/description	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,3 @@
  +a multiline
  +
  +description
  diff -r ff2c9fa2018b -r f81ef9782946 utf
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/utf	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,1 @@
  +h=C3=B6mma!
  

mime encoded mbox (base64):
  $ hg email --date '1970-1-1 0:4' -f 'Q <quux>' -t foo -c bar -r tip -m mbox
  this patch series consists of 1 patches.
  
  
  sending [PATCH] ?a ...

  $ cat mbox
  From quux ... ... .. ..:..:.. .... (re)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="utf-8"
  Content-Transfer-Encoding: base64
  Subject: [PATCH] ?a
  X-Mercurial-Node: f81ef97829467e868fc405fccbcfa66217e4d3e6
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <f81ef97829467e868fc4.240@test-hostname>
  X-Mercurial-Series-Id: <f81ef97829467e868fc4.240@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:04:00 +0000
  From: Q <quux> (no-py3 !)
  From: =?iso-8859-1?q?Q?= <quux> (py3 !)
  To: foo
  Cc: bar
  
  IyBIRyBjaGFuZ2VzZXQgcGF0Y2gKIyBVc2VyIHRlc3QKIyBEYXRlIDQgMAojICAgICAgVGh1IEph
  biAwMSAwMDowMDowNCAxOTcwICswMDAwCiMgTm9kZSBJRCBmODFlZjk3ODI5NDY3ZTg2OGZjNDA1
  ZmNjYmNmYTY2MjE3ZTRkM2U2CiMgUGFyZW50ICBmZjJjOWZhMjAxOGIxNWZhNzRiMzMzNjNiZGE5
  NTI3MzIzZTJhOTlmCj9hCgpkaWZmIC1yIGZmMmM5ZmEyMDE4YiAtciBmODFlZjk3ODI5NDYgZGVz
  Y3JpcHRpb24KLS0tIC9kZXYvbnVsbAlUaHUgSmFuIDAxIDAwOjAwOjAwIDE5NzAgKzAwMDAKKysr
  IGIvZGVzY3JpcHRpb24JVGh1IEphbiAwMSAwMDowMDowNCAxOTcwICswMDAwCkBAIC0wLDAgKzEs
  MyBAQAorYSBtdWx0aWxpbmUKKworZGVzY3JpcHRpb24KZGlmZiAtciBmZjJjOWZhMjAxOGIgLXIg
  ZjgxZWY5NzgyOTQ2IHV0ZgotLS0gL2Rldi9udWxsCVRodSBKYW4gMDEgMDA6MDA6MDAgMTk3MCAr
  MDAwMAorKysgYi91dGYJVGh1IEphbiAwMSAwMDowMDowNCAxOTcwICswMDAwCkBAIC0wLDAgKzEs
  MSBAQAoraMO2bW1hIQo=
  
  
  >>> import base64
  >>> patch = base64.b64decode(open("mbox").read().split("\n\n")[1])
  >>> if not isinstance(patch, str):
  ...     import sys
  ...     sys.stdout.flush()
  ...     junk = sys.stdout.buffer.write(patch + b"\n")
  ... else:
  ...     print(patch)
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID f81ef97829467e868fc405fccbcfa66217e4d3e6
  # Parent  ff2c9fa2018b15fa74b33363bda9527323e2a99f
  ?a
  
  diff -r ff2c9fa2018b -r f81ef9782946 description
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/description	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,3 @@
  +a multiline
  +
  +description
  diff -r ff2c9fa2018b -r f81ef9782946 utf
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/utf	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,1 @@
  +h\xc3\xb6mma! (esc)
  
  $ rm mbox

mime encoded mbox (quoted-printable):
  $ "$PYTHON" -c 'fp = open("long", "wb"); fp.write(b"%s\nfoo\n\nbar\n" % (b"x" * 1024)); fp.close();'
  $ hg commit -A -d '4 0' -m 'long line'
  adding long

no mime encoding for email --test:
  $ hg email --date '1970-1-1 0:4' -f quux -t foo -c bar -r tip -n
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] long line ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH] long line
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <0c7b871cb86b61a1c07e.240@test-hostname>
  X-Mercurial-Series-Id: <0c7b871cb86b61a1c07e.240@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:04:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  

mime encoded mbox (quoted-printable):
  $ hg email --date '1970-1-1 0:4' -f quux -t foo -c bar -r tip -m mbox
  this patch series consists of 1 patches.
  
  
  sending [PATCH] long line ...
  $ cat mbox
  From quux ... ... .. ..:..:.. .... (re)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH] long line
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <0c7b871cb86b61a1c07e.240@test-hostname>
  X-Mercurial-Series-Id: <0c7b871cb86b61a1c07e.240@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:04:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  
  

  $ rm mbox

iso-8859-1 patch:
  $ "$PYTHON" -c 'fp = open("isolatin", "wb"); fp.write(b"h\xF6mma!\n"); fp.close();'
  $ hg commit -A -d '5 0' -m 'isolatin 8-bit encoding'
  adding isolatin

iso-8859-1 mbox:
  $ hg email --date '1970-1-1 0:5' -f quux -t foo -c bar -r tip -m mbox
  this patch series consists of 1 patches.
  
  
  sending [PATCH] isolatin 8-bit encoding ...
  $ cat mbox
  From quux ... ... .. ..:..:.. .... (re)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="iso-8859-1"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH] isolatin 8-bit encoding
  X-Mercurial-Node: 4d6f44f466c96d89f2e7e865a70ff41d8b6eee37
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <4d6f44f466c96d89f2e7.300@test-hostname>
  X-Mercurial-Series-Id: <4d6f44f466c96d89f2e7.300@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:05:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 5 0
  #      Thu Jan 01 00:00:05 1970 +0000
  # Node ID 4d6f44f466c96d89f2e7e865a70ff41d8b6eee37
  # Parent  0c7b871cb86b61a1c07e244393603c361e4a178d
  isolatin 8-bit encoding
  
  diff -r 0c7b871cb86b -r 4d6f44f466c9 isolatin
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/isolatin	Thu Jan 01 00:00:05 1970 +0000
  @@ -0,0 +1,1 @@
  +h=F6mma!
  
  

test diffstat for single patch:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -d -y -r 2
  this patch series consists of 1 patches.
  
  
  Final summary:
  
  From: quux
  To: foo
  Cc: bar
  Subject: [PATCH] test
   c |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  are you sure you want to send (yn)? y
  
  displaying [PATCH] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
   c |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

test diffstat for multiple patches:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -d -y \
  >  -r 0:1
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  Final summary:
  
  From: quux
  To: foo
  Cc: bar
  Subject: [PATCH 0 of 2] test
   a |  1 +
   b |  1 +
   2 files changed, 2 insertions(+), 0 deletions(-)
  Subject: [PATCH 1 of 2] a
   a |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  Subject: [PATCH 2 of 2] b
   b |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  are you sure you want to send (yn)? y
  
  displaying [PATCH 0 of 2] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
   a |  1 +
   b |  1 +
   2 files changed, 2 insertions(+), 0 deletions(-)
  
  displaying [PATCH 1 of 2] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
   a |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
   b |  1 +
   1 files changed, 1 insertions(+), 0 deletions(-)
  
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  

test inline for single patch:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -i -r 2 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: inline; filename=t2.patch
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  
  --===*=-- (glob)


test inline for single patch (quoted-printable):
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -i -r 4 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH] test
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <0c7b871cb86b61a1c07e.60@test-hostname>
  X-Mercurial-Series-Id: <0c7b871cb86b61a1c07e.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Content-Disposition: inline; filename=t2.patch
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  
  --===*=-- (glob)

test inline for multiple patches:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -i \
  >  -r 0:1 -r 4 | filterboundary
  this patch series consists of 3 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 3] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 3] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 3] a ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 1 of 3] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 3
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: inline; filename=t2-1.patch
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  --===*=-- (glob)
  displaying [PATCH 2 of 3] b ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 2 of 3] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 3
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: inline; filename=t2-2.patch
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  
  --===*=-- (glob)
  displaying [PATCH 3 of 3] long line ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 3 of 3] long line
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 3
  X-Mercurial-Series-Total: 3
  Message-Id: <0c7b871cb86b61a1c07e.63@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:03 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Content-Disposition: inline; filename=t2-3.patch
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  
  --===*=-- (glob)

test attach for single patch:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -a -r 2 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  Patch subject is complete summary.
  
  
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: attachment; filename=t2.patch
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  
  --===*=-- (glob)

test attach for single patch (quoted-printable):
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -a -r 4 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH] test
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <0c7b871cb86b61a1c07e.60@test-hostname>
  X-Mercurial-Series-Id: <0c7b871cb86b61a1c07e.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  Patch subject is complete summary.
  
  
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Content-Disposition: attachment; filename=t2.patch
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  
  --===*=-- (glob)

test attach and body for single patch:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -a --body -r 2 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: attachment; filename=t2.patch
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  
  --===*=-- (glob)

test attach for multiple patches:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -a \
  >  -r 0:1 -r 4 | filterboundary
  this patch series consists of 3 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 3] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 3] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 3] a ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 1 of 3] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 3
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  Patch subject is complete summary.
  
  
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: attachment; filename=t2-1.patch
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  --===*=-- (glob)
  displaying [PATCH 2 of 3] b ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 2 of 3] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 3
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  Patch subject is complete summary.
  
  
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: attachment; filename=t2-2.patch
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  
  --===*=-- (glob)
  displaying [PATCH 3 of 3] long line ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 3 of 3] long line
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 3
  X-Mercurial-Series-Total: 3
  Message-Id: <0c7b871cb86b61a1c07e.63@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:03 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  
  Patch subject is complete summary.
  
  
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Content-Disposition: attachment; filename=t2-3.patch
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  
  --===*=-- (glob)

test intro for single patch:
  $ hg email --date '1970-1-1 0:1' -n --intro -f quux -t foo -c bar -s test \
  >  -r 2
  this patch series consists of 1 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 1] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 1] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 1] c ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 1] c
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.61@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

test --desc without --intro for a single patch:
  $ echo foo > intro.text
  $ hg email --date '1970-1-1 0:1' -n --desc intro.text -f quux -t foo -c bar \
  >  -s test -r 2
  this patch series consists of 1 patches.
  
  
  displaying [PATCH 0 of 1] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 1] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  foo
  
  displaying [PATCH 1 of 1] c ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 1] c
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.61@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

test intro for multiple patches:
  $ hg email --date '1970-1-1 0:1' -n --intro -f quux -t foo -c bar -s test \
  >  -r 0:1
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 2] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 2] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  

test reply-to via config:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -r 2 \
  >  --config patchbomb.reply-to='baz@example.com'
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  Reply-To: baz@example.com
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

test reply-to via command line:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -r 2 \
  >  --reply-to baz --reply-to fred
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  Reply-To: baz, fred
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

tagging csets:
  $ hg tag -r0 zero zero.foo
  $ hg tag -r1 one one.patch
  $ hg tag -r2 two two.diff

test inline for single named patch:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -i \
  >   -r 2 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: inline; filename=two.diff
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  
  --===*=-- (glob)

test inline for multiple named/unnamed patches:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar -s test -i \
  >    -r 0:1 | filterboundary
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 2] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 2] a ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 1 of 2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: inline; filename=t2-1.patch
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  --===*=-- (glob)
  displaying [PATCH 2 of 2] b ...
  Content-Type: multipart/mixed; boundary="===*==" (glob)
  MIME-Version: 1.0
  Subject: [PATCH 2 of 2] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  --===*= (glob)
  MIME-Version: 1.0
  Content-Type: text/x-patch; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Content-Disposition: inline; filename=one.patch
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  
  --===*=-- (glob)


test inreplyto:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar --in-reply-to baz \
  >  -r tip
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] Added tag two, two.diff for changeset ff2c9fa2018b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] Added tag two, two.diff for changeset ff2c9fa2018b
  X-Mercurial-Node: 9cea7492c36bdda2c72e7dd5f35f7fc367adeb2c
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <9cea7492c36bdda2c72e.60@test-hostname>
  X-Mercurial-Series-Id: <9cea7492c36bdda2c72e.60@test-hostname>
  In-Reply-To: <baz>
  References: <baz>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID 9cea7492c36bdda2c72e7dd5f35f7fc367adeb2c
  # Parent  3b775b32716d9b54291ccddf0a36ceea45449bfb
  Added tag two, two.diff for changeset ff2c9fa2018b
  
  diff -r 3b775b32716d -r 9cea7492c36b .hgtags
  --- a/.hgtags	Thu Jan 01 00:00:00 1970 +0000
  +++ b/.hgtags	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,3 +2,5 @@
   8580ff50825a50c8f716709acdf8de0deddcd6ab zero.foo
   97d72e5f12c7e84f85064aa72e5a297142c36ed9 one
   97d72e5f12c7e84f85064aa72e5a297142c36ed9 one.patch
  +ff2c9fa2018b15fa74b33363bda9527323e2a99f two
  +ff2c9fa2018b15fa74b33363bda9527323e2a99f two.diff
  
no intro message in non-interactive mode
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar --in-reply-to baz \
  >  -r 0:1
  this patch series consists of 2 patches.
  
  (optional) Subject: [PATCH 0 of 2] 
  
  displaying [PATCH 1 of 2] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.60@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  In-Reply-To: <baz>
  References: <baz>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  In-Reply-To: <baz>
  References: <baz>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  



  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -c bar --in-reply-to baz \
  >  -s test -r 0:1
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 2] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2] test
  Message-Id: <patchbomb.60@test-hostname>
  In-Reply-To: <baz>
  References: <baz>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 2] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  

test single flag for single patch (and no warning when not mailing dirty rev):
  $ hg up -qr1
  $ echo dirt > a
  $ hg email --date '1970-1-1 0:1' -n --flag fooFlag -f quux -t foo -c bar -s test \
  >  -r 2 | filterboundary
  this patch series consists of 1 patches.
  
  
  displaying [PATCH fooFlag] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH fooFlag] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

test single flag for multiple patches (and warning when mailing dirty rev):
  $ hg email --date '1970-1-1 0:1' -n --flag fooFlag -f quux -t foo -c bar -s test \
  >  -r 0:1
  warning: working directory has uncommitted changes
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 2 fooFlag] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2 fooFlag] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 2 fooFlag] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2 fooFlag] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2 fooFlag] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2 fooFlag] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  
  $ hg revert --no-b a
  $ hg up -q

test multiple flags for single patch:
  $ hg email --date '1970-1-1 0:1' -n --flag fooFlag --flag barFlag -f quux -t foo \
  >  -c bar -s test -r 2
  this patch series consists of 1 patches.
  
  
  displaying [PATCH fooFlag barFlag] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH fooFlag barFlag] test
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  

test multiple flags for multiple patches:
  $ hg email --date '1970-1-1 0:1' -n --flag fooFlag --flag barFlag -f quux -t foo \
  >  -c bar -s test -r 0:1
  this patch series consists of 2 patches.
  
  
  Write the introductory message for the patch series.
  
  
  displaying [PATCH 0 of 2 fooFlag barFlag] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2 fooFlag barFlag] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  Cc: bar
  
  
  displaying [PATCH 1 of 2 fooFlag barFlag] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2 fooFlag barFlag] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
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
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2 fooFlag barFlag] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2 fooFlag barFlag] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  Cc: bar
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  

test multi-address parsing:
  $ hg email --date '1980-1-1 0:1' -m tmp.mbox -f quux -t 'spam<spam><eggs>' \
  >  -t toast -c 'foo,bar@example.com' -c '"A, B <>" <a@example.com>' -s test -r 0 \
  >  --config email.bcc='"Quux, A." <quux>'
  this patch series consists of 1 patches.
  
  
  sending [PATCH] test ...
  $ cat < tmp.mbox
  From quux ... ... .. ..:..:.. .... (re)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.315532860@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: quux
  To: spam <spam>, eggs, toast (no-py3 !)
  Cc: foo, bar@example.com, "A, B <>" <a@example.com> (no-py3 !)
  Bcc: "Quux, A." <quux> (no-py3 !)
  To: =?iso-8859-1?q?spam?= <spam>, eggs, toast (py3 !)
  Cc: foo, bar@example.com, =?iso-8859-1?q?A=2C_B_=3C=3E?= <a@example.com> (py3 !)
  Bcc: =?iso-8859-1?q?Quux=2C_A=2E?= <quux> (py3 !)
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  

test flag template:
  $ echo foo > intro.text
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -r 0:1 \
  > --desc intro.text --subject test \
  > --config patchbomb.flagtemplate='R{rev}'
  this patch series consists of 2 patches.
  
  Cc: 
  
  displaying [PATCH 0 of 2 R1] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 2 R1] test
  Message-Id: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  
  foo
  
  displaying [PATCH 1 of 2 R0] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 2 R0] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 2
  Message-Id: <8580ff50825a50c8f716.61@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:01 +0000
  From: quux
  To: foo
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  displaying [PATCH 2 of 2 R1] b ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 2 of 2 R1] b
  X-Mercurial-Node: 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 2
  Message-Id: <97d72e5f12c7e84f8506.62@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.61@test-hostname>
  In-Reply-To: <patchbomb.60@test-hostname>
  References: <patchbomb.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:02 +0000
  From: quux
  To: foo
  
  # HG changeset patch
  # User test
  # Date 2 0
  #      Thu Jan 01 00:00:02 1970 +0000
  # Node ID 97d72e5f12c7e84f85064aa72e5a297142c36ed9
  # Parent  8580ff50825a50c8f716709acdf8de0deddcd6ab
  b
  
  diff -r 8580ff50825a -r 97d72e5f12c7 b
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/b	Thu Jan 01 00:00:02 1970 +0000
  @@ -0,0 +1,1 @@
  +b
  

test flag template plus --flag:
  $ hg email --date '1970-1-1 0:1' -n -f quux -t foo -r 0 --flag 'V2' \
  > --config patchbomb.flagtemplate='{branch} {flags}'
  this patch series consists of 1 patches.
  
  Cc: 
  
  displaying [PATCH default V2] a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH default V2] a
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.60@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.60@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Thu, 01 Jan 1970 00:01:00 +0000
  From: quux
  To: foo
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  

test multi-byte domain parsing:
  >>> with open('toaddress.txt', 'wb') as f:
  ...  f.write(b'bar@\xfcnicode.com') and None
  $ HGENCODING=iso-8859-1
  $ export HGENCODING
  $ hg email --date '1980-1-1 0:1' -m tmp.mbox -f quux -t "`cat toaddress.txt`" -s test -r 0
  this patch series consists of 1 patches.
  
  Cc: 
  
  sending [PATCH] test ...

  $ cat tmp.mbox
  From quux ... ... .. ..:..:.. .... (re)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: 8580ff50825a50c8f716709acdf8de0deddcd6ab
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <8580ff50825a50c8f716.315532860@test-hostname>
  X-Mercurial-Series-Id: <8580ff50825a50c8f716.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: quux
  To: bar@xn--nicode-2ya.com
  
  # HG changeset patch
  # User test
  # Date 1 0
  #      Thu Jan 01 00:00:01 1970 +0000
  # Node ID 8580ff50825a50c8f716709acdf8de0deddcd6ab
  # Parent  0000000000000000000000000000000000000000
  a
  
  diff -r 000000000000 -r 8580ff50825a a
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:01 1970 +0000
  @@ -0,0 +1,1 @@
  +a
  
  

test outgoing:
  $ hg up 1
  0 files updated, 0 files merged, 6 files removed, 0 files unresolved

  $ hg branch test
  marked working directory as branch test
  (branches are permanent and global, did you want a bookmark?)

  $ echo d > d
  $ hg add d
  $ hg ci -md -d '4 0'
  $ echo d >> d
  $ hg ci -mdd -d '5 0'
  $ hg log -G --template "{rev}:{node|short} {desc|firstline}\n"
  @  10:3b6f1ec9dde9 dd
  |
  o  9:2f9fa9b998c5 d
  |
  | o  8:9cea7492c36b Added tag two, two.diff for changeset ff2c9fa2018b
  | |
  | o  7:3b775b32716d Added tag one, one.patch for changeset 97d72e5f12c7
  | |
  | o  6:c41d7353114c Added tag zero, zero.foo for changeset 8580ff50825a
  | |
  | o  5:4d6f44f466c9 isolatin 8-bit encoding
  | |
  | o  4:0c7b871cb86b long line
  | |
  | o  3:f81ef9782946 \xe7a (esc)
  | |
  | o  2:ff2c9fa2018b c
  |/
  o  1:97d72e5f12c7 b
  |
  o  0:8580ff50825a a
  
  $ hg phase --force --secret -r 10

Test without revisions specified
  $ hg email --date '1980-1-1 0:1' -n -o -t foo
  comparing with $TESTTMP/t
  From [test]: test
  this patch series consists of 1 patches.
  
  Cc: 
  
  displaying [PATCH] d ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] d
  X-Mercurial-Node: 2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <2f9fa9b998c5fe3ac2bd.315532860@test-hostname>
  X-Mercurial-Series-Id: <2f9fa9b998c5fe3ac2bd.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Branch test
  # Node ID 2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  d
  
  diff -r 97d72e5f12c7 -r 2f9fa9b998c5 d
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/d	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,1 @@
  +d
  
  $ hg email --date '1980-1-1 0:1' -n -t foo -s test -o ../t -r 'rev(10) or rev(6)'
  comparing with ../t
  From [test]: test
  this patch series consists of 6 patches.
  
  
  Write the introductory message for the patch series.
  
  Cc: 
  
  displaying [PATCH 0 of 6] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 0 of 6] test
  Message-Id: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: test
  To: foo
  
  
  displaying [PATCH 1 of 6] c ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 1 of 6] c
  X-Mercurial-Node: ff2c9fa2018b15fa74b33363bda9527323e2a99f
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 6
  Message-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  In-Reply-To: <patchbomb.315532860@test-hostname>
  References: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:01 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 3 0
  #      Thu Jan 01 00:00:03 1970 +0000
  # Node ID ff2c9fa2018b15fa74b33363bda9527323e2a99f
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  c
  
  diff -r 97d72e5f12c7 -r ff2c9fa2018b c
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/c	Thu Jan 01 00:00:03 1970 +0000
  @@ -0,0 +1,1 @@
  +c
  
  displaying [PATCH 2 of 6] \xe7a ... (esc)
  MIME-Version: 1.0
  Content-Type: text/plain; charset="iso-8859-1"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH 2 of 6] \xe7a (esc) (no-py3 !)
  Subject: =?utf-8?b?W1BBVENIIDIgb2YgNl0gw6dh?= (py3 !)
  X-Mercurial-Node: f81ef97829467e868fc405fccbcfa66217e4d3e6
  X-Mercurial-Series-Index: 2
  X-Mercurial-Series-Total: 6
  Message-Id: <f81ef97829467e868fc4.315532862@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  In-Reply-To: <patchbomb.315532860@test-hostname>
  References: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:02 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID f81ef97829467e868fc405fccbcfa66217e4d3e6
  # Parent  ff2c9fa2018b15fa74b33363bda9527323e2a99f
  =E7a
  
  diff -r ff2c9fa2018b -r f81ef9782946 description
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/description	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,3 @@
  +a multiline
  +
  +description
  diff -r ff2c9fa2018b -r f81ef9782946 utf
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/utf	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,1 @@
  +h=C3=B6mma!
  
  displaying [PATCH 3 of 6] long line ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH 3 of 6] long line
  X-Mercurial-Node: 0c7b871cb86b61a1c07e244393603c361e4a178d
  X-Mercurial-Series-Index: 3
  X-Mercurial-Series-Total: 6
  Message-Id: <0c7b871cb86b61a1c07e.315532863@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  In-Reply-To: <patchbomb.315532860@test-hostname>
  References: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:03 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Node ID 0c7b871cb86b61a1c07e244393603c361e4a178d
  # Parent  f81ef97829467e868fc405fccbcfa66217e4d3e6
  long line
  
  diff -r f81ef9782946 -r 0c7b871cb86b long
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/long	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,4 @@
  +xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  +foo
  +
  +bar
  
  displaying [PATCH 4 of 6] isolatin 8-bit encoding ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="iso-8859-1"
  Content-Transfer-Encoding: quoted-printable
  Subject: [PATCH 4 of 6] isolatin 8-bit encoding
  X-Mercurial-Node: 4d6f44f466c96d89f2e7e865a70ff41d8b6eee37
  X-Mercurial-Series-Index: 4
  X-Mercurial-Series-Total: 6
  Message-Id: <4d6f44f466c96d89f2e7.315532864@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  In-Reply-To: <patchbomb.315532860@test-hostname>
  References: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:04 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 5 0
  #      Thu Jan 01 00:00:05 1970 +0000
  # Node ID 4d6f44f466c96d89f2e7e865a70ff41d8b6eee37
  # Parent  0c7b871cb86b61a1c07e244393603c361e4a178d
  isolatin 8-bit encoding
  
  diff -r 0c7b871cb86b -r 4d6f44f466c9 isolatin
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/isolatin	Thu Jan 01 00:00:05 1970 +0000
  @@ -0,0 +1,1 @@
  +h=F6mma!
  
  displaying [PATCH 5 of 6] Added tag zero, zero.foo for changeset 8580ff50825a ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 5 of 6] Added tag zero, zero.foo for changeset 8580ff50825a
  X-Mercurial-Node: c41d7353114ccb07a50a822ad5ddf47051c88ec2
  X-Mercurial-Series-Index: 5
  X-Mercurial-Series-Total: 6
  Message-Id: <c41d7353114ccb07a50a.315532865@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  In-Reply-To: <patchbomb.315532860@test-hostname>
  References: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:05 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID c41d7353114ccb07a50a822ad5ddf47051c88ec2
  # Parent  4d6f44f466c96d89f2e7e865a70ff41d8b6eee37
  Added tag zero, zero.foo for changeset 8580ff50825a
  
  diff -r 4d6f44f466c9 -r c41d7353114c .hgtags
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/.hgtags	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,2 @@
  +8580ff50825a50c8f716709acdf8de0deddcd6ab zero
  +8580ff50825a50c8f716709acdf8de0deddcd6ab zero.foo
  
  displaying [PATCH 6 of 6] d ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH 6 of 6] d
  X-Mercurial-Node: 2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  X-Mercurial-Series-Index: 6
  X-Mercurial-Series-Total: 6
  Message-Id: <2f9fa9b998c5fe3ac2bd.315532866@test-hostname>
  X-Mercurial-Series-Id: <ff2c9fa2018b15fa74b3.315532861@test-hostname>
  In-Reply-To: <patchbomb.315532860@test-hostname>
  References: <patchbomb.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:06 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Branch test
  # Node ID 2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  d
  
  diff -r 97d72e5f12c7 -r 2f9fa9b998c5 d
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/d	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,1 @@
  +d
  

Don't prompt for a CC header.

  $ echo "[email]" >> $HGRCPATH
  $ echo "cc=" >> $HGRCPATH

dest#branch URIs:
  $ hg email --date '1980-1-1 0:1' -n -t foo -s test -o ../t#test
  comparing with ../t#test
  From [test]: test
  this patch series consists of 1 patches.
  
  
  displaying [PATCH] test ...
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: 2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <2f9fa9b998c5fe3ac2bd.315532860@test-hostname>
  X-Mercurial-Series-Id: <2f9fa9b998c5fe3ac2bd.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 4 0
  #      Thu Jan 01 00:00:04 1970 +0000
  # Branch test
  # Node ID 2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  # Parent  97d72e5f12c7e84f85064aa72e5a297142c36ed9
  d
  
  diff -r 97d72e5f12c7 -r 2f9fa9b998c5 d
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/d	Thu Jan 01 00:00:04 1970 +0000
  @@ -0,0 +1,1 @@
  +d
  
#if no-windows

Set up a fake sendmail program

  $ cat > pretendmail.sh << 'EOF'
  > #!/bin/sh
  > echo "$@"
  > cat
  > EOF
  $ chmod +x pretendmail.sh

  $ echo '[email]' >> $HGRCPATH
  $ echo "method=`pwd`/pretendmail.sh" >> $HGRCPATH

Test introduction configuration
=================================

  $ echo '[patchbomb]' >> $HGRCPATH

"auto" setting
----------------

  $ echo 'intro=auto' >> $HGRCPATH

single rev

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' | grep "Write the introductory message for the patch series."
  [1]

single rev + flag

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' --intro | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.


Multi rev

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '9::' | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.

"never" setting
-----------------

  $ echo 'intro=never' >> $HGRCPATH

single rev

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' | grep "Write the introductory message for the patch series."
  [1]

single rev + flag

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' --intro | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.


Multi rev

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '9::' | grep "Write the introductory message for the patch series."
  [1]

Multi rev + flag

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '9::' --intro | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.

"always" setting
-----------------

  $ echo 'intro=always' >> $HGRCPATH

single rev

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.

single rev + flag

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' --intro | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.


Multi rev

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '9::' | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.

Multi rev + flag

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '9::' --intro | grep "Write the introductory message for the patch series."
  Write the introductory message for the patch series.

bad value setting
-----------------

  $ echo 'intro=oliviawearaclownnose' >> $HGRCPATH

single rev

  $ hg email --date '1980-1-1 0:1' -v -t foo -s test -r '10'
  From [test]: test
  this patch series consists of 1 patches.
  
  warning: invalid patchbomb.intro value "oliviawearaclownnose"
  (should be one of always, never, auto)
  -f test foo
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] test
  X-Mercurial-Node: 3b6f1ec9dde933a40a115a7990f8b320477231af
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <3b6f1ec9dde933a40a11*> (glob)
  X-Mercurial-Series-Id: <3b6f1ec9dde933a40a11.*> (glob)
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: test
  To: foo
  
  # HG changeset patch
  # User test
  # Date 5 0
  #      Thu Jan 01 00:00:05 1970 +0000
  # Branch test
  # Node ID 3b6f1ec9dde933a40a115a7990f8b320477231af
  # Parent  2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  dd
  
  diff -r 2f9fa9b998c5 -r 3b6f1ec9dde9 d
  --- a/d	Thu Jan 01 00:00:04 1970 +0000
  +++ b/d	Thu Jan 01 00:00:05 1970 +0000
  @@ -1,1 +1,2 @@
   d
  +d
  
  sending [PATCH] test ...
  sending mail: $TESTTMP/t2/pretendmail.sh -f test foo

Shell characters in addresses

  $ hg email --date '1980-1-1 0:1' -v -t '~foo/bar@example.com' -f 'me*@example.com' -r '10'
  this patch series consists of 1 patches.
  
  warning: invalid patchbomb.intro value "oliviawearaclownnose"
  (should be one of always, never, auto)
  -f me*@example.com ~foo/bar@example.com
  MIME-Version: 1.0
  Content-Type: text/plain; charset="us-ascii"
  Content-Transfer-Encoding: 7bit
  Subject: [PATCH] dd
  X-Mercurial-Node: 3b6f1ec9dde933a40a115a7990f8b320477231af
  X-Mercurial-Series-Index: 1
  X-Mercurial-Series-Total: 1
  Message-Id: <3b6f1ec9dde933a40a11.315532860@test-hostname>
  X-Mercurial-Series-Id: <3b6f1ec9dde933a40a11.315532860@test-hostname>
  User-Agent: Mercurial-patchbomb/* (glob)
  Date: Tue, 01 Jan 1980 00:01:00 +0000
  From: me*@example.com
  To: ~foo/bar@example.com
  
  # HG changeset patch
  # User test
  # Date 5 0
  #      Thu Jan 01 00:00:05 1970 +0000
  # Branch test
  # Node ID 3b6f1ec9dde933a40a115a7990f8b320477231af
  # Parent  2f9fa9b998c5fe3ac2bd9a2b14bfcbeecbc7c268
  dd
  
  diff -r 2f9fa9b998c5 -r 3b6f1ec9dde9 d
  --- a/d	Thu Jan 01 00:00:04 1970 +0000
  +++ b/d	Thu Jan 01 00:00:05 1970 +0000
  @@ -1,1 +1,2 @@
   d
  +d
  
  sending [PATCH] dd ...
  sending mail: $TESTTMP/t2/pretendmail.sh -f 'me*@example.com' '~foo/bar@example.com'

Test pull url header
=================================

basic version

  $ echo 'intro=auto' >> $HGRCPATH
  $ echo "publicurl=$TESTTMP/t2" >> $HGRCPATH
  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10' | grep '^#'
  abort: public url $TESTTMP/t2 is missing 3b6f1ec9dde9
  (use 'hg push $TESTTMP/t2 -r 3b6f1ec9dde9')
  [1]

public missing

  $ echo 'publicurl=$TESTTMP/missing' >> $HGRCPATH
  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10'
  unable to access public repo: $TESTTMP/missing
  abort: repository $TESTTMP/missing not found
  [255]

node missing at public

  $ hg clone -r '9' . ../t3
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 3 files
  new changesets 8580ff50825a:2f9fa9b998c5
  updating to branch test
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo 'publicurl=$TESTTMP/t3' >> $HGRCPATH
  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '10'
  abort: public url $TESTTMP/t3 is missing 3b6f1ec9dde9
  (use 'hg push $TESTTMP/t3 -r 3b6f1ec9dde9')
  [255]

multiple heads are missing at public

  $ hg email --date '1980-1-1 0:1' -t foo -s test -r '2+10'
  abort: public "$TESTTMP/t3" is missing ff2c9fa2018b and 1 others
  (use 'hg push $TESTTMP/t3 -r ff2c9fa2018b -r 3b6f1ec9dde9')
  [255]

#endif
