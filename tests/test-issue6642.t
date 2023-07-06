hg log --debug shouldn't show different data than {file_*} template keywords
https://bz.mercurial-scm.org/show_bug.cgi?id=6642

  $ hg init issue6642
  $ cd issue6642

  $ echo a > a
  $ hg ci -qAm a
  $ echo b > b
  $ hg ci -qAm b
  $ hg up 0 -q
  $ echo c > c
  $ hg ci -qAm c
  $ hg merge -q
  $ hg ci -m merge

  $ hg log -GT '{rev} {desc} file_adds: [{file_adds}], file_mods: [{file_mods}], file_dels: [{file_dels}], files: [{files}]\n'
  @    3 merge file_adds: [], file_mods: [], file_dels: [], files: []
  |\
  | o  2 c file_adds: [c], file_mods: [], file_dels: [], files: [c]
  | |
  o |  1 b file_adds: [b], file_mods: [], file_dels: [], files: [b]
  |/
  o  0 a file_adds: [a], file_mods: [], file_dels: [], files: [a]
  

  $ hg log -r . --debug | grep files
  [1]
  $ hg log -r . --debug -T json | grep -E '(added|removed|modified)'
    "added": [],
    "modified": [],
    "removed": [],
  $ hg log -r . --debug -T xml | grep path
  <paths>
  </paths>
