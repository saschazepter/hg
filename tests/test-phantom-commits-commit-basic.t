#require rust

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > phantom_commits=
  > EOF

Set up repo
-----------

  $ hg init repo1
  $ cd repo1
  $ cat << EOF > .hgignore
  > syntax: glob
  > *.ignore
  > EOF
  $ hg ci -qAm "add .hgignore"

(Unlike the other test-phantom-commits-*.t files, we do the rest of the repo
setup during the "Test commit fallback" section.)

Test commit fallback
--------------------

This section tests that `hg commit` falls back to doing a normal commit if any
of the extension's conditions are not met.

Must configure the bookmark name
  $ touch file
  $ hg commit -Am "add file" --verbose | grep phantom
  phantom commits: falling back to normal commit: missing config phantom_commits.bookmark
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > bookmark = phantom
  > EOF

Must configure the ai-user
  $ echo A > file
  $ hg commit -m "A" --verbose | grep phantom
  phantom commits: falling back to normal commit: missing config phantom_commits.ai-user
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > ai-user = ai
  > EOF

A bookmark must be active
  $ echo B > file
  $ hg commit -m "B" --verbose | grep phantom
  phantom commits: falling back to normal commit: no bookmark is active
  $ hg bookmark b1

Phantom bookmark must be set (by create-phantom-commit)
  $ echo C > file
  $ hg commit -m "C" --verbose | grep phantom
  phantom commits: falling back to normal commit: phantom bookmark 'phantom' is not set

Confirm the commits worked
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

Test simple cases
-----------------

This section tests simple cases of augmented commit, where `hg commit` is
overridden by the extension to create an extra changeset for AI attribution.

Single change by human
  $ echo change-human > file
  $ hg create-phantom-commit -q --message "change"
  $ hg ci -m "commit" --verbose | grep phantom
  phantom commits: falling back to normal commit: no phantom commits by AI
  $ show_commits
  (1) df6c8da85993 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-human
  $ reset_to_base

Single change by AI
  $ echo change-ai > file
  $ hg create-phantom-commit -q --ai --message "change"
  $ hg ci -m "commit"
  preparing squashed ai commit
  squashed ai commit: 1c45c1d0d4156a9d7b7654b511049b58d75a51e4
  skipping human commit since there are no changes
  deleting bookmark 'phantom'
  created new head
  $ show_commits
  (1) 1c45c1d0d415 by ai: commit (AI)
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-ai
  $ reset_to_base

Human change overwritten by AI
  $ echo change-human > file
  $ hg create-phantom-commit -q --message "change"
  $ echo change-ai > file
  $ hg create-phantom-commit -q --ai --message "change"
  $ hg ci -m "commit"
  preparing squashed ai commit
  squashed ai commit: b92bc59074fb63ad47e2e5876fbc6462d7d0bf72
  skipping human commit since there are no changes
  deleting bookmark 'phantom'
  created new head
  $ show_commits
  (1) b92bc59074fb by ai: commit (AI)
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-ai
  $ reset_to_base

AI change overwritten by human
  $ echo change-ai > file
  $ hg create-phantom-commit -q --ai --message "change"
  $ echo change-human > file
  $ hg create-phantom-commit -q --message "change"
  $ hg ci -m "commit"
  preparing squashed ai commit
  skipping squashed ai commit since ai changes are untracked
  human commit: df6c8da85993e217c279a96b1e56a2cc03fde8b5
  deleting bookmark 'phantom'
  warning: commit already existed in the repository!
  $ show_commits
  (1) df6c8da85993 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-human
  $ reset_to_base

Human change followed by AI change
  $ echo change-human > file
  $ hg create-phantom-commit -q --message "change"
  $ echo change-ai >> file
  $ hg create-phantom-commit -q --ai --message "change"
  $ hg ci -m "commit"
  preparing squashed ai commit
  squashed ai commit: 1841500964f1ff2afaabd26aed68a2558125fd5c
  human commit: 1aebac57d968dd23f339d33687107bcbd0acb7f6
  deleting bookmark 'phantom'
  created new head
  $ show_commits
  (1) 1841500964f1 by ai: commit (AI)
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,2 @@
       C
      +change-ai
  (2) 1aebac57d968 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,2 +1,2 @@
      -C
      +change-human
       change-ai
  $ reset_to_base

AI change followed by human change
  $ echo change-ai > file
  $ hg create-phantom-commit -q --ai --message "change"
  $ echo change-human >> file
  $ hg create-phantom-commit -q --message "change"
  $ hg ci -m "commit"
  preparing squashed ai commit
  squashed ai commit: 83afb696fad8c489fe03acad6f0b61bc7ec493b5
  human commit: 7ab4a9d6a2c59829ff45fd3f0ef5294277d8d70a
  deleting bookmark 'phantom'
  created new head
  $ show_commits
  (1) 83afb696fad8 by ai: commit (AI)
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-ai
  (2) 7ab4a9d6a2c5 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,2 @@
       change-ai
      +change-human
  $ reset_to_base

Test untracked files
--------------------

Human and AI change untracked file
  $ echo human >> newfile
  $ hg create-phantom-commit -q --message "change"
  $ echo ai >> newfile
  $ hg create-phantom-commit -q --ai --message "change"

Commit something else
  $ echo change-human > file
  $ hg ci -qm "change"
  $ show_commits
  (1) e758ad9f572f by test: change
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-human

It created a new phantom commit for newfile
  $ hg debug::phantom-commits
  #1 784222a3a9f3 1970-01-01T00:00:00+0000 ai

So we can commit that file later and retain attribution
  $ hg add newfile
  $ hg ci -qm "add newfile"
  $ show_commits
  (1) e758ad9f572f by test: change
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-human
  (2) 0a4752338729 by ai: add newfile (AI)
      diff --git a/newfile b/newfile
      new file mode 100644
      --- /dev/null
      +++ b/newfile
      @@ -0,0 +1,1 @@
      +ai
  (3) f524a1be2a6e by test: add newfile
      diff --git a/newfile b/newfile
      --- a/newfile
      +++ b/newfile
      @@ -1,1 +1,2 @@
      +human
       ai

  $ reset_to_base

Test adding files
-----------------

This section tests different cases of human and AI adding files:
* order: human->AI or AI->human
* content: empty or nonempty
* extra phantom: for AI->human, whether to do a redundant human phantom commit

Human adds a file, then AI adds a file (empty)
  $ touch human-file
  $ hg create-phantom-commit -q --message "human"
  $ touch ai-file
  $ hg create-phantom-commit -q --ai --message "ai"
  $ hg commit -qAm "add"
  $ show_commits
  (1) a3bbd4f727c1 by ai: add (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) 699808c8ddc9 by test: add
      diff --git a/human-file b/human-file
      new file mode 100644
  $ reset_to_base

Human adds a file, then AI adds a file (nonempty)
  $ echo human > human-file
  $ hg create-phantom-commit -q --message "human"
  $ echo ai > ai-file
  $ hg create-phantom-commit -q --ai --message "ai"
  $ hg commit -qAm "add"
  $ show_commits
  (1) 098283d0dbd0 by ai: add (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
      --- /dev/null
      +++ b/ai-file
      @@ -0,0 +1,1 @@
      +ai
  (2) 52ed0e763d25 by test: add
      diff --git a/human-file b/human-file
      new file mode 100644
      --- /dev/null
      +++ b/human-file
      @@ -0,0 +1,1 @@
      +human
  $ reset_to_base

AI adds a file, then human adds a file, with human phantom commit (empty)
  $ touch ai-file
  $ hg create-phantom-commit -q --ai --message "ai"
  $ touch human-file
  $ hg create-phantom-commit -q --message "human"
  $ hg commit -qAm "add"
  $ show_commits
  (1) 539fe173b26c by ai: add (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) bd0b04d66802 by test: add
      diff --git a/human-file b/human-file
      new file mode 100644
  $ reset_to_base

AI adds a file, then human adds a file, with human phantom commit (nonempty)
  $ echo ai > ai-file
  $ hg create-phantom-commit -q --ai --message "ai"
  $ echo human > human-file
  $ hg create-phantom-commit -q --message "human"
  $ hg commit -qAm "add"
  $ show_commits
  (1) 78c141774bf7 by ai: add (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
      --- /dev/null
      +++ b/ai-file
      @@ -0,0 +1,1 @@
      +ai
  (2) 88886c58f8e5 by test: add
      diff --git a/human-file b/human-file
      new file mode 100644
      --- /dev/null
      +++ b/human-file
      @@ -0,0 +1,1 @@
      +human
  $ reset_to_base

AI adds a file, then human adds a file, without human phantom commit (empty)
  $ touch ai-file
  $ hg create-phantom-commit -q --ai --message "ai"
  $ touch human-file
  $ hg commit -qAm "add"
  $ show_commits
  (1) 444194534f3c by ai: add (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) 2ddb7196deb3 by test: add
      diff --git a/human-file b/human-file
      new file mode 100644
  $ reset_to_base

AI adds a file, then human adds a file, without human phantom commit (nonempty)
  $ echo ai > ai-file
  $ hg create-phantom-commit -q --ai --message "ai"
  $ echo human > human-file
  $ hg commit -qAm "add"
  $ show_commits
  (1) 75e8c0f0ee76 by ai: add (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
      --- /dev/null
      +++ b/ai-file
      @@ -0,0 +1,1 @@
      +ai
  (2) 1549803daae5 by test: add
      diff --git a/human-file b/human-file
      new file mode 100644
      --- /dev/null
      +++ b/human-file
      @@ -0,0 +1,1 @@
      +human
  $ reset_to_base

Test removing files
-------------------

This section tests different cases of human or AI removing a file:
* remover: human or AI
* order: before or after other's phantom commit
* extra phantom: whether to do a redundant human phantom commit

Human removes a file (before AI phantom commit)
  $ rm file
  $ hg create-phantom-commit -q --message "remove"
  $ touch ai-file # to avoid falling back to regular commit
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ hg ci -qAm "commit"
  $ show_commits
  (1) 7754226b93d3 by ai: commit (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) ea275a573a34 by test: commit
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

Human removes a file (after AI phantom commit, without human phantom commit)
  $ touch ai-file # to avoid falling back to regular commit
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ rm file
  $ hg ci -qAm "commit"
  $ show_commits
  (1) 4597b7929749 by ai: commit (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) e297a0ce2a8e by test: commit
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

Human removes a file (after AI phantom commit, with human phantom commit)
  $ touch ai-file # to avoid falling back to regular commit
  $ hg create-phantom-commit -q --ai --message "prevent fallback"
  $ rm file
  $ hg create-phantom-commit -q --message "remove"
  $ hg ci -qAm "commit"
  $ show_commits
  (1) e012c6755997 by ai: commit (AI)
      diff --git a/ai-file b/ai-file
      new file mode 100644
  (2) 3d7262de6759 by test: commit
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

AI removes a file (no human phantom commit)
  $ rm file
  $ hg create-phantom-commit -q --ai --message "remove"
  $ hg ci -qAm "commit"
  $ show_commits
  (1) 8d855f64afc4 by ai: commit (AI)
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  $ reset_to_base

AI removes a file (before human phantom commit)
  $ rm file
  $ hg create-phantom-commit -q --ai --message "remove"
  $ touch human-file
  $ hg create-phantom-commit -q --message "human"
  $ hg ci -qAm "commit"
  $ show_commits
  (1) b07acdecbb02 by ai: commit (AI)
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  (2) bc15cfcf3a64 by test: commit
      diff --git a/human-file b/human-file
      new file mode 100644
  $ reset_to_base

AI removes a file (after human phantom commit)
  $ touch human-file
  $ hg create-phantom-commit -q --message "human"
  $ rm file
  $ hg create-phantom-commit -q --ai --message "remove"
  $ hg ci -qAm "commit"
  $ show_commits
  (1) 5ea5e4842287 by ai: commit (AI)
      diff --git a/file b/file
      deleted file mode 100644
      --- a/file
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -C
  (2) f9b41550ab97 by test: commit
      diff --git a/human-file b/human-file
      new file mode 100644
  $ reset_to_base

Test revert AI change (without phantom commit)
----------------------------------------------

AI makes a change containing "SECRET"
(also add a new AI file, to avoid skipping the squashed AI commit later)
  $ echo SECRET > file
  $ touch added-ai
  $ hg create-phantom-commit -q --ai --message "change"

Human reverts the change
  $ hg revert file --no-backup

There is nothing to commit at this point
  $ hg ci -m "commit"
  nothing changed
  [1]
  $ show_commits
  abort: export requires at least one changeset
  [10]

Human makes a change (to ensure the file is involved in the final commit)
  $ echo change-human > file

Commit. The word "SECRET" does not appear at all, rather than being added and
removed, because the final result is based on net changes.
  $ hg ci -qAm "commit"
  $ show_commits
  (1) 017f9393d537 by ai: commit (AI)
      diff --git a/added-ai b/added-ai
      new file mode 100644
  (2) d7127ba11ea3 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-human
  $ reset_to_base

Test revert AI change (with phantom commit)
-------------------------------------------

AI makes a change containing "SECRET"
(also add a new AI file, to avoid skipping the squashed AI commit later)
  $ echo SECRET > file
  $ touch added-ai
  $ hg create-phantom-commit -q --ai --message "change"

Human reverts the change
  $ hg revert file --no-backup
  $ hg create-phantom-commit -q --message "revert"

There is nothing to commit at this point
  $ hg ci -m "commit"
  nothing changed
  [1]
  $ show_commits
  abort: export requires at least one changeset
  [10]

Human makes a change (to ensure the file is involved in the final commit)
  $ echo change-human > file
  $ hg create-phantom-commit -q --message "change"

Commit. The word "SECRET" does not appear at all, rather than being added and
removed, because the final result is based on net changes.
  $ hg ci -qAm "commit"
  $ show_commits
  (1) c0f1c8781328 by ai: commit (AI)
      diff --git a/added-ai b/added-ai
      new file mode 100644
  (2) d98e1c966399 by test: commit
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -1,1 +1,1 @@
      -C
      +change-human
  $ reset_to_base
