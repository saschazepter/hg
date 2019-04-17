Tests for wire protocol version 2 exchange.
Tests in this file should be folded into existing tests once protocol
v2 has enough features that it can be enabled via #testcase in existing
tests.

  $ . $TESTDIR/wireprotohelpers.sh
  $ enablehttpv2client

  $ hg init server-simple
  $ enablehttpv2 server-simple
  $ cd server-simple
  $ cat >> .hg/hgrc << EOF
  > [phases]
  > publish = false
  > EOF
  $ echo a0 > a
  $ echo b0 > b
  $ hg -q commit -A -m 'commit 0'

  $ echo a1 > a
  $ hg commit -m 'commit 1'
  $ hg phase --public -r .
  $ echo a2 > a
  $ hg commit -m 'commit 2'

  $ hg -q up -r 0
  $ echo b1 > b
  $ hg -q commit -m 'head 2 commit 1'
  $ echo b2 > b
  $ hg -q commit -m 'head 2 commit 2'

  $ hg serve -p $HGPORT -d --pid-file hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ cd ..

Test basic clone

Output is flaky, save it in a file and check part independently
  $ hg --debug clone -U http://localhost:$HGPORT client-simple > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset 4432d83626e8
  add changeset cd2534766bec
  add changeset e96ae20f4188
  add changeset caa2a465451d
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '\xa9\x88\xfbCX>\x87\x1d\x1e\xd5u\x0e\xe0t\xc6\xd8@\xbb\xbf\xc8',
      '\xec\x80NH\x8c \x88\xc25\t\x9a\x10 u\x13\xbe\xcd\xc3\xdd\xa5',
      '\x04\\\x7f9\'\xda\x13\xe7Z\xf8\xf0\xe4\xf0HI\xe4a\xa9x\x0f',
      '7\x9c\xb0\xc2\xe6d\\y\xdd\xc5\x9a\x1dG\'\xa9\xfb\x83\n\xeb&'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          'D2\xd86&\xe8\xa9\x86U\xf0b\xec\x1f*C\xb0\x7f\x7f\xbb\xb0',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f',
          '\xe9j\xe2\x0fA\x88H{\x9a\xe4\xef9A\xc2|\x81\x141F\xe5',
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets 3390ef850073:caa2a465451d (3 drafts)
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=43; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=941; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=992; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=901; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

All changesets should have been transferred

  $ hg -R client-simple debugindex -c
     rev linkrev nodeid       p1           p2
       0       0 3390ef850073 000000000000 000000000000
       1       1 4432d83626e8 3390ef850073 000000000000
       2       2 cd2534766bec 4432d83626e8 000000000000
       3       3 e96ae20f4188 3390ef850073 000000000000
       4       4 caa2a465451d e96ae20f4188 000000000000

  $ hg -R client-simple log -G -T '{rev} {node} {phase}\n'
  o  4 caa2a465451dd1facda0f5b12312c355584188a1 draft
  |
  o  3 e96ae20f4188487b9ae4ef3941c27c81143146e5 draft
  |
  | o  2 cd2534766bece138c7c1afdc6825302f0f62d81f draft
  | |
  | o  1 4432d83626e8a98655f062ec1f2a43b07f7fbbb0 public
  |/
  o  0 3390ef850073fbc2f0dfff2244342c8e9229013a public
  

All manifests should have been transferred

  $ hg -R client-simple debugindex -m
     rev linkrev nodeid       p1           p2
       0       0 992f4779029a 000000000000 000000000000
       1       1 a988fb43583e 992f4779029a 000000000000
       2       2 ec804e488c20 a988fb43583e 000000000000
       3       3 045c7f3927da 992f4779029a 000000000000
       4       4 379cb0c2e664 045c7f3927da 000000000000

Cloning only a specific revision works

Output is flaky, save it in a file and check part independently
  $ hg --debug clone -U -r 4432d83626e8 http://localhost:$HGPORT client-singlehead > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  sending 1 commands
  sending command lookup: {
    'key': '4432d83626e8'
  }
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          'D2\xd86&\xe8\xa9\x86U\xf0b\xec\x1f*C\xb0\x7f\x7f\xbb\xb0'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset 4432d83626e8
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '\xa9\x88\xfbCX>\x87\x1d\x1e\xd5u\x0e\xe0t\xc6\xd8@\xbb\xbf\xc8'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          'D2\xd86&\xe8\xa9\x86U\xf0b\xec\x1f*C\xb0\x7f\x7f\xbb\xb0'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets 3390ef850073:4432d83626e8
  (sent 6 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=21; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=43; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=381; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=404; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=439; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

  $ cd client-singlehead

  $ hg log -G -T '{rev} {node} {phase}\n'
  o  1 4432d83626e8a98655f062ec1f2a43b07f7fbbb0 public
  |
  o  0 3390ef850073fbc2f0dfff2244342c8e9229013a public
  

  $ hg debugindex -m
     rev linkrev nodeid       p1           p2
       0       0 992f4779029a 000000000000 000000000000
       1       1 a988fb43583e 992f4779029a 000000000000

Incremental pull works

Output is flaky, save it in a file and check part independently
  $ hg --debug pull > pull-output

  $ cat pull-output | grep -v "received frame"
  pulling from http://localhost:$HGPORT/
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': [
      'D2\xd86&\xe8\xa9\x86U\xf0b\xec\x1f*C\xb0\x7f\x7f\xbb\xb0'
    ]
  }
  searching for changes
  all local heads known remotely
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'roots': [
          'D2\xd86&\xe8\xa9\x86U\xf0b\xec\x1f*C\xb0\x7f\x7f\xbb\xb0'
        ],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset cd2534766bec
  add changeset e96ae20f4188
  add changeset caa2a465451d
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\xec\x80NH\x8c \x88\xc25\t\x9a\x10 u\x13\xbe\xcd\xc3\xdd\xa5',
      '\x04\\\x7f9\'\xda\x13\xe7Z\xf8\xf0\xe4\xf0HI\xe4a\xa9x\x0f',
      '7\x9c\xb0\xc2\xe6d\\y\xdd\xc5\x9a\x1dG\'\xa9\xfb\x83\n\xeb&'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'revisions': [
      {
        'nodes': [
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f',
          '\xe9j\xe2\x0fA\x88H{\x9a\xe4\xef9A\xc2|\x81\x141F\xe5',
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets cd2534766bec:caa2a465451d (3 drafts)
  (run 'hg update' to get a working copy)
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat pull-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=43; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=2; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=573; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=601; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=527; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm pull-output

  $ hg log -G -T '{rev} {node} {phase}\n'
  o  4 caa2a465451dd1facda0f5b12312c355584188a1 draft
  |
  o  3 e96ae20f4188487b9ae4ef3941c27c81143146e5 draft
  |
  | o  2 cd2534766bece138c7c1afdc6825302f0f62d81f draft
  | |
  | o  1 4432d83626e8a98655f062ec1f2a43b07f7fbbb0 public
  |/
  o  0 3390ef850073fbc2f0dfff2244342c8e9229013a public
  

  $ hg debugindex -m
     rev linkrev nodeid       p1           p2
       0       0 992f4779029a 000000000000 000000000000
       1       1 a988fb43583e 992f4779029a 000000000000
       2       2 ec804e488c20 a988fb43583e 000000000000
       3       3 045c7f3927da 992f4779029a 000000000000
       4       4 379cb0c2e664 045c7f3927da 000000000000

Phase-only update works
TODO this doesn't work

  $ hg -R ../server-simple phase --public -r caa2a465451dd
  $ hg --debug pull
  pulling from http://localhost:$HGPORT/
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': [
      '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f',
      '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1'
    ]
  }
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=43; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=3; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  searching for changes
  all remote heads known locally
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'roots': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'type': 'changesetdagrange'
      }
    ]
  }
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=13; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  checking for updated bookmarks
  (run 'hg update' to get a working copy)
  (sent 3 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ hg log -G -T '{rev} {node} {phase}\n'
  o  4 caa2a465451dd1facda0f5b12312c355584188a1 draft
  |
  o  3 e96ae20f4188487b9ae4ef3941c27c81143146e5 draft
  |
  | o  2 cd2534766bece138c7c1afdc6825302f0f62d81f draft
  | |
  | o  1 4432d83626e8a98655f062ec1f2a43b07f7fbbb0 public
  |/
  o  0 3390ef850073fbc2f0dfff2244342c8e9229013a public
  

  $ cd ..

Bookmarks are transferred on clone

  $ hg -R server-simple bookmark -r 3390ef850073fbc2f0dfff2244342c8e9229013a book-1
  $ hg -R server-simple bookmark -r cd2534766bece138c7c1afdc6825302f0f62d81f book-2

Output is flaky, save it in a file and check part independently
  $ hg --debug clone -U http://localhost:$HGPORT/ client-bookmarks > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset 4432d83626e8
  add changeset cd2534766bec
  add changeset e96ae20f4188
  add changeset caa2a465451d
  checking for updated bookmarks
  adding remote bookmark book-1
  adding remote bookmark book-2
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '\xa9\x88\xfbCX>\x87\x1d\x1e\xd5u\x0e\xe0t\xc6\xd8@\xbb\xbf\xc8',
      '\xec\x80NH\x8c \x88\xc25\t\x9a\x10 u\x13\xbe\xcd\xc3\xdd\xa5',
      '\x04\\\x7f9\'\xda\x13\xe7Z\xf8\xf0\xe4\xf0HI\xe4a\xa9x\x0f',
      '7\x9c\xb0\xc2\xe6d\\y\xdd\xc5\x9a\x1dG\'\xa9\xfb\x83\n\xeb&'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          'D2\xd86&\xe8\xa9\x86U\xf0b\xec\x1f*C\xb0\x7f\x7f\xbb\xb0',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f',
          '\xe9j\xe2\x0fA\x88H{\x9a\xe4\xef9A\xc2|\x81\x141F\xe5',
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets 3390ef850073:caa2a465451d (1 drafts)
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=43; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=979; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=992; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=901; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

  $ hg -R client-bookmarks bookmarks
     book-1                    0:3390ef850073
     book-2                    2:cd2534766bec

Server-side bookmark moves are reflected during `hg pull`

  $ hg -R server-simple bookmark -r cd2534766bece138c7c1afdc6825302f0f62d81f book-1
  moving bookmark 'book-1' forward from 3390ef850073

Output is flaky, save it in a file and check part independently
  $ hg -R client-bookmarks --debug pull > pull-output

  $ cat pull-output | grep -v "received frame"
  pulling from http://localhost:$HGPORT/
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': [
      '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f',
      '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1'
    ]
  }
  searching for changes
  all remote heads known locally
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'roots': [
          '\xca\xa2\xa4eE\x1d\xd1\xfa\xcd\xa0\xf5\xb1#\x12\xc3UXA\x88\xa1',
          '\xcd%4vk\xec\xe18\xc7\xc1\xaf\xdch%0/\x0fb\xd8\x1f'
        ],
        'type': 'changesetdagrange'
      }
    ]
  }
  checking for updated bookmarks
  updating bookmark book-1
  (run 'hg update' to get a working copy)
  (sent 3 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat pull-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=43; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=3; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=65; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm pull-output

  $ hg -R client-bookmarks bookmarks
     book-1                    2:cd2534766bec
     book-2                    2:cd2534766bec

  $ killdaemons.py

Let's set up a slightly more complicated server

  $ hg init server-2
  $ enablehttpv2 server-2
  $ cd server-2
  $ mkdir dir0 dir1
  $ echo a0 > a
  $ echo b0 > b
  $ hg -q commit -A -m 'commit 0'
  $ echo c0 > dir0/c
  $ echo d0 > dir0/d
  $ hg -q commit -A -m 'commit 1'
  $ echo e0 > dir1/e
  $ echo f0 > dir1/f
  $ hg -q commit -A -m 'commit 2'
  $ echo c1 > dir0/c
  $ echo e1 > dir1/e
  $ hg commit -m 'commit 3'
  $ hg serve -p $HGPORT -d --pid-file hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS

  $ cd ..

Narrow clone only fetches some files

Output is flaky, save it in a file and check part independently
  $ hg --config extensions.pullext=$TESTDIR/pullext.py --debug clone -U --include dir0/ http://localhost:$HGPORT/ client-narrow-0 > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset b709380892b1
  add changeset 47fe012ab237
  add changeset 97765fc3cd62
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '|2 \x1a\xa3\xa1R\xa9\xe6\xa9"+?\xa8\xd0\xe3\x0f\xc2V\xe8',
      '\x8d\xd0W<\x7f\xaf\xe2\x04F\xcc\xea\xac\x05N\xea\xa4x\x91M\xdb',
      '113\x85\xf2!\x8b\x08^\xb2Z\x821\x1e*\xdd\x0e\xeb\x8c3'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'pathfilter': {
      'include': [
        'path:dir0'
      ]
    },
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          '\xb7\t8\x08\x92\xb1\x93\xc1\t\x1d:\x81\x7fp`R\xe3F\x82\x1b',
          'G\xfe\x01*\xb27\xa8\xc7\xfc\x0cx\xf9\xf2mXf\xee\xf3\xf8%',
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets 3390ef850073:97765fc3cd62
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=22; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=783; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=967; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=449; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

#if reporevlogstore
  $ find client-narrow-0/.hg/store -type f -name '*.i' | sort
  client-narrow-0/.hg/store/00changelog.i
  client-narrow-0/.hg/store/00manifest.i
  client-narrow-0/.hg/store/data/dir0/c.i
  client-narrow-0/.hg/store/data/dir0/d.i
#endif

--exclude by itself works

Output is flaky, save it in a file and check part independently
  $ hg --config extensions.pullext=$TESTDIR/pullext.py --debug clone -U --exclude dir0/ http://localhost:$HGPORT/ client-narrow-1 > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset b709380892b1
  add changeset 47fe012ab237
  add changeset 97765fc3cd62
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '|2 \x1a\xa3\xa1R\xa9\xe6\xa9"+?\xa8\xd0\xe3\x0f\xc2V\xe8',
      '\x8d\xd0W<\x7f\xaf\xe2\x04F\xcc\xea\xac\x05N\xea\xa4x\x91M\xdb',
      '113\x85\xf2!\x8b\x08^\xb2Z\x821\x1e*\xdd\x0e\xeb\x8c3'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'pathfilter': {
      'exclude': [
        'path:dir0'
      ],
      'include': [
        'path:.'
      ]
    },
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          '\xb7\t8\x08\x92\xb1\x93\xc1\t\x1d:\x81\x7fp`R\xe3F\x82\x1b',
          'G\xfe\x01*\xb27\xa8\xc7\xfc\x0cx\xf9\xf2mXf\xee\xf3\xf8%',
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets 3390ef850073:97765fc3cd62
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=22; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=783; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=967; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=709; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

#if reporevlogstore
  $ find client-narrow-1/.hg/store -type f -name '*.i' | sort
  client-narrow-1/.hg/store/00changelog.i
  client-narrow-1/.hg/store/00manifest.i
  client-narrow-1/.hg/store/data/a.i
  client-narrow-1/.hg/store/data/b.i
  client-narrow-1/.hg/store/data/dir1/e.i
  client-narrow-1/.hg/store/data/dir1/f.i
#endif

Mixing --include and --exclude works

Output is flaky, save it in a file and check part independently
  $ hg --config extensions.pullext=$TESTDIR/pullext.py --debug clone -U --include dir0/ --exclude dir0/c http://localhost:$HGPORT/ client-narrow-2 > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset b709380892b1
  add changeset 47fe012ab237
  add changeset 97765fc3cd62
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '|2 \x1a\xa3\xa1R\xa9\xe6\xa9"+?\xa8\xd0\xe3\x0f\xc2V\xe8',
      '\x8d\xd0W<\x7f\xaf\xe2\x04F\xcc\xea\xac\x05N\xea\xa4x\x91M\xdb',
      '113\x85\xf2!\x8b\x08^\xb2Z\x821\x1e*\xdd\x0e\xeb\x8c3'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'pathfilter': {
      'exclude': [
        'path:dir0/c'
      ],
      'include': [
        'path:dir0'
      ]
    },
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          '\xb7\t8\x08\x92\xb1\x93\xc1\t\x1d:\x81\x7fp`R\xe3F\x82\x1b',
          'G\xfe\x01*\xb27\xa8\xc7\xfc\x0cx\xf9\xf2mXf\xee\xf3\xf8%',
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  updating the branch cache
  new changesets 3390ef850073:97765fc3cd62
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=22; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=783; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=967; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=160; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

#if reporevlogstore
  $ find client-narrow-2/.hg/store -type f -name '*.i' | sort
  client-narrow-2/.hg/store/00changelog.i
  client-narrow-2/.hg/store/00manifest.i
  client-narrow-2/.hg/store/data/dir0/d.i
#endif

--stream will use rawfiledata to transfer changelog and manifestlog, then
fall through to get files data

Output is flaky, save it in a file and check part independently
  $ hg --debug clone --stream -U http://localhost:$HGPORT client-stream-0 > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  sending 1 commands
  sending command rawstorefiledata: {
    'files': [
      'changelog',
      'manifestlog'
    ]
  }
  updating the branch cache
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': [
      '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
    ]
  }
  searching for changes
  all remote heads known locally
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'roots': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetdagrange'
      }
    ]
  }
  checking for updated bookmarks
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          '\xb7\t8\x08\x92\xb1\x93\xc1\t\x1d:\x81\x7fp`R\xe3F\x82\x1b',
          'G\xfe\x01*\xb27\xa8\xc7\xfc\x0cx\xf9\xf2mXf\xee\xf3\xf8%',
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1275; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=22; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=2; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=13; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1133; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

--stream + --include/--exclude will only obtain some files

Output is flaky, save it in a file and check part independently
  $ hg --debug --config extensions.pullext=$TESTDIR/pullext.py clone --stream --include dir0/ -U http://localhost:$HGPORT client-stream-2 > clone-output

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  sending 1 commands
  sending command rawstorefiledata: {
    'files': [
      'changelog',
      'manifestlog'
    ]
  }
  updating the branch cache
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': [
      '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
    ]
  }
  searching for changes
  all remote heads known locally
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'roots': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetdagrange'
      }
    ]
  }
  checking for updated bookmarks
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'pathfilter': {
      'include': [
        'path:dir0'
      ]
    },
    'revisions': [
      {
        'nodes': [
          '3\x90\xef\x85\x00s\xfb\xc2\xf0\xdf\xff"D4,\x8e\x92)\x01:',
          '\xb7\t8\x08\x92\xb1\x93\xc1\t\x1d:\x81\x7fp`R\xe3F\x82\x1b',
          'G\xfe\x01*\xb27\xa8\xc7\xfc\x0cx\xf9\xf2mXf\xee\xf3\xf8%',
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1275; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=22; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=2; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=13; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=449; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

#if reporevlogstore
  $ find client-stream-2/.hg/store -type f -name '*.i' | sort
  client-stream-2/.hg/store/00changelog.i
  client-stream-2/.hg/store/00manifest.i
  client-stream-2/.hg/store/data/dir0/c.i
  client-stream-2/.hg/store/data/dir0/d.i
#endif

Shallow clone doesn't work with revlogs

Output is flaky, save it in a file and check part independently
  $ hg --debug --config extensions.pullext=$TESTDIR/pullext.py clone --depth 1 -U http://localhost:$HGPORT client-shallow-revlogs > clone-output
  transaction abort!
  rollback completed
  abort: revlog storage does not support missing parents write mode
  [255]

  $ cat clone-output | grep -v "received frame"
  using http://localhost:$HGPORT/
  sending capabilities command
  query 1; heads
  sending 2 commands
  sending command heads: {}
  sending command known: {
    'nodes': []
  }
  sending 1 commands
  sending command changesetdata: {
    'fields': set([
      'bookmarks',
      'parents',
      'phase',
      'revision'
    ]),
    'revisions': [
      {
        'heads': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'roots': [],
        'type': 'changesetdagrange'
      }
    ]
  }
  add changeset 3390ef850073
  add changeset b709380892b1
  add changeset 47fe012ab237
  add changeset 97765fc3cd62
  checking for updated bookmarks
  sending 1 commands
  sending command manifestdata: {
    'fields': set([
      'parents',
      'revision'
    ]),
    'haveparents': True,
    'nodes': [
      '\x99/Gy\x02\x9a=\xf8\xd0fm\x00\xbb\x92OicN&A',
      '|2 \x1a\xa3\xa1R\xa9\xe6\xa9"+?\xa8\xd0\xe3\x0f\xc2V\xe8',
      '\x8d\xd0W<\x7f\xaf\xe2\x04F\xcc\xea\xac\x05N\xea\xa4x\x91M\xdb',
      '113\x85\xf2!\x8b\x08^\xb2Z\x821\x1e*\xdd\x0e\xeb\x8c3'
    ],
    'tree': ''
  }
  sending 1 commands
  sending command filesdata: {
    'fields': set([
      'linknode',
      'parents',
      'revision'
    ]),
    'haveparents': False,
    'revisions': [
      {
        'nodes': [
          '\x97v_\xc3\xcdbO\xd1\xfa\x01v\x93,!\xff\xd1j\xdfC.'
        ],
        'type': 'changesetexplicit'
      }
    ]
  }
  (sent 5 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat clone-output | grep "received frame"
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=22; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=11; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1; request=3; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=3; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=783; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=967; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)
  received frame(size=9; request=1; stream=2; streamflags=stream-begin; type=stream-settings; flags=eos)
  received frame(size=11; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=1005; request=1; stream=2; streamflags=encoded; type=command-response; flags=continuation)
  received frame(size=0; request=1; stream=2; streamflags=; type=command-response; flags=eos)

  $ rm clone-output

  $ killdaemons.py

Repo with 2 DAG branches introducing same filenode, to test linknode adjustment

  $ hg init server-linknode
  $ enablehttpv2 server-linknode
  $ cd server-linknode
  $ touch foo
  $ hg -q commit -Am initial
  $ echo foo > dupe-file
  $ hg commit -Am 'dupe 1'
  adding dupe-file
  $ hg -q up -r 0
  $ echo foo > dupe-file
  $ hg commit -Am 'dupe 2'
  adding dupe-file
  created new head
  $ hg serve -p $HGPORT -d --pid-file hg.pid -E error.log
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

Perform an incremental pull of both heads and ensure linkrev is written out properly

  $ hg clone -r 96ee1d7354c4 http://localhost:$HGPORT client-linknode-1
  new changesets 96ee1d7354c4
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client-linknode-1
  $ touch extra
  $ hg commit -Am extra
  adding extra
  $ cd ..

  $ hg clone -r 96ee1d7354c4 http://localhost:$HGPORT client-linknode-2
  new changesets 96ee1d7354c4
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client-linknode-2
  $ touch extra
  $ hg commit -Am extra
  adding extra
  $ cd ..

  $ hg -R client-linknode-1 pull -r 1681c33f9f80
  pulling from http://localhost:$HGPORT/
  searching for changes
  new changesets 1681c33f9f80
  (run 'hg update' to get a working copy)

#if reporevlogstore
  $ hg -R client-linknode-1 debugrevlogindex dupe-file
     rev linkrev nodeid       p1           p2
       0       2 2ed2a3912a0b 000000000000 000000000000
#endif

  $ hg -R client-linknode-2 pull -r 639c8990d6a5
  pulling from http://localhost:$HGPORT/
  searching for changes
  new changesets 639c8990d6a5
  (run 'hg update' to get a working copy)

#if reporevlogstore
  $ hg -R client-linknode-2 debugrevlogindex dupe-file
     rev linkrev nodeid       p1           p2
       0       2 2ed2a3912a0b 000000000000 000000000000
#endif
