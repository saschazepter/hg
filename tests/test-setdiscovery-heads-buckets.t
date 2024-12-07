==========================================
Testing of heads buckets helping discovery
==========================================

The heads buckets features group heads by bucket and associate a fingerprint to that bucket.

The goal is for a client to be able to cache the content of bucket and to reuse
it if the fingerprint is unchanged.

This test file check behavior related to this bucket computation.


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
   
