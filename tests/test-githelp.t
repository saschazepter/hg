  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > githelp =
  > EOF

  $ hg init repo
  $ cd repo
  $ echo foo > test_file
  $ mkdir dir
  $ echo foo > dir/file
  $ echo foo > removed_file
  $ echo foo > deleted_file
  $ hg add -q .
  $ hg commit -m 'bar'
  $ hg bookmark both
  $ touch both
  $ touch untracked_file
  $ hg remove removed_file
  $ rm deleted_file

githelp on a single command should succeed
  $ hg githelp -- commit
  hg commit
  $ hg githelp -- git commit
  hg commit

githelp should fail nicely if we don't give it arguments
  $ hg githelp
  abort: missing git command - usage: hg githelp -- <git command>
  [255]
  $ hg githelp -- git
  abort: missing git command - usage: hg githelp -- <git command>
  [255]

githelp on a command with options should succeed
  $ hg githelp -- commit -pm "abc"
  hg commit --interactive -m 'abc'

githelp on a command with standalone unrecognized option should succeed with warning
  $ hg githelp -- commit -p -v
  ignoring unknown option -v
  hg commit --interactive

githelp on a command with unrecognized option packed with other options should fail with error
  $ hg githelp -- commit -pv
  abort: unknown option 'v' packed with other options
  (please try passing the option as its own flag: -v)
  [255]

githelp for git rebase --skip
  $ hg githelp -- git rebase --skip
  hg revert --all -r .
  hg rebase --continue

githelp for git commit --amend (hg commit --amend pulls up an editor)
  $ hg githelp -- commit --amend
  hg commit --amend

githelp for git commit --amend --no-edit (hg amend does not pull up an editor)
  $ hg githelp -- commit --amend --no-edit
  hg amend

githelp for git checkout -- . (checking out a directory)
  $ hg githelp -- checkout -- .
  note: use --no-backup to avoid creating .orig files
  
  hg revert .

githelp for git checkout "HEAD^" (should still work to pass a rev)
  $ hg githelp -- checkout "HEAD^"
  hg update .^

githelp checkout: args after -- should be treated as paths no matter what
  $ hg githelp -- checkout -- HEAD
  note: use --no-backup to avoid creating .orig files
  
  hg revert HEAD

githelp for git checkout with rev and path
  $ hg githelp -- checkout "HEAD^" -- file.txt
  note: use --no-backup to avoid creating .orig files
  
  hg revert -r .^ file.txt

githelp for git with rev and path, without separator
  $ hg githelp -- checkout "HEAD^" file.txt
  note: use --no-backup to avoid creating .orig files
  
  hg revert -r .^ file.txt

githelp for checkout with a file as first argument
  $ hg githelp -- checkout test_file
  note: use --no-backup to avoid creating .orig files
  
  hg revert test_file

githelp for checkout with a removed file as first argument
  $ hg githelp -- checkout removed_file
  note: use --no-backup to avoid creating .orig files
  
  hg revert removed_file

githelp for checkout with a deleted file as first argument
  $ hg githelp -- checkout deleted_file
  note: use --no-backup to avoid creating .orig files
  
  hg revert deleted_file

githelp for checkout with a untracked file as first argument
  $ hg githelp -- checkout untracked_file
  note: use --no-backup to avoid creating .orig files
  
  hg revert untracked_file

githelp for checkout with a directory as first argument
  $ hg githelp -- checkout dir
  note: use --no-backup to avoid creating .orig files
  
  hg revert dir

githelp for checkout when not in repo root
  $ cd dir
  $ hg githelp -- checkout file
  note: use --no-backup to avoid creating .orig files
  
  hg revert file

  $ cd ..

githelp for checkout with an argument that is both a file and a revision
  $ hg githelp -- checkout both
  hg update both

githelp for checkout with the -p option
  $ hg githelp -- git checkout -p xyz
  hg revert -i -r xyz

  $ hg githelp -- git checkout -p xyz -- abc
  note: use --no-backup to avoid creating .orig files
  
  hg revert -i -r xyz abc

githelp for checkout with the -f option and a rev
  $ hg githelp -- git checkout -f xyz
  hg update -C xyz
  $ hg githelp -- git checkout --force xyz
  hg update -C xyz

githelp for checkout with the -f option without an arg
  $ hg githelp -- git checkout -f
  hg revert --all
  $ hg githelp -- git checkout --force
  hg revert --all

githelp for grep with pattern and path
  $ hg githelp -- grep shrubbery flib/intern/
  hg grep shrubbery flib/intern/

githelp for reset, checking ~ in git becomes ~1 in mercurial
  $ hg githelp -- reset HEAD~
  hg update .~1
  $ hg githelp -- reset "HEAD^"
  hg update .^
  $ hg githelp -- reset HEAD~3
  hg update .~3

  $ hg githelp -- reset --mixed HEAD
  note: --mixed has no meaning since Mercurial has no staging area
  
  hg update .
  $ hg githelp -- reset --soft HEAD
  note: --soft has no meaning since Mercurial has no staging area
  
  hg update .
  $ hg githelp -- reset --hard HEAD
  hg update --clean .

githelp for git show --name-status
  $ hg githelp -- git show --name-status
  hg log --style status -r .

githelp for git show --pretty=format: --name-status
  $ hg githelp -- git show --pretty=format: --name-status
  hg status --change .

githelp for show with no arguments
  $ hg githelp -- show
  hg export

githelp for show with a path
  $ hg githelp -- show test_file
  hg cat test_file

githelp for show with not a path:
  $ hg githelp -- show rev
  hg export rev

githelp for show with many arguments
  $ hg githelp -- show argone argtwo
  hg export argone argtwo
  $ hg githelp -- show test_file argone argtwo
  hg cat test_file argone argtwo

githelp for show with --unified options
  $ hg githelp -- show --unified=10
  hg export --config diff.unified=10
  $ hg githelp -- show -U100
  hg export --config diff.unified=100

githelp for show with a path and --unified
  $ hg githelp -- show -U20 test_file
  hg cat test_file --config diff.unified=20

githelp for stash drop without name
  $ hg githelp -- git stash drop
  hg shelve -d <shelve name>

githelp for stash drop with name
  $ hg githelp -- git stash drop xyz
  hg shelve -d xyz

githelp for stash list with patch
  $ hg githelp -- git stash list -p
  hg shelve -l -p

githelp for stash show
  $ hg githelp -- git stash show
  hg shelve --stat

githelp for stash show with patch and name
  $ hg githelp -- git stash show -p mystash
  hg shelve -p mystash

githelp for stash clear
  $ hg githelp -- git stash clear
  hg shelve --cleanup

githelp for whatchanged should show deprecated message
  $ hg githelp -- whatchanged -p
  this command has been deprecated in the git project, thus isn't supported by this tool
  

githelp for git branch -m renaming
  $ hg githelp -- git branch -m old new
  hg bookmark -m old new

When the old name is omitted, git branch -m new renames the current branch.
  $ hg githelp -- git branch -m new
  hg bookmark -m `hg log -T"{activebookmark}" -r .` new

Branch deletion in git strips commits
  $ hg githelp -- git branch -d
  hg strip -B
  $ hg githelp -- git branch -d feature
  hg strip -B feature -B
  $ hg githelp -- git branch --delete experiment1 experiment2
  hg strip -B experiment1 -B experiment2 -B

githelp for reuse message using the shorthand
  $ hg githelp -- git commit -C deadbeef
  hg commit -M deadbeef

githelp for reuse message using the the long version
  $ hg githelp -- git commit --reuse-message deadbeef
  hg commit -M deadbeef

githelp for reuse message using HEAD
  $ hg githelp -- git commit --reuse-message HEAD~
  hg commit -M .~1

githelp for apply with no options
  $ hg githelp -- apply
  hg import --no-commit

githelp for apply with directory strip custom
  $ hg githelp -- apply -p 5
  hg import --no-commit -p 5

githelp for apply with prefix directory
  $ hg githelp -- apply --directory=modules
  hg import --no-commit --prefix modules

git merge-base
  $ hg githelp -- git merge-base --is-ancestor
  ignoring unknown option --is-ancestor
  note: ancestors() is part of the revset language
  (learn more about revsets with 'hg help revsets')
  
  hg log -T '{node}\n' -r 'ancestor(A,B)'

githelp for git blame
  $ hg githelp -- git blame
  hg annotate -udl

githelp for add

  $ hg githelp -- git add
  hg add

  $ hg githelp -- git add -p
  note: Mercurial will commit when complete, as there is no staging area in Mercurial
  
  hg commit --interactive

  $ hg githelp -- git add --all
  note: use hg addremove to remove files that have been deleted
  
  hg add

githelp for reflog

  $ hg githelp -- git reflog
  hg journal
  
  note: in hg commits can be deleted from repo but we always have backups

  $ hg githelp -- git reflog --all
  hg journal --all
  
  note: in hg commits can be deleted from repo but we always have backups

  $ hg githelp -- git log -Gnarf
  hg grep --diff narf
  $ hg githelp -- git log -S narf
  hg grep --diff narf
  $ hg githelp -- git log --pickaxe-regex narf
  hg grep --diff narf
