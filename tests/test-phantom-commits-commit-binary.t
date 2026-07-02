#require rust

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > phantom_commits=
  > 
  > [phantom_commits]
  > bookmark = phantom
  > ai-user = ai
  > EOF

Set up repo
-----------

  $ hg init repo1
  $ cd repo1
  $ hg bookmark b1
  $ cat << EOF > .hgignore
  > syntax: glob
  > *.ignore
  > EOF
  $ hg ci -qAm "add .hgignore"
  $ touch file
  $ hg commit -qAm "add file"
  $ echo A > file
  $ hg commit -m "A"
  $ echo B > file
  $ hg commit -m "B"
  $ echo C > file
  $ hg commit -m "C"

  $ hg log -T '{rev}: {desc}\n'
  4: C
  3: B
  2: A
  1: add file
  0: add .hgignore

Helpers
-------

Helper to reset state to make each test independent
  $ base=$(hg log -r . -T '{rev}')
  $ reset_to_base() {
  >   hg update --clean "$base" --quiet
  >   hg purge --no-confirm --all
  >   hg bookmark b1 --force --quiet
  >   hg bookmark --delete phantom 2>/dev/null || true
  > }

Helper to show all changeset(s) created, in the order they were committed
  $ show_commits() {
  >   hg export -r "$base::. - $base" --git -T '({index+1}) {node|short} by {user}: {desc}\n{indent(diff, "    ")}'
  > }

Test changing binary files
--------------------------

This section tests that the extension does not attempt to do line-level
attribution on binary files. Instead, all changes are attributed to the last
user who changed the file.

Create and change a binary file: human first, AI second
  >>> open("binary", "wb").write(b"human\x00\n")
  7
  $ hg create-phantom-commit -q --message change
  >>> open("binary", "ab").write(b"ai\x00\n")
  4
  $ hg create-phantom-commit -q --ai --message change
Make a human phantom commit to a different file, to demonstrate that we're not
just attributing the binary change to the last phantom commit
  $ echo change > file
  $ hg create-phantom-commit -q --message change
  $ hg commit -qAm "commit"
AI changed it last, so only the AI commit involves the binary file
  $ show_commits
  (1) 48c319dd937a by ai: commit (AI)
      diff --git a/binary b/binary
      new file mode 100644
      index 0000000000000000000000000000000000000000..d3bd4cb98a5064324cbccd758d125a2319e0bb71
      GIT binary patch
      literal 11
      Sc$~{9%}vZ>;7ZJ7-~s>@?*jM$
  
  (2) 3bf565250157 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change
  $ reset_to_base

Create and change a binary file: AI first, human second
  >>> open("binary", "wb").write(b"ai\x00\n")
  4
  $ hg create-phantom-commit -q --ai --message change
  >>> open("binary", "ab").write(b"human\x00\n")
  7
  $ hg create-phantom-commit -q --user human --message change
Make an AI phantom commit to a different file, to demonstrate that we're not
just attributing the binary change to the last phantom commit
  $ echo change > file
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qAm "commit"
Human changed it last, so only the human commit involves the binary file
  $ show_commits
  (1) 7ec1f9ce6c2b by ai: commit (AI)
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change
  (2) dbf74dbee910 by test: commit
      diff --git a/binary b/binary
      new file mode 100644
      index 0000000000000000000000000000000000000000..8ac8fdae3e7374c4268d1e1038951d3e1ae34d34
      GIT binary patch
      literal 11
      Sc$`bjWZ=pu%}vZ>-~s>>F9P@g
  
  $ reset_to_base

Test text -> binary
-------------------

This section tests phantom commit histories involving a change from text to
binary. Like in the binary -> binary case, all changes are attributed to the
last user who changed the file.

Change a file from text to binary: human first, AI second
  $ echo human >> file
  $ hg create-phantom-commit -q --message change
  >>> open("file", "ab").write(b"ai\x00\n")
  4
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qm "commit"
It's binary at the end, and AI changed it last, so only the AI commit involves
the file
  $ show_commits
  (1) 62cc32e57cfb by ai: commit (AI)
      diff --git a/file b/file
      index 3cc58df83752123644fef39faab2393af643b1d2..6528a01515b91a6a336737fa582b58bb6aa831b1
      GIT binary patch
      literal 12
      Tc${<Q$|%iE%;QSTWZ(h-7ij}U
  
  $ reset_to_base

Change a file from text to binary: AI first, human second
  $ echo ai >> file
  $ hg create-phantom-commit -q --ai --message change
  >>> open("file", "ab").write(b"human\x00\n")
  7
  $ hg create-phantom-commit -q --message change
  $ hg commit -qm "commit"
It's binary at the end, and human changed it last, so only the human commit
involves the file (in fact, there is no need for an AI commit at all)
  $ show_commits
  (1) 05515fa08859 by test: commit
      diff --git a/file b/file
      index 3cc58df83752123644fef39faab2393af643b1d2..601fa74ca2dcb5d7df9ffff2802e8a2ccadb4cc4
      GIT binary patch
      literal 12
      Tc${<QO3dWSD9ugGW8eY+75D>1
  
  $ reset_to_base

Test binary -> text
-------------------

This section tests phantom commit histories involving a change from binary to
text. All changes up to and including the text transition are attributed to the
user who made the transition, and changes after that are attributed as usual.

Change a file from binary to text: human first, AI second
  >>> open("newfile", "ab").write(b"\x00\n")
  2
  $ hg commit -Am "add binary file"
  adding newfile
  created new head
  $ echo human > newfile
  $ hg create-phantom-commit -q --message change
  $ echo ai >> newfile
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qm "commit"
It's just like a normal human + AI change, except it also changes to text, so
the squashed AI commit does that change (since it comes first)
  $ show_commits
  (1) 4e1a436bfbbf by test: add binary file
      diff --git a/newfile b/newfile
      new file mode 100644
      index 0000000000000000000000000000000000000000..1f2a4f5ef3df7f7456d91c961da36fc58904f2f1
      GIT binary patch
      literal 2
      Jc${P40ssIE01E&B
  
  (2) 09a4e6b98f9d by ai: commit (AI)
      diff --git a/newfile b/newfile
      index 1f2a4f5ef3df7f7456d91c961da36fc58904f2f1..f303d0919d067c69137a2fe2a5e418468fec1723
      GIT binary patch
      literal 3
      Kc$`bj<N^Q!0sz$j
  
  (3) 5bcf33c21e6d by test: commit
      diff --git a/newfile b/newfile
      --- a/newfile
      +++ b/newfile
      @@ -1,1 +1,2 @@
      +human
       ai
  $ reset_to_base

Change a file from binary to text: AI first, human second
  >>> open("newfile", "ab").write(b"\x00\n")
  2
  $ hg commit -Am "add binary file"
  adding newfile
  warning: commit already existed in the repository!
  $ echo ai > newfile
  $ hg create-phantom-commit -q --ai --message change
  $ echo human >> newfile
  $ hg create-phantom-commit -q --message change
  $ hg commit -qm "commit"
It's just like a normal AI + human change, except it also changes to text, so
squashed AI commit does that change (since it comes first)
  $ show_commits
  (1) 4e1a436bfbbf by test: add binary file
      diff --git a/newfile b/newfile
      new file mode 100644
      index 0000000000000000000000000000000000000000..1f2a4f5ef3df7f7456d91c961da36fc58904f2f1
      GIT binary patch
      literal 2
      Jc${P40ssIE01E&B
  
  (2) f35f16453291 by ai: commit (AI)
      diff --git a/newfile b/newfile
      index 1f2a4f5ef3df7f7456d91c961da36fc58904f2f1..f303d0919d067c69137a2fe2a5e418468fec1723
      GIT binary patch
      literal 3
      Kc$`bj<N^Q!0sz$j
  
  (3) f1ccabafc376 by test: commit
      diff --git a/newfile b/newfile
      --- a/newfile
      +++ b/newfile
      @@ -1,1 +1,2 @@
       ai
      +human
  $ reset_to_base
