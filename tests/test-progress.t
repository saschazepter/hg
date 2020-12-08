
  $ cat > loop.py <<EOF
  > from __future__ import absolute_import
  > import time
  > from mercurial import commands, registrar
  > 
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > 
  > class incrementingtime(object):
  >     def __init__(self):
  >         self._time = 0.0
  >     def __call__(self):
  >         self._time += 0.25
  >         return self._time
  > time.time = incrementingtime()
  > 
  > @command(b'loop',
  >     [(b'', b'total', b'', b'override for total'),
  >     (b'', b'nested', False, b'show nested results'),
  >     (b'', b'parallel', False, b'show parallel sets of results'),
  >     (b'', b'warn', False, b'show warning if step divisible by 3')],
  >     b'hg loop LOOPS',
  >     norepo=True)
  > def loop(ui, loops, **opts):
  >     loops = int(loops)
  >     total = None
  >     if loops >= 0:
  >         total = loops
  >     if opts.get('total', None):
  >         total = int(opts.get('total'))
  >     nested = False
  >     if opts.get('nested', None):
  >         nested = True
  >     loops = abs(loops)
  >     showwarn = opts.get('warn', False)
  > 
  >     progress = ui.makeprogress(topiclabel, unit=b'loopnum', total=total)
  >     other = ui.makeprogress(b'other', unit=b'othernum', total=total)
  >     for i in range(loops):
  >         progress.update(i, item=getloopitem(i))
  >         if opts.get('parallel'):
  >             other.update(i, item=b'other.%d' % i)
  >         if nested:
  >             nested_steps = 2
  >             if i and i % 4 == 0:
  >                 nested_steps = 5
  >             nested = ui.makeprogress(b'nested', unit=b'nestnum',
  >                                      total=nested_steps)
  >             for j in range(nested_steps):
  >                 nested.update(j, item=b'nested.%d' % j)
  >             nested.complete()
  >         if showwarn and i % 3 == 0:
  >             ui.warn(b'reached step %d\n' %i)
  >     progress.complete()
  > 
  > topiclabel = b'loop'
  > def getloopitem(i):
  >     return b'loop.%d' % i
  > 
  > EOF

  $ cp $HGRCPATH $HGRCPATH.orig
  $ echo "[extensions]" >> $HGRCPATH
  $ echo "progress=" >> $HGRCPATH
  $ echo "loop=`pwd`/loop.py" >> $HGRCPATH
  $ echo "[progress]" >> $HGRCPATH
  $ echo "format = topic bar number" >> $HGRCPATH
  $ echo "assume-tty=1" >> $HGRCPATH
  $ echo "width=60" >> $HGRCPATH

test default params, display nothing because of delay

  $ hg -y loop 3
  $ echo "delay=0" >> $HGRCPATH
  $ echo "refresh=0" >> $HGRCPATH

test with delay=0, refresh=0

  $ hg -y loop 3
  \r (no-eol) (esc)
  loop [                                                ] 0/3\r (no-eol) (esc)
  loop [===============>                                ] 1/3\r (no-eol) (esc)
  loop [===============================>                ] 2/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
no progress with --quiet
  $ hg -y loop 3 --quiet

test plain mode exception
  $ HGPLAINEXCEPT=progress hg -y loop 1
  \r (no-eol) (esc)
  loop [                                                ] 0/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

test nested short-lived topics (which shouldn't display with nestdelay):

  $ hg -y loop 3 --nested
  \r (no-eol) (esc)
  loop [                                                ] 0/3\r (no-eol) (esc)
  loop [===============>                                ] 1/3\r (no-eol) (esc)
  loop [===============================>                ] 2/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

Test nested long-lived topic which has the same name as a short-lived
peer. We shouldn't get stuck showing the short-lived inner steps, and
should go back to skipping the inner steps when the slow nested step
finishes.

  $ hg -y loop 7 --nested
  \r (no-eol) (esc)
  loop [                                                ] 0/7\r (no-eol) (esc)
  loop [=====>                                          ] 1/7\r (no-eol) (esc)
  loop [============>                                   ] 2/7\r (no-eol) (esc)
  loop [===================>                            ] 3/7\r (no-eol) (esc)
  loop [==========================>                     ] 4/7\r (no-eol) (esc)
  nested [==========================>                   ] 3/5\r (no-eol) (esc)
  nested [===================================>          ] 4/5\r (no-eol) (esc)
  loop [=================================>              ] 5/7\r (no-eol) (esc)
  loop [========================================>       ] 6/7\r (no-eol) (esc)
                                                              \r (no-eol) (esc)


  $ hg --config progress.changedelay=0 -y loop 3 --nested
  \r (no-eol) (esc)
  loop [                                                ] 0/3\r (no-eol) (esc)
  nested [                                              ] 0/2\r (no-eol) (esc)
  nested [======================>                       ] 1/2\r (no-eol) (esc)
  loop [===============>                                ] 1/3\r (no-eol) (esc)
  nested [                                              ] 0/2\r (no-eol) (esc)
  nested [======================>                       ] 1/2\r (no-eol) (esc)
  loop [===============================>                ] 2/3\r (no-eol) (esc)
  nested [                                              ] 0/2\r (no-eol) (esc)
  nested [======================>                       ] 1/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)


test two topics being printed in parallel (as when we're doing a local
--pull clone, where you get the unbundle and bundle progress at the
same time):
  $ hg loop 3 --parallel
  \r (no-eol) (esc)
  loop [                                                ] 0/3\r (no-eol) (esc)
  loop [===============>                                ] 1/3\r (no-eol) (esc)
  loop [===============================>                ] 2/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
test refresh is taken in account

  $ hg -y --config progress.refresh=100 loop 3

test format options 1

  $ hg -y --config 'progress.format=number topic item+2' loop 2
  \r (no-eol) (esc)
  0/2 loop lo\r (no-eol) (esc)
  1/2 loop lo\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

test format options 2

  $ hg -y --config 'progress.format=number item-3 bar' loop 2
  \r (no-eol) (esc)
  0/2 p.0 [                                                 ]\r (no-eol) (esc)
  1/2 p.1 [=======================>                         ]\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

test format options and indeterminate progress

  $ hg -y --config 'progress.format=number item bar' loop -- -2
  \r (no-eol) (esc)
  0 loop.0               [ <=>                              ]\r (no-eol) (esc)
  1 loop.1               [  <=>                             ]\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

make sure things don't fall over if count > total

  $ hg -y loop --total 4 6
  \r (no-eol) (esc)
  loop [                                                ] 0/4\r (no-eol) (esc)
  loop [===========>                                    ] 1/4\r (no-eol) (esc)
  loop [=======================>                        ] 2/4\r (no-eol) (esc)
  loop [===================================>            ] 3/4\r (no-eol) (esc)
  loop [===============================================>] 4/4\r (no-eol) (esc)
  loop [ <=>                                            ] 5/4\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

test interaction with ui.warn

  $ hg loop --warn 6
  \r (no-eol) (esc)
  loop [                                                ] 0/6\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  reached step 0
  \r (no-eol) (esc)
  loop [=======>                                        ] 1/6\r (no-eol) (esc)
  loop [===============>                                ] 2/6\r (no-eol) (esc)
  loop [=======================>                        ] 3/6\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  reached step 3
  \r (no-eol) (esc)
  loop [===============================>                ] 4/6\r (no-eol) (esc)
  loop [=======================================>        ] 5/6\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

test interaction with ui.timestamp-output

XXX: The timestamp on Windows with py2 hg is in 1970, and py3 hg is now.  But
the py2/py3 checks here test the test runner, not the binary.  The Windows lines
can be dropped when switching to py3-only.

  $ hg loop --warn --config ui.timestamp-output=true 6
  \r (no-eol) (esc)
  loop [                                                ] 0/6\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  [*T*] reached step 0 (glob) (windows !)
  \[20[2-9][0-9]-[01][0-9]-[0-3][0-9]T[0-5][0-9]:[0-5][0-9]:[0-5][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]\] reached step 0 (re) (no-windows !)
  \r (no-eol) (esc)
  loop [=======>                                        ] 1/6\r (no-eol) (esc)
  loop [===============>                                ] 2/6\r (no-eol) (esc)
  loop [=======================>                        ] 3/6\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  [*T*] reached step 3 (glob) (windows !)
  \[20[2-9][0-9]-[01][0-9]-[0-3][0-9]T[0-5][0-9]:[0-5][0-9]:[0-5][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]\] reached step 3 (re) (no-windows !)
  \r (no-eol) (esc)
  loop [===============================>                ] 4/6\r (no-eol) (esc)
  loop [=======================================>        ] 5/6\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

test immediate progress completion

  $ hg -y loop 0

test delay time estimates

#if no-chg

  $ cp $HGRCPATH.orig $HGRCPATH
  $ echo "[extensions]" >> $HGRCPATH
  $ echo "mocktime=$TESTDIR/mocktime.py" >> $HGRCPATH
  $ echo "progress=" >> $HGRCPATH
  $ echo "loop=`pwd`/loop.py" >> $HGRCPATH
  $ echo "[progress]" >> $HGRCPATH
  $ echo "assume-tty=1" >> $HGRCPATH
  $ echo "delay=25" >> $HGRCPATH
  $ echo "width=60" >> $HGRCPATH

  $ MOCKTIME=11 hg -y loop 8
  \r (no-eol) (esc)
  loop [=========>                                ] 2/8 1m07s\r (no-eol) (esc)
  loop [===============>                            ] 3/8 56s\r (no-eol) (esc)
  loop [=====================>                      ] 4/8 45s\r (no-eol) (esc)
  loop [==========================>                 ] 5/8 34s\r (no-eol) (esc)
  loop [================================>           ] 6/8 23s\r (no-eol) (esc)
  loop [=====================================>      ] 7/8 12s\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

  $ MOCKTIME=10000 hg -y loop 4
  \r (no-eol) (esc)
  loop [                                                ] 0/4\r (no-eol) (esc)
  loop [=========>                                ] 1/4 8h21m\r (no-eol) (esc)
  loop [====================>                     ] 2/4 5h34m\r (no-eol) (esc)
  loop [==============================>           ] 3/4 2h47m\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

  $ MOCKTIME=1000000 hg -y loop 4
  \r (no-eol) (esc)
  loop [                                                ] 0/4\r (no-eol) (esc)
  loop [=========>                                ] 1/4 5w00d\r (no-eol) (esc)
  loop [====================>                     ] 2/4 3w03d\r (no-eol) (esc)
  loop [=============================>           ] 3/4 11d14h\r (no-eol) (esc)
                                                              \r (no-eol) (esc)


  $ MOCKTIME=14000000 hg -y loop 4
  \r (no-eol) (esc)
  loop [                                                ] 0/4\r (no-eol) (esc)
  loop [=========>                                ] 1/4 1y18w\r (no-eol) (esc)
  loop [===================>                     ] 2/4 46w03d\r (no-eol) (esc)
  loop [=============================>           ] 3/4 23w02d\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

Non-linear progress:

  $ MOCKTIME='20 20 20 20 20 20 20 20 20 20 500 500 500 500 500 20 20 20 20 20' hg -y loop 20
  \r (no-eol) (esc)
  loop [=>                                      ]  1/20 6m21s\r (no-eol) (esc)
  loop [===>                                    ]  2/20 6m01s\r (no-eol) (esc)
  loop [=====>                                  ]  3/20 5m41s\r (no-eol) (esc)
  loop [=======>                                ]  4/20 5m21s\r (no-eol) (esc)
  loop [=========>                              ]  5/20 5m01s\r (no-eol) (esc)
  loop [===========>                            ]  6/20 4m41s\r (no-eol) (esc)
  loop [=============>                          ]  7/20 4m21s\r (no-eol) (esc)
  loop [===============>                        ]  8/20 4m01s\r (no-eol) (esc)
  loop [================>                      ]  9/20 25m40s\r (no-eol) (esc)
  loop [===================>                    ] 10/20 1h06m\r (no-eol) (esc)
  loop [=====================>                  ] 11/20 1h13m\r (no-eol) (esc)
  loop [=======================>                ] 12/20 1h07m\r (no-eol) (esc)
  loop [========================>              ] 13/20 58m19s\r (no-eol) (esc)
  loop [===========================>            ] 14/20 7m09s\r (no-eol) (esc)
  loop [=============================>          ] 15/20 3m38s\r (no-eol) (esc)
  loop [===============================>        ] 16/20 2m15s\r (no-eol) (esc)
  loop [=================================>      ] 17/20 1m27s\r (no-eol) (esc)
  loop [====================================>     ] 18/20 52s\r (no-eol) (esc)
  loop [======================================>   ] 19/20 25s\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

Time estimates should not fail when there's no end point:
  $ MOCKTIME=11 hg -y loop -- -4
  \r (no-eol) (esc)
  loop [ <=>                                              ] 2\r (no-eol) (esc)
  loop [  <=>                                             ] 3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)

#endif

test line trimming by '[progress] width', when progress topic contains
multi-byte characters, of which length of byte sequence and columns in
display are different from each other.

  $ cp $HGRCPATH.orig $HGRCPATH
  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > progress=
  > loop=`pwd`/loop.py
  > [progress]
  > assume-tty = 1
  > delay = 0
  > refresh = 0
  > EOF

  $ rm -f loop.pyc
  $ cat >> loop.py <<EOF
  > # use non-ascii characters as topic label of progress
  > # 2 x 4 = 8 columns, but 3 x 4 = 12 bytes
  > topiclabel = u'\u3042\u3044\u3046\u3048'.encode('utf-8')
  > EOF

  $ cat >> $HGRCPATH <<EOF
  > [progress]
  > format = topic number
  > width= 12
  > EOF

  $ hg --encoding utf-8 -y loop --total 3 3
  \r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\xe3\x81\x88 0/3\r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\xe3\x81\x88 1/3\r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\xe3\x81\x88 2/3\r (no-eol) (esc)
              \r (no-eol) (esc)

test calculation of bar width, when progress topic contains multi-byte
characters, of which length of byte sequence and columns in display
are different from each other.

  $ cat >> $HGRCPATH <<EOF
  > [progress]
  > format = topic bar
  > width= 21
  > # progwidth should be 9 (= 21 - (8+1) - 3)
  > EOF

  $ hg --encoding utf-8 -y loop --total 3 3
  \r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\xe3\x81\x88 [         ]\r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\xe3\x81\x88 [==>      ]\r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\xe3\x81\x88 [=====>   ]\r (no-eol) (esc)
                       \r (no-eol) (esc)

test trimming progress items, when they contain multi-byte characters,
of which length of byte sequence and columns in display are different
from each other.

  $ rm -f loop.pyc
  $ rm -Rf __pycache__
  $ cat >> loop.py <<EOF
  > # use non-ascii characters as loop items of progress
  > loopitems = [
  >     u'\u3042\u3044'.encode('utf-8'), # 2 x 2 = 4 columns
  >     u'\u3042\u3044\u3046'.encode('utf-8'), # 2 x 3 = 6 columns
  >     u'\u3042\u3044\u3046\u3048'.encode('utf-8'), # 2 x 4 = 8 columns
  > ]
  > def getloopitem(i):
  >     return loopitems[i % len(loopitems)]
  > EOF

  $ cat >> $HGRCPATH <<EOF
  > [progress]
  > # trim at tail side
  > format = item+6
  > EOF

  $ hg --encoding utf-8 -y loop --total 3 3
  \r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84  \r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\r (no-eol) (esc)
                       \r (no-eol) (esc)

  $ cat >> $HGRCPATH <<EOF
  > [progress]
  > # trim at left side
  > format = item-6
  > EOF

  $ hg --encoding utf-8 -y loop --total 3 3
  \r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84  \r (no-eol) (esc)
  \xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\r (no-eol) (esc)
  \xe3\x81\x84\xe3\x81\x86\xe3\x81\x88\r (no-eol) (esc)
                       \r (no-eol) (esc)
