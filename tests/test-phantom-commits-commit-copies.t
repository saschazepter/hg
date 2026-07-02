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

Test overall renames
--------------------

This section tests that augmented commit respects `hg mv`. It does not test
tracking of attribution through renames within the sequence of phantom commits.
(TODO: add a section testing that)

AI renames a file
  $ hg mv file renamed
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qm "rename"
  $ show_commits
  (1) 3188a43b26e6 by ai: rename (AI)
      diff --git a/file b/renamed
      rename from file
      rename to renamed
  $ reset_to_base

Human renames a file (not in phantom commit)
  $ touch ai-file # to avoid falling back to regular commit
  $ hg add ai-file
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ hg mv file renamed
  $ hg commit -qm "rename"
  $ show_commits
  (1) 8d4e922e6dac by ai: rename (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) 5dcf397304f9 by test: rename
      diff --git a/file b/renamed
      rename from file
      rename to renamed
  $ reset_to_base

Human renames a file (in phantom commit)
  $ hg mv file renamed
  $ hg create-phantom-commit -q --message change
  $ touch ai-file # to avoid falling back to regular commit
  $ hg add ai-file
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ hg commit -qm "rename"
  $ show_commits
  (1) 158831e1bb74 by ai: rename (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) c211b13a75f8 by test: rename
      diff --git a/file b/renamed
      rename from file
      rename to renamed
  $ reset_to_base

AI renames a file, then human changes it (not in phantom commit)
  $ hg mv file renamed
  $ hg create-phantom-commit -q --ai --message change
  $ echo human >> renamed
  $ hg commit -qm "rename"
  $ show_commits
  (1) 3188a43b26e6 by ai: rename (AI)
      diff --git a/file b/renamed
      rename from file
      rename to renamed
  (2) 29651a0730ba by test: rename
      diff --git a/renamed b/renamed
      --- a/renamed
      +++ b/renamed
      @@ -1,1 +1,2 @@
       C
      +human
  $ reset_to_base

AI renames a file, then human changes it (in phantom commit)
  $ hg mv file renamed
  $ hg create-phantom-commit -q --ai --message change
  $ echo human >> renamed
  $ hg create-phantom-commit -q --message change
  $ hg commit -qm "rename"
  $ show_commits
  (1) 8266912306b8 by ai: rename (AI)
      diff --git a/file b/renamed
      rename from file
      rename to renamed
  (2) e903d2c4c18b by test: rename
      diff --git a/renamed b/renamed
      --- a/renamed
      +++ b/renamed
      @@ -1,1 +1,2 @@
       C
      +human
  $ reset_to_base

Human renames a file, then AI changes it
This becomes copy + delete because the new file must go in the AI commit to
reflect the AI changes, but the delete can stay in the human commit.
  $ hg mv file renamed
  $ hg create-phantom-commit -q --message change
  $ echo ai >> renamed
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qm "rename"
  $ show_commits
  (1) c7752755856d by ai: rename (AI)
      diff --git a/file b/renamed
      copy from file
      copy to renamed
      --- a/file
      +++ b/renamed
      @@ -1,1 +1,2 @@
       C
      +ai
  (2) 7dad2a68a8f6 by test: rename
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

Test overall copies
-------------------

This section tests that augmented commit respects `hg cp`. It does not test
tracking of attribution through copies within the sequence of phantom commits.
(TODO: add a section testing that)

AI copies a file
  $ hg cp file copied
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qm "copy"
  $ show_commits
  (1) 6d9a37500aee by ai: copy (AI)
      diff --git a/file b/copied
      copy from file
      copy to copied
  $ reset_to_base

Human copies a file (not in phantom commit)
  $ touch ai-file # to avoid falling back to regular commit
  $ hg add ai-file
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ hg cp file copied
  $ hg commit -qm "copy"
  $ show_commits
  (1) bb5460452def by ai: copy (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) f6b4283c6707 by test: copy
      diff --git a/file b/copied
      copy from file
      copy to copied
  $ reset_to_base

Human copies a file (in phantom commit)
  $ hg cp file copied
  $ hg create-phantom-commit -q --message change
  $ touch ai-file # to avoid falling back to regular commit
  $ hg add ai-file
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ hg commit -qm "copy"
  $ show_commits
  (1) eb77b9abf5c7 by ai: copy (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) ba77459eba2b by test: copy
      diff --git a/file b/copied
      copy from file
      copy to copied
  $ reset_to_base

AI copies a file, then human changes it (not in phantom commit)
  $ hg cp file copied
  $ hg create-phantom-commit -q --ai --message change
  $ echo human >> copied
  $ hg commit -qm "copy"
  $ show_commits
  (1) 6d9a37500aee by ai: copy (AI)
      diff --git a/file b/copied
      copy from file
      copy to copied
  (2) fed01017f7d8 by test: copy
      diff --git a/copied b/copied
      --- a/copied
      +++ b/copied
      @@ -1,1 +1,2 @@
       C
      +human
  $ reset_to_base

AI copies a file, then human changes it (in phantom commit)
  $ hg cp file copied
  $ hg create-phantom-commit -q --ai --message change
  $ echo human >> copied
  $ hg create-phantom-commit -q --message change
  $ hg commit -qm "copy"
  $ show_commits
  (1) 767acbd665a1 by ai: copy (AI)
      diff --git a/file b/copied
      copy from file
      copy to copied
  (2) 0f00403d85d8 by test: copy
      diff --git a/copied b/copied
      --- a/copied
      +++ b/copied
      @@ -1,1 +1,2 @@
       C
      +human
  $ reset_to_base

Human copies a file, then AI changes it
  $ hg cp file copied
  $ hg create-phantom-commit -q --message change
  $ echo ai >> copied
  $ hg create-phantom-commit -q --ai --message change
  $ hg commit -qm "copy"
  $ show_commits
  (1) c885bd394adf by ai: copy (AI)
      diff --git a/file b/copied
      copy from file
      copy to copied
      --- a/file
      +++ b/copied
      @@ -1,1 +1,2 @@
       C
      +ai
  $ reset_to_base

Test split rename
-----------------

This section tests the case where the addition and removal parts of a rename are
split across phantom commits.

Human adds the new file, AI removes the old one
  $ touch renamed
  $ hg create-phantom-commit -q --message change
  $ rm file
  $ hg create-phantom-commit -q --ai --message change
  $ hg mv -A file renamed
  $ hg commit -qm "rename"
  $ show_commits
  (1) 82a60d764fa0 by test: rename
      diff --git a/file b/renamed
      rename from file
      rename to renamed
      --- a/file
      +++ b/renamed
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

AI adds the new file, human removes the old one (not in phantom commit)
This becomes AI copy + human remove, as expected.
  $ touch renamed
  $ hg create-phantom-commit -q --ai --message change
  $ hg rm file
  $ hg mv -A file renamed
  $ hg commit -qm "rename"
  $ show_commits
  (1) 35050fc6c041 by ai: rename (AI)
      diff --git a/file b/renamed
      copy from file
      copy to renamed
      --- a/file
      +++ b/renamed
      @@ -1,1 +0,0 @@
      -C
  (2) 19bb5149b8fd by test: rename
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

AI adds the new file, human removes the old one (in phantom commit)
This becomes AI copy + human remove, as expected.
  $ touch renamed
  $ hg create-phantom-commit -q --ai --message change
  $ hg rm file
  $ hg mv -A file renamed
  $ hg create-phantom-commit -q --message change
  $ hg commit -qm "rename"
  $ show_commits
  (1) aad8c552c7f4 by ai: rename (AI)
      diff --git a/file b/renamed
      copy from file
      copy to renamed
      --- a/file
      +++ b/renamed
      @@ -1,1 +0,0 @@
      -C
  (2) 9f7d3cacb2fa by test: rename
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

Test rename back and forth
--------------------------

This section tests renaming a file, then undoing the rename, then redoing it,
recording phantom commits at each step.

  $ hg mv file renamed
  $ hg create-phantom-commit -q --message change
  $ hg mv renamed file
  $ touch ai-file # to avoid skipping the AI commit
  $ hg add ai-file
  $ hg create-phantom-commit -q --ai --message change
  $ hg mv file renamed
  $ hg commit -qm "change"
  $ show_commits
  (1) d366195e360c by ai: change (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) ca9935730ab6 by test: change
      diff --git a/file b/renamed
      rename from file
      rename to renamed
  $ reset_to_base
