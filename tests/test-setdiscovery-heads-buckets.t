==========================================
Testing of heads buckets helping discovery
==========================================


The heads buckets features group heads by bucket and associate a fingerprint to that bucket.

The goal is for a client to be able to cache the content of bucket and to reuse
it if the fingerprint is unchanged.

This test file check behavior related to this bucket computation.

  $ cat << EOF >> $HGRCPATH
  > [devel]
  > discovery.randomize=false
  > [experimental]
  > disco.heads-fingerprints=yes
  > EOF

setup a branchy repository
==========================

This create a repository made of small segment that keep branching and merging.

  >>> with open("dagdesc", "w") as f:
  ...     _ = f.write("+42:Paaaaaaaa\n")
  ...     for x in range(1, 100):
  ...         segment_length = 1 + ((~x) % 11) * (x % 13)
  ...         base_target = max(x - max((x**2) % min(19,  1 + x // 2), 1), 0)
  ...         merge_target = max(x - max((x**3) % min(31, 1 + x // 3), 1), 0)
  ...         base = f"{base_target:08b}".replace("0", "a").replace("1", "b")
  ...         this = f"{x:08b}".replace("0", "a").replace("1", "b")
  ...         other = f"{merge_target:08b}".replace("0", "a").replace("1", "b")
  ...         _ = f.write(f"<P{base}+{segment_length}/P{other}:P{this}\n")
  $ cat dagdesc
  +42:Paaaaaaaa
  <Paaaaaaaa+10/Paaaaaaaa:Paaaaaaab
  <Paaaaaaab+17/Paaaaaaab:Paaaaaaba
  <Paaaaaaba+22/Paaaaaaba:Paaaaaabb
  <Paaaaaabb+25/Paaaaaabb:Paaaaabaa
  <Paaaaabaa+26/Paaaaabaa:Paaaaabab
  <Paaaaabab+25/Paaaaabab:Paaaaabba
  <Paaaaabba+22/Paaaaabba:Paaaaabbb
  <Paaaaabaa+17/Paaaaabba:Paaaabaaa
  <Paaaabaaa+10/Paaaabaaa:Paaaabaab
  <Paaaaabba+1/Paaaabaab:Paaaababa
  <Paaaababa+111/Paaaabaaa:Paaaababb
  <Paaaabaaa+109/Paaaabaab:Paaaabbaa
  <Paaaabbaa+1/Paaaababb:Paaaabbab
  <Paaaababa+8/Paaaababa:Paaaabbba
  <Paaaabbba+13/Paaaabbaa:Paaaabbbb
  <Paaaabbaa+16/Paaaabbaa:Paaabaaaa
  <Paaabaaaa+17/Paaaabbaa:Paaabaaab
  <Paaaabbba+16/Paaabaaab:Paaabaaba
  <Paaabaaba+13/Paaaabbab:Paaabaabb
  <Paaabaaaa+8/Paaaabbba:Paaababaa
  <Paaababaa+1/Paaabaaaa:Paaababab
  <Paaabaaba+91/Paaababab:Paaababba
  <Paaababba+91/Paaabaaaa:Paaababbb
  <Paaababaa+89/Paaababbb:Paaabbaaa
  <Paaabbaaa+85/Paaabbaaa:Paaabbaab
  <Paaababba+1/Paaabaaba:Paaabbaba
  <Paaabbaba+6/Paaabbaaa:Paaabbabb
  <Paaabbaaa+9/Paaabbaba:Paaabbbaa
  <Paaabbbaa+10/Paaababaa:Paaabbbab
  <Paaabbaba+9/Paaabbaaa:Paaabbbba
  <Paaabbbba+6/Paaabbbaa:Paaabbbbb
  <Paaabbbaa+1/Paaababba:Paabaaaaa
  <Paabaaaaa+71/Paaabbaaa:Paabaaaab
  <Paaabbbba+73/Paaabbbba:Paabaaaba
  <Paabaaaba+73/Paaabbaaa:Paabaaabb
  <Paabaaaaa+71/Paaabbaaa:Paabaabaa
  <Paabaabaa+67/Paabaaaaa:Paabaabab
  <Paabaabab+61/Paaabbaba:Paabaabba
  <Paabaabba+1/Paabaabba:Paabaabbb
  <Paabaabaa+4/Paabaaaba:Paababaaa
  <Paabaaaaa+5/Paaabbbaa:Paababaab
  <Paaabbaba+4/Paabaabbb:Paabababa
  <Paabaabab+1/Paabaabaa:Paabababb
  <Paaabbabb+51/Paaabbbba:Paababbaa
  <Paabaaaba+55/Paababaaa:Paababbab
  <Paabaabbb+57/Paabaabba:Paababbba
  <Paabababa+57/Paabaaaaa:Paababbbb
  <Paabababb+55/Paababaab:Paabbaaaa
  <Paabababa+51/Paababaaa:Paabbaaab
  <Paabaabbb+45/Paabaaaba:Paabbaaba
  <Paabaaaba+37/Paabababa:Paabbaabb
  <Paababbba+1/Paabababa:Paabbabaa
  <Paabaabab+2/Paabaabaa:Paabbabab
  <Paababbab+1/Paabababb:Paabbabba
  <Paabbaabb+31/Paababbaa:Paabbabbb
  <Paabbabbb+37/Paabaabba:Paabbbaaa
  <Paabbbaaa+41/Paababbaa:Paabbbaab
  <Paabbbaab+43/Paababbba:Paabbbaba
  <Paabbabbb+43/Paababaaa:Paabbbabb
  <Paabbaabb+41/Paababbab:Paabbbbaa
  <Paababbab+37/Paabbaaaa:Paabbbbab
  <Paabbbaaa+31/Paabababa:Paabbbbba
  <Paababbba+23/Paababbba:Paabbbbbb
  <Paabbabab+13/Paabbaaba:Pabaaaaaa
  <Paabbbaba+1/Paababbaa:Pabaaaaab
  <Paabbbbab+11/Paababbbb:Pabaaaaba
  <Paabbbbba+19/Paabbabaa:Pabaaaabb
  <Paabbbbab+25/Paababbba:Pabaaabaa
  <Paabbbaba+29/Paabbaaaa:Pabaaabab
  <Paabbabab+31/Paabbabba:Pabaaabba
  <Pabaaaaab+31/Paabbaaaa:Pabaaabbb
  <Paabbbaaa+29/Paabbaaab:Pabaabaaa
  <Pabaaaaaa+25/Paabbbaaa:Pabaabaab
  <Pabaaabba+19/Paabbaaba:Pabaababa
  <Pabaababa+11/Paabbaaba:Pabaababb
  <Pabaababb+1/Paabbbaba:Pabaabbaa
  <Pabaabbaa+121/Paabbabaa:Pabaabbab
  <Pabaababa+1/Pabaabbab:Pabaabbba
  <Pabaaabba+9/Paabbbbaa:Pabaabbbb
  <Pabaaaaaa+15/Paabbabba:Pababaaaa
  <Pabaababb+19/Pababaaaa:Pababaaab
  <Pabaaaaab+21/Paabbbbba:Pababaaba
  <Pabaabaaa+21/Paabbbaaa:Pababaabb
  <Pabaabbab+19/Pababaaba:Pabababaa
  <Pababaaaa+15/Pabaaaaaa:Pabababab
  <Pababaaab+9/Paabbbaba:Pabababba
  <Pababaaaa+1/Pabababaa:Pabababbb
  <Pabaabbab+101/Pabaaaaba:Pababbaaa
  <Pabaabaaa+100/Paabbbbaa:Pababbaab
  <Pabababaa+97/Pabababba:Pababbaba
  <Pabaababb+1/Pabaaabaa:Pababbabb
  <Pababaabb+7/Paabbbbba:Pababbbaa
  <Pababbaab+11/Pababbbaa:Pababbbab
  <Pababbbab+13/Pababbbab:Pababbbba
  <Pababbbba+13/Pabababbb:Pababbbbb
  <Pababbbbb+11/Pabaaabab:Pabbaaaaa
  <Pababbbab+7/Pababbbbb:Pabbaaaab
  <Pababbaab+1/Pabbaaaab:Pabbaaaba
  <Pababaabb+81/Pabaaabab:Pabbaaabb

Also generate a handy list of pair of set of tags

  >>> with open("pairs", "w") as f:
  ...     for x in range(0, 5):
  ...         left = x * 20
  ...         right = left + 1
  ...         left_tags = "+".join([
  ...             f"P{l:08b}"
  ...             for l in range(left, left + 20, 2)
  ...         ]).replace("0", "a").replace("1", "b")
  ...         right_tags = "+".join([
  ...             f"P{r:08b}"
  ...             for r in range(right, right + 20, 2)
  ...         ]).replace("0", "a").replace("1", "b")
  ...         print(left_tags, right_tags, file=f)

  $ hg init main-repo
  $ hg -R main-repo debugbuilddag < dagdesc
  reading DAG from stdin
  $ cd main-repo

Show the revision number spread of the resulting heads

Note: if the bucket strategy change to use rank instead of revision number, we
should change the command below

  $ hg log -T '{rev}\n' --rev 'heads(all())' | f --line-count
  line-count=22
  $ hg log -T '{rev}\n' --rev 'heads(all())'
  195
  473
  539
  910
  940
  957
  1031
  1179
  2024
  2160
  2208
  2328
  2384
  2542
  2552
  2668
  2782
  2981
  2983
  3043
  3053
  3135



Test fingerprinting of heads buckets
===================================

display the current buckets and their fingerprint

  $ hg log -r 'max(all())' -T '{rev}\n'
  3135
  $ hg debug::heads-bucket-fingerprints
   fingerprint bucket-id head-count
      8ad425b4      2048          9
      5d988be1      2560         15
      97aacdfe      2816         17
      97aacdfe      2944         17
      b87e8dc5      3008         19
      dcd9a578      3072         21
      dcd9a578      3104         21
      dcd9a578      3120         21
      dcd9a578      3128         21
      dcd9a578      3132         21
      dcd9a578      3134         21
      b37762e3      3135         22


Buckets stability
-----------------

  $ multi_line_buckets() {
  >  number=$1
  >  hg debug::heads-bucket-fingerprints -T "{bucket_id}\n" > $TESTTMP/buckets-$number.txt
  >  hg debug::heads-bucket-fingerprints -T "bucket:       {bucket_id}\nfingerprint: {fingerprint}\n\n" > $TESTTMP/list-$number.txt
  > }

  $ changed() {
  >  echo '### Common bucket ###'
  >  cat $TESTTMP/buckets-$1.txt $TESTTMP/buckets-$2.txt | sort | uniq -d
  >  echo ''
  >  echo '### Difference ###'
  >  old=$TESTTMP/list-$1.txt
  >  new=$TESTTMP/list-$2.txt
  >  cmp $old $new || diff --minimal -U 1 $old $new | sed "s,\.txt.*,.txt,"
  > }

When adding a few more changeset, the lower buckets should remain the same

  $ multi_line_buckets 00
  $ hg debugbuilddag --from-existing "+25<5+50"
  $ hg log -r 'max(all())' -T '{rev}\n'
  3210
  $ hg debug::heads-bucket-fingerprints
   fingerprint bucket-id head-count
      8ad425b4      2048          9
      5d988be1      2560         15
      97aacdfe      2816         17
      dcd9a578      3072         21
      dcd9a578      3136         21
      09b89345      3168         22
      09b89345      3184         22
      09b89345      3200         22
      09b89345      3204         22
      09b89345      3208         22
      09b89345      3209         22
      c3fc2540      3210         23
  $ multi_line_buckets 01
  $ changed 00 01
  ### Common bucket ###
  2048
  2560
  2816
  3072
  
  ### Difference ###
  $TESTTMP/list-00.txt $TESTTMP/list-01.txt differ: char 141, line 10
  --- $TESTTMP/list-00.txt
  +++ $TESTTMP/list-01.txt
  @@ -9,8 +9,2 @@
   
  -bucket:       2944
  -fingerprint: 97aacdfe
  -
  -bucket:       3008
  -fingerprint: b87e8dc5
  -
   bucket:       3072
  @@ -18,19 +12,25 @@
   
  -bucket:       3104
  +bucket:       3136
   fingerprint: dcd9a578
   
  -bucket:       3120
  -fingerprint: dcd9a578
  +bucket:       3168
  +fingerprint: 09b89345
   
  -bucket:       3128
  -fingerprint: dcd9a578
  +bucket:       3184
  +fingerprint: 09b89345
   
  -bucket:       3132
  -fingerprint: dcd9a578
  +bucket:       3200
  +fingerprint: 09b89345
   
  -bucket:       3134
  -fingerprint: dcd9a578
  +bucket:       3204
  +fingerprint: 09b89345
   
  -bucket:       3135
  -fingerprint: b37762e3
  +bucket:       3208
  +fingerprint: 09b89345
  +
  +bucket:       3209
  +fingerprint: 09b89345
  +
  +bucket:       3210
  +fingerprint: c3fc2540
   

Getting bigger bucket
---------------------

Adding many more changeset will result in the usage of larger bucket over time

  $ hg debugbuilddag --from-existing "+500"
  $ hg log -r 'max(all())' -T '{rev}\n'
  3710
  $ hg debug::heads-bucket-fingerprints
   fingerprint bucket-id head-count
      8ad425b4      2048          9
      dcd9a578      3072         21
      09b89345      3328         22
      09b89345      3456         22
      09b89345      3584         22
      09b89345      3648         22
      09b89345      3680         22
      09b89345      3696         22
      09b89345      3704         22
      09b89345      3708         22
      09b89345      3709         22
      5da9a54a      3710         23
  $ multi_line_buckets 02
  $ changed 01 02
  ### Common bucket ###
  2048
  3072
  
  ### Difference ###
  $TESTTMP/list-01.txt $TESTTMP/list-02.txt differ: char 57, line 4
  --- $TESTTMP/list-01.txt
  +++ $TESTTMP/list-02.txt
  @@ -3,8 +3,2 @@
   
  -bucket:       2560
  -fingerprint: 5d988be1
  -
  -bucket:       2816
  -fingerprint: 97aacdfe
  -
   bucket:       3072
  @@ -12,25 +6,31 @@
   
  -bucket:       3136
  -fingerprint: dcd9a578
  +bucket:       3328
  +fingerprint: 09b89345
   
  -bucket:       3168
  +bucket:       3456
   fingerprint: 09b89345
   
  -bucket:       3184
  +bucket:       3584
   fingerprint: 09b89345
   
  -bucket:       3200
  +bucket:       3648
   fingerprint: 09b89345
   
  -bucket:       3204
  +bucket:       3680
   fingerprint: 09b89345
   
  -bucket:       3208
  +bucket:       3696
   fingerprint: 09b89345
   
  -bucket:       3209
  +bucket:       3704
   fingerprint: 09b89345
   
  -bucket:       3210
  -fingerprint: c3fc2540
  +bucket:       3708
  +fingerprint: 09b89345
  +
  +bucket:       3709
  +fingerprint: 09b89345
  +
  +bucket:       3710
  +fingerprint: 5da9a54a
   

  $ hg debugbuilddag --from-existing "+100<66+400"
  $ hg log -r 'max(all())' -T '{rev}\n'
  4210
  $ hg debug::heads-bucket-fingerprints
   fingerprint bucket-id head-count
      8ad425b4      2048          9
      dcd9a578      3072         21
      09b89345      3584         22
      41f733bd      3840         23
      41f733bd      3968         23
      41f733bd      4096         23
      41f733bd      4160         23
      41f733bd      4192         23
      41f733bd      4200         23
      41f733bd      4204         23
      41f733bd      4208         23
      41f733bd      4209         23
      77e4cc2e      4210         24
  $ multi_line_buckets 03
  $ changed 02 03
  ### Common bucket ###
  2048
  3072
  3584
  
  ### Difference ###
  $TESTTMP/list-02.txt $TESTTMP/list-03.txt differ: char 100, line 7
  --- $TESTTMP/list-02.txt
  +++ $TESTTMP/list-03.txt
  @@ -6,31 +6,34 @@
   
  -bucket:       3328
  +bucket:       3584
   fingerprint: 09b89345
   
  -bucket:       3456
  -fingerprint: 09b89345
  +bucket:       3840
  +fingerprint: 41f733bd
   
  -bucket:       3584
  -fingerprint: 09b89345
  +bucket:       3968
  +fingerprint: 41f733bd
   
  -bucket:       3648
  -fingerprint: 09b89345
  +bucket:       4096
  +fingerprint: 41f733bd
   
  -bucket:       3680
  -fingerprint: 09b89345
  +bucket:       4160
  +fingerprint: 41f733bd
   
  -bucket:       3696
  -fingerprint: 09b89345
  +bucket:       4192
  +fingerprint: 41f733bd
   
  -bucket:       3704
  -fingerprint: 09b89345
  +bucket:       4200
  +fingerprint: 41f733bd
   
  -bucket:       3708
  -fingerprint: 09b89345
  +bucket:       4204
  +fingerprint: 41f733bd
   
  -bucket:       3709
  -fingerprint: 09b89345
  +bucket:       4208
  +fingerprint: 41f733bd
   
  -bucket:       3710
  -fingerprint: 5da9a54a
  +bucket:       4209
  +fingerprint: 41f733bd
  +
  +bucket:       4210
  +fingerprint: 77e4cc2e
   

  $ hg debugbuilddag --from-existing "+500"
  $ hg log -r 'max(all())' -T '{rev}\n'
  4710
  $ hg debug::heads-bucket-fingerprints
   fingerprint bucket-id head-count
      8ad425b4      2048          9
      dcd9a578      3072         21
      41f733bd      4096         23
      41f733bd      4352         23
      41f733bd      4480         23
      41f733bd      4608         23
      41f733bd      4672         23
      41f733bd      4688         23
      41f733bd      4696         23
      41f733bd      4704         23
      41f733bd      4708         23
      41f733bd      4709         23
      d1f033f2      4710         24
  $ multi_line_buckets 04
  $ changed 03 04
  ### Common bucket ###
  2048
  3072
  4096
  
  ### Difference ###
  $TESTTMP/list-03.txt $TESTTMP/list-04.txt differ: char 99, line 7
  --- $TESTTMP/list-03.txt
  +++ $TESTTMP/list-04.txt
  @@ -6,34 +6,34 @@
   
  -bucket:       3584
  -fingerprint: 09b89345
  +bucket:       4096
  +fingerprint: 41f733bd
   
  -bucket:       3840
  +bucket:       4352
   fingerprint: 41f733bd
   
  -bucket:       3968
  +bucket:       4480
   fingerprint: 41f733bd
   
  -bucket:       4096
  +bucket:       4608
   fingerprint: 41f733bd
   
  -bucket:       4160
  +bucket:       4672
   fingerprint: 41f733bd
   
  -bucket:       4192
  +bucket:       4688
   fingerprint: 41f733bd
   
  -bucket:       4200
  +bucket:       4696
   fingerprint: 41f733bd
   
  -bucket:       4204
  +bucket:       4704
   fingerprint: 41f733bd
   
  -bucket:       4208
  +bucket:       4708
   fingerprint: 41f733bd
   
  -bucket:       4209
  +bucket:       4709
   fingerprint: 41f733bd
   
  -bucket:       4210
  -fingerprint: 77e4cc2e
  +bucket:       4710
  +fingerprint: d1f033f2
   

  $ hg debugbuilddag --from-existing "+75<25+125<25+300"
  $ hg log -r 'max(all())' -T '{rev}\n'
  5210
  $ hg debug::heads-bucket-fingerprints
   fingerprint bucket-id head-count
      8ad425b4      2048          9
      41f733bd      4096         23
      41f733bd      4608         23
      f171b049      4864         24
      113ee5ff      4992         25
      113ee5ff      5120         25
      113ee5ff      5152         25
      113ee5ff      5184         25
      113ee5ff      5200         25
      113ee5ff      5204         25
      113ee5ff      5208         25
      113ee5ff      5209         25
      322b8056      5210         26
  $ multi_line_buckets 05
  $ changed 04 05
  ### Common bucket ###
  2048
  4096
  4608
  
  ### Difference ###
  $TESTTMP/list-04.txt $TESTTMP/list-05.txt differ: char 57, line 4
  --- $TESTTMP/list-04.txt
  +++ $TESTTMP/list-05.txt
  @@ -3,5 +3,2 @@
   
  -bucket:       3072
  -fingerprint: dcd9a578
  -
   bucket:       4096
  @@ -9,31 +6,34 @@
   
  -bucket:       4352
  +bucket:       4608
   fingerprint: 41f733bd
   
  -bucket:       4480
  -fingerprint: 41f733bd
  +bucket:       4864
  +fingerprint: f171b049
   
  -bucket:       4608
  -fingerprint: 41f733bd
  +bucket:       4992
  +fingerprint: 113ee5ff
   
  -bucket:       4672
  -fingerprint: 41f733bd
  +bucket:       5120
  +fingerprint: 113ee5ff
   
  -bucket:       4688
  -fingerprint: 41f733bd
  +bucket:       5152
  +fingerprint: 113ee5ff
   
  -bucket:       4696
  -fingerprint: 41f733bd
  +bucket:       5184
  +fingerprint: 113ee5ff
   
  -bucket:       4704
  -fingerprint: 41f733bd
  +bucket:       5200
  +fingerprint: 113ee5ff
   
  -bucket:       4708
  -fingerprint: 41f733bd
  +bucket:       5204
  +fingerprint: 113ee5ff
   
  -bucket:       4709
  -fingerprint: 41f733bd
  +bucket:       5208
  +fingerprint: 113ee5ff
   
  -bucket:       4710
  -fingerprint: d1f033f2
  +bucket:       5209
  +fingerprint: 113ee5ff
  +
  +bucket:       5210
  +fingerprint: 322b8056
   


Bucket usage in discovery
=========================

  $ STEP="600 1200 1230 1500 2000 3315 4000 5000 5210"

  $ for x in $STEP; do
  >   hg bundle --exact --rev :$x ../first-$x.hg --quiet;
  > done
  $ cd ..

Simple full pull
----------------

  $ cd $TESTTMP
  $ mkdir simple-full-pull
  $ cd simple-full-pull
  $ hg init server
  $ hg clone ssh://user@dummy/simple-full-pull/server client
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ for step in $STEP; do
  >     echo
  >     echo "##### server goes to $step changesets"
  >     hg unbundle -R server ../first-$step.hg --quiet
  >     hg -R client pull --config devel.debug.discovery=yes
  > done
  
  ##### server goes to 600 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints
           received 5 server heads
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 601 changesets with 0 changes to 0 files (+4 heads)
  new changesets 1ea73414a91b:2e8c8ce74df7
  (run 'hg heads' to see heads, 'hg merge' to merge)
  
  ##### server goes to 1200 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 5)
           received 7 server heads, 3 cached, 10 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 600 changesets with 0 changes to 0 files (+5 heads)
  new changesets da1f9dad48ca:266b5ea5a79c
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 1230 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 10)
           received 1 server heads, 9 cached, 10 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 30 changesets with 0 changes to 0 files
  new changesets cad093e13ed4:ada45e7417b8
  (run 'hg update' to get a working copy)
  
  ##### server goes to 1500 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 10)
           received 12 server heads, 2 cached, 14 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 270 changesets with 0 changes to 0 files (+4 heads)
  new changesets 0889b4c30afe:bc915268d551
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 2000 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 14)
           received 9 server heads, 8 cached, 17 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 500 changesets with 0 changes to 0 files (+3 heads)
  new changesets a182e64e91a9:22b8522d1e58
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 3315 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 17)
           received 23 server heads
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1315 changesets with 0 changes to 0 files (+6 heads)
  new changesets e3dbe44aff39:d58e47499b55
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 4000 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 23)
           received 2 server heads, 22 cached, 24 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 685 changesets with 0 changes to 0 files (+1 heads)
  new changesets e69fa130d956:fe8d4a6c9087
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 5000 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 24)
           received 3 server heads, 23 cached, 26 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1000 changesets with 0 changes to 0 files (+2 heads)
  new changesets 23b0b7c9332a:993cd0837a5c
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 5210 changesets
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 26)
           received 1 server heads, 25 cached, 26 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 210 changesets with 0 changes to 0 files
  new changesets 74ba7dd140b5:518e7f4bc0ca
  (run 'hg update' to get a working copy)


final no-op pull

  $ hg -R client pull --config devel.debug.discovery=yes
  pulling from ssh://user@dummy/simple-full-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 26)
           received 0 server heads, 26 cached, 26 total
  searching for changes
  all remote heads known locally
  no changes found

Series of simple partial pull
-----------------------------

  $ cd $TESTTMP
  $ mkdir simple-partial-pull
  $ cd simple-partial-pull
  $ hg init server
  $ hg clone ssh://user@dummy/simple-partial-pull/server client
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ for step in $STEP; do
  >     echo
  >     echo "##### server goes to $step changesets"
  >     hg unbundle -R server ../first-$step.hg --quiet
  >     hg -R client pull --rev tip --config devel.debug.discovery=yes
  > done
  
  ##### server goes to 600 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints
           received 5 server heads
  adding changesets
  adding manifests
  adding file changes
  added 425 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:2e8c8ce74df7
  (run 'hg update' to get a working copy)
  
  ##### server goes to 1200 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 1)
           received 7 server heads, 3 cached, 10 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 270 changesets with 0 changes to 0 files
  new changesets e4b144f7c1f5:266b5ea5a79c
  (run 'hg update' to get a working copy)
  
  ##### server goes to 1230 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 1)
           received 1 server heads, 9 cached, 10 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 30 changesets with 0 changes to 0 files
  new changesets cad093e13ed4:ada45e7417b8
  (run 'hg update' to get a working copy)
  
  ##### server goes to 1500 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 1)
           received 12 server heads, 2 cached, 14 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 131 changesets with 0 changes to 0 files (+1 heads)
  new changesets 55441e24f33e:bc915268d551
  (run 'hg heads' to see heads, 'hg merge' to merge)
  
  ##### server goes to 2000 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 2)
           received 9 server heads, 8 cached, 17 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 307 changesets with 0 changes to 0 files
  new changesets 09e99e6a8d0b:22b8522d1e58
  (run 'hg update' to get a working copy)
  
  ##### server goes to 3315 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 2)
           received 23 server heads
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 643 changesets with 0 changes to 0 files (+1 heads)
  new changesets 2da5c5d08364:d58e47499b55
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### server goes to 4000 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 3)
           received 2 server heads, 22 cached, 24 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 620 changesets with 0 changes to 0 files
  new changesets e69fa130d956:fe8d4a6c9087
  (run 'hg update' to get a working copy)
  
  ##### server goes to 5000 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 3)
           received 3 server heads, 23 cached, 26 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 952 changesets with 0 changes to 0 files
  new changesets 23b0b7c9332a:993cd0837a5c
  (run 'hg update' to get a working copy)
  
  ##### server goes to 5210 changesets
  pulling from ssh://user@dummy/simple-partial-pull/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 3)
           received 1 server heads, 25 cached, 26 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 210 changesets with 0 changes to 0 files
  new changesets 74ba7dd140b5:518e7f4bc0ca
  (run 'hg update' to get a working copy)

final no-op pull

  $ hg -R client pull --rev tip --config devel.debug.discovery=yes
  pulling from ssh://user@dummy/simple-partial-pull/server
  no changes found

Exchange between non-converging repository
------------------------------------------

  $ cd $TESTTMP
  $ mkdir diverging-repo
  $ cd diverging-repo
  $ hg init server
  $ hg clone ssh://user@dummy/diverging-repo/server client
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cat ../pairs | while read -r left right; do
  >     echo
  >     echo "##### adding $left server side - $right client side"
  >     hg -R ../main-repo push --force --rev $left server --quiet
  >     hg -R ../main-repo push --force --rev $right client --quiet
  >     hg -R client debugdiscovery --config devel.debug.discovery=yes
  > done
  
  ##### adding Paaaaaaaa+Paaaaaaba+Paaaaabaa+Paaaaabba+Paaaabaaa+Paaaababa+Paaaabbaa+Paaaabbba+Paaabaaaa+Paaabaaba server side - Paaaaaaab+Paaaaaabb+Paaaaabab+Paaaaabbb+Paaaabaab+Paaaababb+Paaaabbab+Paaaabbbb+Paaabaaab+Paaabaabb client side
  comparing with ssh://user@dummy/diverging-repo/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 3)
           received 1 server heads
  searching for changes
  all remote heads known locally
  elapsed time:  *.?????? seconds (glob)
  round-trips:                   1
  queries:                       3
  heads summary:
    total common heads:          1
      also local heads:          0
      also remote heads:         1
      both:                      0
    local heads:                 3
      common:                    0
      missing:                   3
    remote heads:                1
      common:                    1
      unknown:                   0
  local changesets:            540
    common:                    375
      heads:                     1
      roots:                     1
    missing:                   165
      heads:                     3
      roots:                     5
    first undecided set:       165
      heads:                     3
      roots:                     5
      common:                    0
      missing:                 165
  
  ##### adding Paaababaa+Paaababba+Paaabbaaa+Paaabbaba+Paaabbbaa+Paaabbbba+Paabaaaaa+Paabaaaba+Paabaabaa+Paabaabba server side - Paaababab+Paaababbb+Paaabbaab+Paaabbabb+Paaabbbab+Paaabbbbb+Paabaaaab+Paabaaabb+Paabaabab+Paabaabbb client side
  comparing with ssh://user@dummy/diverging-repo/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 10)
           received 2 server heads
  searching for changes
  all remote heads known locally
  elapsed time:  *.?????? seconds (glob)
  round-trips:                   1
  queries:                      10
  heads summary:
    total common heads:          2
      also local heads:          0
      also remote heads:         2
      both:                      0
    local heads:                10
      common:                    0
      missing:                  10
    remote heads:                2
      common:                    2
      unknown:                   0
  local changesets:           1384
    common:                    960
      heads:                     2
      roots:                     1
    missing:                   424
      heads:                    10
      roots:                    12
    first undecided set:       424
      heads:                    10
      roots:                    12
      common:                    0
      missing:                 424
  
  ##### adding Paababaaa+Paabababa+Paababbaa+Paababbba+Paabbaaaa+Paabbaaba+Paabbabaa+Paabbabba+Paabbbaaa+Paabbbaba server side - Paababaab+Paabababb+Paababbab+Paababbbb+Paabbaaab+Paabbaabb+Paabbabab+Paabbabbb+Paabbbaab+Paabbbabb client side
  comparing with ssh://user@dummy/diverging-repo/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 16)
           received 5 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 560, sample size is: 200
  2 total queries in *.????s (glob)
  elapsed time:  *.?????? seconds (glob)
  round-trips:                   2
  queries:                     216
  heads summary:
    total common heads:          4
      also local heads:          4
      also remote heads:         0
      both:                      0
    local heads:                16
      common:                    4
      missing:                  12
    remote heads:                5
      common:                    0
      unknown:                   5
  local changesets:           1817
    common:                   1245
      heads:                     4
      roots:                     1
    missing:                   572
      heads:                    12
      roots:                    14
    first undecided set:      1813
      heads:                    16
      roots:                     1
      common:                 1241
      missing:                 572
  
  ##### adding Paabbbbaa+Paabbbbba+Pabaaaaaa+Pabaaaaba+Pabaaabaa+Pabaaabba+Pabaabaaa+Pabaababa+Pabaabbaa+Pabaabbba server side - Paabbbbab+Paabbbbbb+Pabaaaaab+Pabaaaabb+Pabaaabab+Pabaaabbb+Pabaabaab+Pabaababb+Pabaabbab+Pabaabbbb client side
  comparing with ssh://user@dummy/diverging-repo/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 19)
           received 7 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 588, sample size is: 200
  2 total queries in *.????s (glob)
  elapsed time:  *.?????? seconds (glob)
  round-trips:                   2
  queries:                     219
  heads summary:
    total common heads:          7
      also local heads:          4
      also remote heads:         3
      both:                      0
    local heads:                19
      common:                    4
      missing:                  15
    remote heads:                7
      common:                    3
      unknown:                   4
  local changesets:           2483
    common:                   1880
      heads:                     7
      roots:                     1
    missing:                   603
      heads:                    15
      roots:                    17
    first undecided set:      1147
      heads:                    19
      roots:                    22
      common:                  544
      missing:                 603
  
  ##### adding Pababaaaa+Pababaaba+Pabababaa+Pabababba+Pababbaaa+Pababbaba+Pababbbaa+Pababbbba+Pabbaaaaa+Pabbaaaba server side - Pababaaab+Pababaabb+Pabababab+Pabababbb+Pababbaab+Pababbabb+Pababbbab+Pababbbbb+Pabbaaaab+Pabbaaabb client side
  comparing with ssh://user@dummy/diverging-repo/server
  query 1; heads-fingerprints + initial-local-heads (sample size is 20)
           received 6 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 684, sample size is: 200
  2 total queries in *.????s (glob)
  elapsed time:  *.?????? seconds (glob)
  round-trips:                   2
  queries:                     220
  heads summary:
    total common heads:          5
      also local heads:          3
      also remote heads:         1
      both:                      0
    local heads:                20
      common:                    3
      missing:                  17
    remote heads:                6
      common:                    1
      unknown:                   5
  local changesets:           2898
    common:                   2227
      heads:                     5
      roots:                     1
    missing:                   671
      heads:                    17
      roots:                    19
    first undecided set:      1686
      heads:                    21
      roots:                    18
      common:                 1015
      missing:                 671

Talking to multiple server
--------------------------


  $ cd $TESTTMP
  $ mkdir multiple-servers
  $ cd multiple-servers
  $ hg init server-1
  $ hg init server-2
  $ hg init client
  $ cat >> client/.hg/hgrc << EOF
  > [paths]
  > server-1 = ssh://user@dummy/multiple-servers/server-1
  > server-2 = ssh://user@dummy/multiple-servers/server-2
  > EOF

  $ cat ../pairs | while read -r left right; do
  >     echo
  >     echo "##### adding $left on server-1 - $right on server-2"
  >     hg -R ../main-repo push --force server-1 --rev $left --quiet
  >     hg -R ../main-repo push --force server-2 --rev $right --quiet
  >     hg -R client pull server-1 --config devel.debug.discovery=yes
  >     hg -R client pull server-2 --config devel.debug.discovery=yes
  > done
  
  ##### adding Paaaaaaaa+Paaaaaaba+Paaaaabaa+Paaaaabba+Paaaabaaa+Paaaababa+Paaaabbaa+Paaaabbba+Paaabaaaa+Paaabaaba on server-1 - Paaaaaaab+Paaaaaabb+Paaaaabab+Paaaaabbb+Paaaabaab+Paaaababb+Paaaabbab+Paaaabbbb+Paaabaaab+Paaabaabb on server-2
  pulling from ssh://user@dummy/multiple-servers/server-1
  query 1; heads-fingerprints
           received 1 server heads
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 375 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:a7ca523f57f5
  (run 'hg update' to get a working copy)
  pulling from ssh://user@dummy/multiple-servers/server-2
  query 1; heads-fingerprints + initial-local-heads (sample size is 1)
           received 3 server heads
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 165 changesets with 0 changes to 0 files (+2 heads)
  new changesets 0d0ec4326451:f0ddb6fbbb1d
  (run 'hg heads' to see heads, 'hg merge' to merge)
  
  ##### adding Paaababaa+Paaababba+Paaabbaaa+Paaabbaba+Paaabbbaa+Paaabbbba+Paabaaaaa+Paabaaaba+Paabaabaa+Paabaabba on server-1 - Paaababab+Paaababbb+Paaabbaab+Paaabbabb+Paaabbbab+Paaabbbbb+Paabaaaab+Paabaaabb+Paabaabab+Paabaabbb on server-2
  pulling from ssh://user@dummy/multiple-servers/server-1
  query 1; heads-fingerprints + initial-local-heads (sample size is 3)
           received 2 server heads
  searching for changes
  taking quick initial sample
  query 2; still undecided: 537, sample size is: 54
  query 3; still undecided: 71, sample size is: 71
  3 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 585 changesets with 0 changes to 0 files (+2 heads)
  new changesets e4b144f7c1f5:0d623320dc9b
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  pulling from ssh://user@dummy/multiple-servers/server-2
  query 1; heads-fingerprints + initial-local-heads (sample size is 5)
           received 8 server heads, 2 cached, 10 total
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 259 changesets with 0 changes to 0 files (+5 heads)
  new changesets c362f1e51701:155f59ca84fd
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### adding Paababaaa+Paabababa+Paababbaa+Paababbba+Paabbaaaa+Paabbaaba+Paabbabaa+Paabbabba+Paabbbaaa+Paabbbaba on server-1 - Paababaab+Paabababb+Paababbab+Paababbbb+Paabbaaab+Paabbaabb+Paabbabab+Paabbabbb+Paabbbaab+Paabbbabb on server-2
  pulling from ssh://user@dummy/multiple-servers/server-1
  query 1; heads-fingerprints + initial-local-heads (sample size is 10)
           received 5 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 491, sample size is: 200
  query 3; still undecided: 26, sample size is: 26
  3 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 484 changesets with 0 changes to 0 files (+3 heads)
  new changesets 2da5c5d08364:dd416cf284bc
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  pulling from ssh://user@dummy/multiple-servers/server-2
  query 1; heads-fingerprints + initial-local-heads (sample size is 13)
           received 16 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 203, sample size is: 200
  2 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 157 changesets with 0 changes to 0 files (+4 heads)
  new changesets 0af0844ee22c:e9986b03a22a
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### adding Paabbbbaa+Paabbbbba+Pabaaaaaa+Pabaaaaba+Pabaaabaa+Pabaaabba+Pabaabaaa+Pabaababa+Pabaabbaa+Pabaabbba on server-1 - Paabbbbab+Paabbbbbb+Pabaaaaab+Pabaaaabb+Pabaaabab+Pabaaabbb+Pabaabaab+Pabaababb+Pabaabbab+Pabaabbbb on server-2
  pulling from ssh://user@dummy/multiple-servers/server-1
  query 1; heads-fingerprints + initial-local-heads (sample size is 17)
           received 7 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 450, sample size is: 200
  2 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 384 changesets with 0 changes to 0 files (-1 heads)
  new changesets 8dbce9ae65d2:dbe7d8ed8434
  (run 'hg update' to get a working copy)
  pulling from ssh://user@dummy/multiple-servers/server-2
  query 1; heads-fingerprints + initial-local-heads (sample size is 16)
           received 13 server heads, 6 cached, 19 total
  searching for changes
  taking initial sample
  query 2; still undecided: 66, sample size is: 66
  2 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 144 changesets with 0 changes to 0 files (+3 heads)
  new changesets c50da21912eb:d902bf76c24d
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  
  ##### adding Pababaaaa+Pababaaba+Pabababaa+Pabababba+Pababbaaa+Pababbaba+Pababbbaa+Pababbbba+Pabbaaaaa+Pabbaaaba on server-1 - Pababaaab+Pababaabb+Pabababab+Pabababbb+Pababbaab+Pababbabb+Pababbbab+Pababbbbb+Pabbaaaab+Pabbaaabb on server-2
  pulling from ssh://user@dummy/multiple-servers/server-1
  query 1; heads-fingerprints + initial-local-heads (sample size is 19)
           received 6 server heads
  searching for changes
  taking initial sample
  query 2; still undecided: 647, sample size is: 200
  query 3; still undecided: 11, sample size is: 11
  3 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 483 changesets with 0 changes to 0 files (+1 heads)
  new changesets 7500d37fcd60:fe1fc7aac4f5
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  pulling from ssh://user@dummy/multiple-servers/server-2
  query 1; heads-fingerprints + initial-local-heads (sample size is 20)
           received 14 server heads, 6 cached, 20 total
  searching for changes
  taking initial sample
  query 2; still undecided: 263, sample size is: 200
  2 total queries in *.????s (glob)
  adding changesets
  adding manifests
  adding file changes
  added 100 changesets with 0 changes to 0 files (+2 heads)
  new changesets 5c8eece2db7c:30aa3e66fabd
  (run 'hg heads .' to see heads, 'hg merge' to merge)
