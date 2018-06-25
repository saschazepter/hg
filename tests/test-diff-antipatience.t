#testcases bdiff xdiff

#if xdiff
#require xdiff
  $ cat >> $HGRCPATH <<EOF
  > [experimental]
  > xdiff = true
  > EOF
#endif

Test case that makes use of the weakness of patience diff algorithm

  $ hg init
  >>> open('a', 'wb').write(('\n'.join(list('a' + 'x' * 10 + 'u' + 'x' * 30 + 'a\n'))).encode('ascii')) and None
  $ hg commit -m 1 -A a
  >>> open('a', 'wb').write(('\n'.join(list('b' + 'x' * 30 + 'u' + 'x' * 10 + 'b\n'))).encode('ascii')) and None
#if xdiff
  $ hg diff
  diff -r f0aeecb49805 a
  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,4 +1,4 @@
  -a
  +b
   x
   x
   x
  @@ -9,7 +9,6 @@
   x
   x
   x
  -u
   x
   x
   x
  @@ -30,6 +29,7 @@
   x
   x
   x
  +u
   x
   x
   x
  @@ -40,5 +40,5 @@
   x
   x
   x
  -a
  +b
   
#else
  $ hg diff
  diff -r f0aeecb49805 a
  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,15 +1,4 @@
  -a
  -x
  -x
  -x
  -x
  -x
  -x
  -x
  -x
  -x
  -x
  -u
  +b
   x
   x
   x
  @@ -40,5 +29,16 @@
   x
   x
   x
  -a
  +u
  +x
  +x
  +x
  +x
  +x
  +x
  +x
  +x
  +x
  +x
  +b
   
#endif
