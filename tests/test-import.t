  [255]
  $ HGEDITOR=cat hg --cwd b import ../exported-tip.patch
  > from __future__ import print_function
  [255]
  [255]

  $ egrep -v '^(Subject|email)' msg.patch | hg --cwd b import -
  [255]
  [255]
  [255]
  [255]
  [255]
  [255]
  $ ls
  $ ls
  $ ls
  [255]
  [255]
  [255]
  [255]