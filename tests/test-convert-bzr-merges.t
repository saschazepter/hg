#require bzr

N.B. bzr 1.13 has a bug that breaks this test.  If you see this
test fail, check your bzr version.  Upgrading to bzr 1.13.1
should fix it.

  $ . "$TESTDIR/bzr-definitions"

test multiple merges at once

  $ mkdir test-multimerge
  $ cd test-multimerge
  $ bzr init -q source
  $ cd source
  $ echo content > file
  $ bzr add -q file
  $ bzr commit -q -m 'Initial add' '--commit-time=2009-10-10 08:00:00 +0100'
  $ cd ..
  $ bzr branch -q source source-branch1
  $ cd source-branch1
  $ echo morecontent >> file
  $ echo evenmorecontent > file-branch1
  $ bzr add -q file-branch1
  $ bzr commit -q -m 'Added branch1 file' '--commit-time=2009-10-10 08:00:01 +0100'
  $ cd ../source
  $ sleep 1
  $ echo content > file-parent
  $ bzr add -q file-parent
  $ bzr commit -q -m 'Added parent file' '--commit-time=2009-10-10 08:00:02 +0100'
  $ cd ..
  $ bzr branch -q source source-branch2
  $ cd source-branch2
  $ echo somecontent > file-branch2
  $ bzr add -q file-branch2
  $ bzr commit -q -m 'Added brach2 file' '--commit-time=2009-10-10 08:00:03 +0100'
  $ sleep 1
  $ cd ../source
  $ bzr merge -q ../source-branch1
  $ bzr merge -q --force ../source-branch2
  $ bzr commit -q -m 'Merged branches' '--commit-time=2009-10-10 08:00:04 +0100'
  $ cd ..

BUG: file-branch2 should not be added in rev 4
  $ hg convert --datesort --config convert.bzr.saverev=False source source-hg
  initializing destination source-hg repository
  scanning source...
  sorting...
  converting...
  4 Initial add
  3 Added branch1 file
  2 Added parent file
  1 Added brach2 file
  0 Merged branches
  $ glog -R source-hg
  o    5@source "(octopus merge fixup)" files+: [], files-: [], files: []
  |\
  | o    4@source "Merged branches" files+: [file-branch1 file-branch2], files-: [], files: [file]
  | |\
  o---+  3@source-branch2 "Added brach2 file" files+: [file-branch2], files-: [], files: []
   / /
  | o  2@source "Added parent file" files+: [file-parent], files-: [], files: []
  | |
  o |  1@source-branch1 "Added branch1 file" files+: [file-branch1], files-: [], files: [file]
  |/
  o  0@source "Initial add" files+: [file], files-: [], files: []
  
  $ manifest source-hg tip
  % manifest of tip
  644   file
  644   file-branch1
  644   file-branch2
  644   file-parent

  $ hg convert source-hg hg2hg
  initializing destination hg2hg repository
  scanning source...
  sorting...
  converting...
  5 Initial add
  4 Added branch1 file
  3 Added parent file
  2 Added brach2 file
  1 Merged branches
  0 (octopus merge fixup)
  $ hg -R hg2hg out source-hg -T compact
  comparing with source-hg
  searching for changes
  no changes found
  [1]

  $ glog -R hg2hg
  o    5@source "(octopus merge fixup)" files+: [], files-: [], files: []
  |\
  | o    4@source "Merged branches" files+: [file-branch1 file-branch2], files-: [], files: [file]
  | |\
  o---+  3@source-branch2 "Added brach2 file" files+: [file-branch2], files-: [], files: []
   / /
  | o  2@source "Added parent file" files+: [file-parent], files-: [], files: []
  | |
  o |  1@source-branch1 "Added branch1 file" files+: [file-branch1], files-: [], files: [file]
  |/
  o  0@source "Initial add" files+: [file], files-: [], files: []
  

  $ hg -R source-hg log --debug -r tip
  changeset:   5:6bd55e8269392769783345686faf7ff7b3b0215d
  branch:      source
  tag:         tip
  phase:       draft
  parent:      4:1dc38c377bb35eeea4fa955056fbe4440d54a743
  parent:      3:4aaba1bfb426b8941bbf63f9dd52301152695164
  manifest:    4:daa315d56a98ba20811fdd0d9d575861f65cfa8c
  user:        Foo Bar <foo.bar@example.com>
  date:        Sat Oct 10 08:00:04 2009 +0100
  extra:       branch=source
  description:
  (octopus merge fixup)
  
  
  $ hg -R hg2hg log --debug -r tip
  changeset:   5:6bd55e8269392769783345686faf7ff7b3b0215d
  branch:      source
  tag:         tip
  phase:       draft
  parent:      4:1dc38c377bb35eeea4fa955056fbe4440d54a743
  parent:      3:4aaba1bfb426b8941bbf63f9dd52301152695164
  manifest:    4:daa315d56a98ba20811fdd0d9d575861f65cfa8c
  user:        Foo Bar <foo.bar@example.com>
  date:        Sat Oct 10 08:00:04 2009 +0100
  extra:       branch=source
  description:
  (octopus merge fixup)
  
  
  $ hg -R source-hg manifest --debug -r tip
  cdf31ed9242b209cd94697112160e2c5b37a667d 644   file
  5108144f585149b29779d7c7e51d61dd22303ffe 644   file-branch1
  80753c4a9ac3806858405b96b24a907b309e3616 644   file-branch2
  7108421418404a937c684d2479a34a24d2ce4757 644   file-parent
  $ hg -R source-hg manifest --debug -r 'tip^'
  cdf31ed9242b209cd94697112160e2c5b37a667d 644   file
  5108144f585149b29779d7c7e51d61dd22303ffe 644   file-branch1
  80753c4a9ac3806858405b96b24a907b309e3616 644   file-branch2
  7108421418404a937c684d2479a34a24d2ce4757 644   file-parent

  $ hg -R hg2hg manifest --debug -r tip
  cdf31ed9242b209cd94697112160e2c5b37a667d 644   file
  5108144f585149b29779d7c7e51d61dd22303ffe 644   file-branch1
  80753c4a9ac3806858405b96b24a907b309e3616 644   file-branch2
  7108421418404a937c684d2479a34a24d2ce4757 644   file-parent
  $ hg -R hg2hg manifest --debug -r 'tip^'
  cdf31ed9242b209cd94697112160e2c5b37a667d 644   file
  5108144f585149b29779d7c7e51d61dd22303ffe 644   file-branch1
  80753c4a9ac3806858405b96b24a907b309e3616 644   file-branch2
  7108421418404a937c684d2479a34a24d2ce4757 644   file-parent

  $ cd ..
