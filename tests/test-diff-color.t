Setup

  $ cat <<EOF >> $HGRCPATH
  > [ui]
  > color = yes
  > formatted = always
  > paginate = never
  > [color]
  > mode = ansi
  > EOF
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
  \x1b[0;32madding a\x1b[0m (esc)
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
  \x1b[0;1mdiff -r cf9f4ba66af2 a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -2,7 +2,7 @@\x1b[0m (esc)
   c
   a
   a
  \x1b[0;31m-b\x1b[0m (esc)
  \x1b[0;32m+dd\x1b[0m (esc)
   a
   a
   c

trailing whitespace

  $ cp a a.orig
  >>> with open('a', 'rb') as f:
  ...     data = f.read()
  >>> with open('a', 'wb') as f:
  ...     f.write(data.replace(b'dd', b'dd \r')) and None
  $ hg diff --nodates
  \x1b[0;1mdiff -r cf9f4ba66af2 a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -2,7 +2,7 @@\x1b[0m (esc)
   c
   a
   a
  \x1b[0;31m-b\x1b[0m (esc)
  \x1b[0;32m+dd\x1b[0m\x1b[0;1;41m \x1b[0m\r (esc)
   a
   a
   c

  $ mv a.orig a

(check that 'ui.color=yes' match '--color=auto')

  $ hg diff --nodates --config ui.formatted=no
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

(check that 'ui.color=no' disable color)

  $ hg diff --nodates --config ui.formatted=yes --config ui.color=no
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

(check that 'ui.color=always' force color)

  $ hg diff --nodates --config ui.formatted=no --config ui.color=always
  \x1b[0;1mdiff -r cf9f4ba66af2 a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -2,7 +2,7 @@\x1b[0m (esc)
   c
   a
   a
  \x1b[0;31m-b\x1b[0m (esc)
  \x1b[0;32m+dd\x1b[0m (esc)
   a
   a
   c

--unified=2

  $ hg diff --nodates -U 2
  \x1b[0;1mdiff -r cf9f4ba66af2 a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -3,5 +3,5 @@\x1b[0m (esc)
   a
   a
  \x1b[0;31m-b\x1b[0m (esc)
  \x1b[0;32m+dd\x1b[0m (esc)
   a
   a

diffstat

  $ hg diff --stat
   a |  2 \x1b[0;32m+\x1b[0m\x1b[0;31m-\x1b[0m (esc)
   1 files changed, 1 insertions(+), 1 deletions(-)
  $ cat <<EOF >> $HGRCPATH
  > [extensions]
  > record =
  > [ui]
  > interactive = true
  > [diff]
  > git = True
  > EOF

#if execbit

record

  $ chmod +x a
  $ hg record -m moda a <<EOF
  > y
  > EOF
  \x1b[0;1mdiff --git a/a b/a\x1b[0m (esc)
  \x1b[0;36;1mold mode 100644\x1b[0m (esc)
  \x1b[0;36;1mnew mode 100755\x1b[0m (esc)
  1 hunks, 1 lines changed
  \x1b[0;35m@@ -2,7 +2,7 @@ c\x1b[0m (esc)
   c
   a
   a
  \x1b[0;31m-b\x1b[0m (esc)
  \x1b[0;32m+dd\x1b[0m (esc)
   a
   a
   c
  \x1b[0;33mrecord this change to 'a'?\x1b[0m (esc)
  \x1b[0;33m(enter ? for help) [Ynesfdaq?]\x1b[0m y (esc)
  

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "mq=" >> $HGRCPATH
  $ hg rollback
  repository tip rolled back to revision 0 (undo commit)
  working directory now based on revision 0

qrecord

  $ hg qrecord -m moda patch <<EOF
  > y
  > y
  > EOF
  \x1b[0;1mdiff --git a/a b/a\x1b[0m (esc)
  \x1b[0;36;1mold mode 100644\x1b[0m (esc)
  \x1b[0;36;1mnew mode 100755\x1b[0m (esc)
  1 hunks, 1 lines changed
  \x1b[0;33mexamine changes to 'a'?\x1b[0m (esc)
  \x1b[0;33m(enter ? for help) [Ynesfdaq?]\x1b[0m y (esc)
  
  \x1b[0;35m@@ -2,7 +2,7 @@ c\x1b[0m (esc)
   c
   a
   a
  \x1b[0;31m-b\x1b[0m (esc)
  \x1b[0;32m+dd\x1b[0m (esc)
   a
   a
   c
  \x1b[0;33mrecord this change to 'a'?\x1b[0m (esc)
  \x1b[0;33m(enter ? for help) [Ynesfdaq?]\x1b[0m y (esc)
  

  $ hg qpop -a
  popping patch
  patch queue now empty

#endif

issue3712: test colorization of subrepo diff

  $ hg init sub
  $ echo b > sub/b
  $ hg -R sub commit -Am 'create sub'
  \x1b[0;32madding b\x1b[0m (esc)
  $ echo 'sub = sub' > .hgsub
  $ hg add .hgsub
  $ hg commit -m 'add subrepo sub'
  $ echo aa >> a
  $ echo bb >> sub/b

  $ hg diff -S
  \x1b[0;1mdiff --git a/a b/a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -7,3 +7,4 @@\x1b[0m (esc)
   a
   c
   c
  \x1b[0;32m+aa\x1b[0m (esc)
  \x1b[0;1mdiff --git a/sub/b b/sub/b\x1b[0m (esc)
  \x1b[0;31;1m--- a/sub/b\x1b[0m (esc)
  \x1b[0;32;1m+++ b/sub/b\x1b[0m (esc)
  \x1b[0;35m@@ -1,1 +1,2 @@\x1b[0m (esc)
   b
  \x1b[0;32m+bb\x1b[0m (esc)

test tabs

  $ cat >> a <<EOF
  > 	one tab
  > 		two tabs
  > end tab	
  > mid	tab
  > 	all		tabs	
  > EOF
  $ hg diff --nodates
  \x1b[0;1mdiff --git a/a b/a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -7,3 +7,9 @@\x1b[0m (esc)
   a
   c
   c
  \x1b[0;32m+aa\x1b[0m (esc)
  \x1b[0;32m+\x1b[0m	\x1b[0;32mone tab\x1b[0m (esc)
  \x1b[0;32m+\x1b[0m		\x1b[0;32mtwo tabs\x1b[0m (esc)
  \x1b[0;32m+end tab\x1b[0m\x1b[0;1;41m	\x1b[0m (esc)
  \x1b[0;32m+mid\x1b[0m	\x1b[0;32mtab\x1b[0m (esc)
  \x1b[0;32m+\x1b[0m	\x1b[0;32mall\x1b[0m		\x1b[0;32mtabs\x1b[0m\x1b[0;1;41m	\x1b[0m (esc)
  $ echo "[color]" >> $HGRCPATH
  $ echo "diff.tab = bold magenta" >> $HGRCPATH
  $ hg diff --nodates
  \x1b[0;1mdiff --git a/a b/a\x1b[0m (esc)
  \x1b[0;31;1m--- a/a\x1b[0m (esc)
  \x1b[0;32;1m+++ b/a\x1b[0m (esc)
  \x1b[0;35m@@ -7,3 +7,9 @@\x1b[0m (esc)
   a
   c
   c
  \x1b[0;32m+aa\x1b[0m (esc)
  \x1b[0;32m+\x1b[0m\x1b[0;1;35m	\x1b[0m\x1b[0;32mone tab\x1b[0m (esc)
  \x1b[0;32m+\x1b[0m\x1b[0;1;35m		\x1b[0m\x1b[0;32mtwo tabs\x1b[0m (esc)
  \x1b[0;32m+end tab\x1b[0m\x1b[0;1;41m	\x1b[0m (esc)
  \x1b[0;32m+mid\x1b[0m\x1b[0;1;35m	\x1b[0m\x1b[0;32mtab\x1b[0m (esc)
  \x1b[0;32m+\x1b[0m\x1b[0;1;35m	\x1b[0m\x1b[0;32mall\x1b[0m\x1b[0;1;35m		\x1b[0m\x1b[0;32mtabs\x1b[0m\x1b[0;1;41m	\x1b[0m (esc)

  $ cd ..

test inline color diff

  $ hg init inline
  $ cd inline
  $ cat > file1 << EOF
  > this is the first line
  > this is the second line
  >     third line starts with space
  > + starts with a plus sign
  > 	this one with one tab
  > 		now with full two tabs
  > 	now tabs		everywhere, much fun
  > 
  > this line won't change
  > 
  > two lines are going to
  > be changed into three!
  > 
  > three of those lines will
  > collapse onto one
  > (to see if it works)
  > EOF
  $ hg add file1
  $ hg ci -m 'commit'

  $ cat > file1 << EOF
  > that is the first paragraph
  >     this is the second line
  > third line starts with space
  > - starts with a minus sign
  > 	this one with two tab
  > 			now with full three tabs
  > 	now there are tabs		everywhere, much fun
  > 
  > this line won't change
  > 
  > two lines are going to
  > (entirely magically,
  >  assuming this works)
  > be changed into four!
  > 
  > three of those lines have
  > collapsed onto one
  > EOF
  $ hg diff --config diff.word-diff=False --color=debug
  [diff.diffline|diff --git a/file1 b/file1]
  [diff.file_a|--- a/file1]
  [diff.file_b|+++ b/file1]
  [diff.hunk|@@ -1,16 +1,17 @@]
  [diff.deleted|-this is the first line]
  [diff.deleted|-this is the second line]
  [diff.deleted|-    third line starts with space]
  [diff.deleted|-+ starts with a plus sign]
  [diff.deleted|-][diff.tab|	][diff.deleted|this one with one tab]
  [diff.deleted|-][diff.tab|		][diff.deleted|now with full two tabs]
  [diff.deleted|-][diff.tab|	][diff.deleted|now tabs][diff.tab|		][diff.deleted|everywhere, much fun]
  [diff.inserted|+that is the first paragraph]
  [diff.inserted|+    this is the second line]
  [diff.inserted|+third line starts with space]
  [diff.inserted|+- starts with a minus sign]
  [diff.inserted|+][diff.tab|	][diff.inserted|this one with two tab]
  [diff.inserted|+][diff.tab|			][diff.inserted|now with full three tabs]
  [diff.inserted|+][diff.tab|	][diff.inserted|now there are tabs][diff.tab|		][diff.inserted|everywhere, much fun]
   
   this line won't change
   
   two lines are going to
  [diff.deleted|-be changed into three!]
  [diff.inserted|+(entirely magically,]
  [diff.inserted|+ assuming this works)]
  [diff.inserted|+be changed into four!]
   
  [diff.deleted|-three of those lines will]
  [diff.deleted|-collapse onto one]
  [diff.deleted|-(to see if it works)]
  [diff.inserted|+three of those lines have]
  [diff.inserted|+collapsed onto one]
  $ hg diff --config diff.word-diff=True --color=debug
  [diff.diffline|diff --git a/file1 b/file1]
  [diff.file_a|--- a/file1]
  [diff.file_b|+++ b/file1]
  [diff.hunk|@@ -1,16 +1,17 @@]
  [diff.deleted|-][diff.deleted.changed|this][diff.deleted.unchanged| is the first ][diff.deleted.changed|line]
  [diff.deleted|-][diff.deleted.unchanged|this is the second line]
  [diff.deleted|-][diff.deleted.changed|    ][diff.deleted.unchanged|third line starts with space]
  [diff.deleted|-][diff.deleted.changed|+][diff.deleted.unchanged| starts with a ][diff.deleted.changed|plus][diff.deleted.unchanged| sign]
  [diff.deleted|-][diff.tab|	][diff.deleted.unchanged|this one with ][diff.deleted.changed|one][diff.deleted.unchanged| tab]
  [diff.deleted|-][diff.tab|		][diff.deleted.unchanged|now with full ][diff.deleted.changed|two][diff.deleted.unchanged| tabs]
  [diff.deleted|-][diff.tab|	][diff.deleted.unchanged|now ][diff.deleted.unchanged|tabs][diff.tab|		][diff.deleted.unchanged|everywhere, much fun]
  [diff.inserted|+][diff.inserted.changed|that][diff.inserted.unchanged| is the first ][diff.inserted.changed|paragraph]
  [diff.inserted|+][diff.inserted.changed|    ][diff.inserted.unchanged|this is the second line]
  [diff.inserted|+][diff.inserted.unchanged|third line starts with space]
  [diff.inserted|+][diff.inserted.changed|-][diff.inserted.unchanged| starts with a ][diff.inserted.changed|minus][diff.inserted.unchanged| sign]
  [diff.inserted|+][diff.tab|	][diff.inserted.unchanged|this one with ][diff.inserted.changed|two][diff.inserted.unchanged| tab]
  [diff.inserted|+][diff.tab|			][diff.inserted.unchanged|now with full ][diff.inserted.changed|three][diff.inserted.unchanged| tabs]
  [diff.inserted|+][diff.tab|	][diff.inserted.unchanged|now ][diff.inserted.changed|there are ][diff.inserted.unchanged|tabs][diff.tab|		][diff.inserted.unchanged|everywhere, much fun]
   
   this line won't change
   
   two lines are going to
  [diff.deleted|-][diff.deleted.unchanged|be changed into ][diff.deleted.changed|three][diff.deleted.unchanged|!]
  [diff.inserted|+][diff.inserted.changed|(entirely magically,]
  [diff.inserted|+][diff.inserted.changed| assuming this works)]
  [diff.inserted|+][diff.inserted.unchanged|be changed into ][diff.inserted.changed|four][diff.inserted.unchanged|!]
   
  [diff.deleted|-][diff.deleted.unchanged|three of those lines ][diff.deleted.changed|will]
  [diff.deleted|-][diff.deleted.changed|collapse][diff.deleted.unchanged| onto one]
  [diff.deleted|-][diff.deleted.changed|(to see if it works)]
  [diff.inserted|+][diff.inserted.unchanged|three of those lines ][diff.inserted.changed|have]
  [diff.inserted|+][diff.inserted.changed|collapsed][diff.inserted.unchanged| onto one]

multibyte character shouldn't be broken up in word diff:

  $ "$PYTHON" <<'EOF'
  > with open("utf8", "wb") as f:
  >     f.write(b"blah \xe3\x82\xa2 blah\n")
  > EOF
  $ hg ci -Am 'add utf8 char' utf8
  $ "$PYTHON" <<'EOF'
  > with open("utf8", "wb") as f:
  >     f.write(b"blah \xe3\x82\xa4 blah\n")
  > EOF
  $ hg ci -m 'slightly change utf8 char' utf8

  $ hg diff --config diff.word-diff=True --color=debug -c.
  [diff.diffline|diff --git a/utf8 b/utf8]
  [diff.file_a|--- a/utf8]
  [diff.file_b|+++ b/utf8]
  [diff.hunk|@@ -1,1 +1,1 @@]
  [diff.deleted|-][diff.deleted.unchanged|blah ][diff.deleted.changed|\xe3\x82\xa2][diff.deleted.unchanged| blah] (esc)
  [diff.inserted|+][diff.inserted.unchanged|blah ][diff.inserted.changed|\xe3\x82\xa4][diff.inserted.unchanged| blah] (esc)
