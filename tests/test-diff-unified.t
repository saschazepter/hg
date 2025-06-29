  $ hg init repo
  $ cd repo
  $ cat > a <<EOF
  > c
  > c
  > a
  > a
  > b
  > a
  > a
  > c
  > c
  > EOF
  $ hg ci -Am adda
  adding a

  $ cat > a <<EOF
  > c
  > c
  > a
  > a
  > dd
  > a
  > a
  > c
  > c
  > EOF

default context

  $ hg diff --nodates
  diff -r cf9f4ba66af2 a
  --- a/a
  +++ b/a
  @@ -2,7 +2,7 @@
   c
   a
   a
  -b
  +dd
   a
   a
   c

invalid --unified

  $ hg diff --nodates -U foo
  abort: diff context lines count must be an integer, not 'foo'
  [10]


  $ hg diff --nodates -U 2
  diff -r cf9f4ba66af2 a
  --- a/a
  +++ b/a
  @@ -3,5 +3,5 @@
   a
   a
  -b
  +dd
   a
   a

  $ hg --config diff.unified=2 diff --nodates
  diff -r cf9f4ba66af2 a
  --- a/a
  +++ b/a
  @@ -3,5 +3,5 @@
   a
   a
  -b
  +dd
   a
   a

  $ hg diff --nodates -U 1
  diff -r cf9f4ba66af2 a
  --- a/a
  +++ b/a
  @@ -4,3 +4,3 @@
   a
  -b
  +dd
   a

invalid diff.unified

  $ hg --config diff.unified=foo diff --nodates
  abort: diff context lines count must be an integer, not 'foo'
  [10]

noprefix config and option

  $ hg --config diff.noprefix=True diff --nodates
  diff -r cf9f4ba66af2 a
  --- a
  +++ a
  @@ -2,7 +2,7 @@
   c
   a
   a
  -b
  +dd
   a
   a
   c
  $ hg diff --noprefix --nodates
  diff -r cf9f4ba66af2 a
  --- a
  +++ a
  @@ -2,7 +2,7 @@
   c
   a
   a
  -b
  +dd
   a
   a
   c

noprefix config disabled in plain mode, but option still enabled

  $ HGPLAIN=1 hg --config diff.noprefix=True diff --nodates
  diff -r cf9f4ba66af2 a
  --- a/a
  +++ b/a
  @@ -2,7 +2,7 @@
   c
   a
   a
  -b
  +dd
   a
   a
   c
  $ HGPLAIN=1 hg diff --noprefix --nodates
  diff -r cf9f4ba66af2 a
  --- a
  +++ a
  @@ -2,7 +2,7 @@
   c
   a
   a
  -b
  +dd
   a
   a
   c

  $ cd ..


0 lines of context hunk header matches gnu diff hunk header

  $ hg init diffzero
  $ cd diffzero
  $ cat > f1 << EOF
  > c2
  > c4
  > c5
  > EOF
  $ hg commit -Am0
  adding f1

  $ cat > f2 << EOF
  > c1
  > c2
  > c3
  > c4
  > EOF
  $ mv f2 f1
  $ hg diff -U0 --nodates
  diff -r 55d8ff78db23 f1
  --- a/f1
  +++ b/f1
  @@ -0,0 +1,1 @@
  +c1
  @@ -1,0 +3,1 @@
  +c3
  @@ -3,1 +4,0 @@
  -c5

  $ hg diff -U0 --nodates --git
  diff --git a/f1 b/f1
  --- a/f1
  +++ b/f1
  @@ -0,0 +1,1 @@
  +c1
  @@ -1,0 +3,1 @@
  +c3
  @@ -3,1 +4,0 @@
  -c5

  $ hg diff -U0 --nodates -p
  diff -r 55d8ff78db23 f1
  --- a/f1
  +++ b/f1
  @@ -0,0 +1,1 @@
  +c1
  @@ -1,0 +3,1 @@ c2
  +c3
  @@ -3,1 +4,0 @@ c4
  -c5

  $ echo a > f1
  $ hg ci -m movef2

Test diff headers terminating with TAB when necessary (issue3357)
Regular diff --nodates, file creation

  $ hg mv f1 'f 1'
  $ echo b > 'f 1'
  $ hg diff --nodates 'f 1'
  diff -r 7574207d0d15 f 1
  --- /dev/null
  +++ b/f 1	
  @@ -0,0 +1,1 @@
  +b

Git diff, adding space

  $ hg diff --git
  diff --git a/f1 b/f 1
  rename from f1
  rename to f 1
  --- a/f1
  +++ b/f 1	
  @@ -1,1 +1,1 @@
  -a
  +b

Git diff, adding extended headers

  $ hg diff --git --config experimental.extendedheader.index=7 --config experimental.extendedheader.similarity=True
  diff --git a/f1 b/f 1
  similarity index 0%
  rename from f1
  rename to f 1
  index 7898192..6178079 100644
  --- a/f1
  +++ b/f 1	
  @@ -1,1 +1,1 @@
  -a
  +b

  $ hg diff --git --config experimental.extendedheader.index=-1
  invalid length for extendedheader.index: '-1'
  diff --git a/f1 b/f 1
  rename from f1
  rename to f 1
  --- a/f1
  +++ b/f 1	
  @@ -1,1 +1,1 @@
  -a
  +b

  $ hg diff --git --config experimental.extendedheader.index=whatever
  invalid value for extendedheader.index: 'whatever'
  diff --git a/f1 b/f 1
  rename from f1
  rename to f 1
  --- a/f1
  +++ b/f 1	
  @@ -1,1 +1,1 @@
  -a
  +b

Git diff with noprefix

  $ hg --config diff.noprefix=True diff --git --nodates
  diff --git f1 f 1
  rename from f1
  rename to f 1
  --- f1
  +++ f 1	
  @@ -1,1 +1,1 @@
  -a
  +b

noprefix config disabled in plain mode, but option still enabled

  $ HGPLAIN=1 hg --config diff.noprefix=True diff --git --nodates
  diff --git a/f1 b/f 1
  rename from f1
  rename to f 1
  --- a/f1
  +++ b/f 1	
  @@ -1,1 +1,1 @@
  -a
  +b
  $ HGPLAIN=1 hg diff --git --noprefix --nodates
  diff --git f1 f 1
  rename from f1
  rename to f 1
  --- f1
  +++ f 1	
  @@ -1,1 +1,1 @@
  -a
  +b

Regular diff --nodates, file deletion

  $ hg ci -m addspace
  $ hg mv 'f 1' f1
  $ echo a > f1
  $ hg diff --nodates 'f 1'
  diff -r ca50fe67c9c7 f 1
  --- a/f 1	
  +++ /dev/null
  @@ -1,1 +0,0 @@
  -b

Git diff, removing space

  $ hg diff --git
  diff --git a/f 1 b/f1
  rename from f 1
  rename to f1
  --- a/f 1	
  +++ b/f1
  @@ -1,1 +1,1 @@
  -b
  +a

showfunc diff
  $ cat > f1 << EOF
  > int main() {
  >     int a = 0;
  >     int b = 1;
  >     int c = 2;
  >     int d = 3;
  >     return a + b + c + d;
  > }
  > EOF
  $ hg commit -m addfunction
  $ cat > f1 << EOF
  > int main() {
  >     int a = 0;
  >     int b = 1;
  >     int c = 2;
  >     int e = 3;
  >     return a + b + c + e;
  > }
  > EOF
  $ hg diff --git
  diff --git a/f1 b/f1
  --- a/f1
  +++ b/f1
  @@ -2,6 +2,6 @@
       int a = 0;
       int b = 1;
       int c = 2;
  -    int d = 3;
  -    return a + b + c + d;
  +    int e = 3;
  +    return a + b + c + e;
   }
  $ hg diff --config diff.showfunc=True --git
  diff --git a/f1 b/f1
  --- a/f1
  +++ b/f1
  @@ -2,6 +2,6 @@ int main() {
       int a = 0;
       int b = 1;
       int c = 2;
  -    int d = 3;
  -    return a + b + c + d;
  +    int e = 3;
  +    return a + b + c + e;
   }

If [diff] git is set to true, but the user says --no-git, we should
*not* get git diffs
  $ hg diff --nodates --config diff.git=1 --no-git
  diff -r f2c7c817fa55 f1
  --- a/f1
  +++ b/f1
  @@ -2,6 +2,6 @@
       int a = 0;
       int b = 1;
       int c = 2;
  -    int d = 3;
  -    return a + b + c + d;
  +    int e = 3;
  +    return a + b + c + e;
   }

showfunc diff with underscore or dollar sign prefix (issue6965)
  $ cat > f1 << EOF
  > int
  > _rtld_main()
  > {
  >     int a = 0;
  >     int b = 1;
  >     int c = 2;
  >     int d = 3;
  >     return a + b + c + d;
  > }
  > 
  > \$vms_quirk()
  > {
  >     int a = 0;
  >     int b = 1;
  >     int c = 2;
  >     int d = 3;
  >     return a + b + c + d;
  > }
  > EOF
  $ hg commit -m "add function bsd style"
  $ cat > f1 << EOF
  > int
  > _rtld_main()
  > {
  >     int a = 0;
  >     int b = 1;
  >     int c = 2;
  >     int e = 3;
  >     return a + b + c + e;
  > }
  > 
  > \$vms_quirk()
  > {
  >     int a = 0;
  >     int b = 1;
  >     int c = 2;
  >     int e = 3;
  >     return a + b + c + e;
  > }
  > EOF
  $ hg diff --nodates --config diff.showfunc=True
  diff -r 21493d8e6bae f1
  --- a/f1
  +++ b/f1
  @@ -4,8 +4,8 @@ _rtld_main()
       int a = 0;
       int b = 1;
       int c = 2;
  -    int d = 3;
  -    return a + b + c + d;
  +    int e = 3;
  +    return a + b + c + e;
   }
   
   $vms_quirk()
  @@ -13,6 +13,6 @@ $vms_quirk()
       int a = 0;
       int b = 1;
       int c = 2;
  -    int d = 3;
  -    return a + b + c + d;
  +    int e = 3;
  +    return a + b + c + e;
   }

  $ cd ..

Long function names should be abbreviated, but multi-byte character shouldn't
be broken up

  $ hg init longfunc
  $ cd longfunc

  >>> with open('a', 'wb') as f:
  ...     f.write(b'a' * 39 + b'bb' + b'\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b' 0 b\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b'a' * 39 + b'\xc3\xa0' + b'\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b' 0 a with grave (single code point)\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b'a' * 39 + b'a\xcc\x80' + b'\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b' 0 a with grave (composition)\n') and None
  ...     f.write(b' .\n' * 3) and None
  $ hg ci -qAm0

  >>> with open('a', 'wb') as f:
  ...     f.write(b'a' * 39 + b'bb' + b'\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b' 1 b\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b'a' * 39 + b'\xc3\xa0' + b'\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b' 1 a with grave (single code point)\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b'a' * 39 + b'a\xcc\x80' + b'\n') and None
  ...     f.write(b' .\n' * 3) and None
  ...     f.write(b' 1 a with grave (composition)\n') and None
  ...     f.write(b' .\n' * 3) and None
  $ hg ci -m1

  $ hg diff -c1 --nodates --show-function
  diff -r 3e92dd6fa812 -r a256341606cb a
  --- a/a
  +++ b/a
  @@ -2,7 +2,7 @@ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab
    .
    .
    .
  - 0 b
  + 1 b
    .
    .
    .
  @@ -10,7 +10,7 @@ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xc3\xa0 (esc)
    .
    .
    .
  - 0 a with grave (single code point)
  + 1 a with grave (single code point)
    .
    .
    .
  @@ -18,7 +18,7 @@ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xcc\x80 (esc)
    .
    .
    .
  - 0 a with grave (composition)
  + 1 a with grave (composition)
    .
    .
    .

  $ cd ..

Make sure `hg diff --git` differentiate "file did not exists" and "file is empty"
for git blob oids

  $ hg init bloboids
  $ cd bloboids

  $ touch a
  $ hg ci -Am "empty a"
  adding a
  $ hg diff -c 0 --git --config experimental.extendedheader.index=full | grep index
  index 0000000000000000000000000000000000000000..e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 100644

Make sure `hg diff --git` differentiate "file was empty" and "file is removed"
for git blob oids

  $ rm a
  $ hg ci -Am "removed a"
  removing a
  $ hg diff -c 1 --git --config experimental.extendedheader.index=full | grep index
  index e69de29bb2d1d6434b8b29ae775ad8c2e48c5391..0000000000000000000000000000000000000000 100644

  $ cd ..
