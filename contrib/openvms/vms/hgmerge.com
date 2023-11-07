$!
$! Custom merge tool to help solve merge conflict in OpenVMS
$! We recommand to solve this on other system
$!
$ set proc/par=extend
$ mine = p1
$ orig = p2
$ theirs = p3
$ tovms :== $ MERCURIAL_ROOT:[vms]tovms
$ merged = p1 + ".hgmerge"
$ tovms 'merged'
$ merged = tmpfn
$
$ define DECC$UNIX_LEVEL 90
$ gdiff3 :== $ MERCURIAL_ROOT:[vms]gdiff3
$ gdiff == "$ MERCURIAL_ROOT:[VMS]gdiff"
$! gdiff -u 'orig' 'mine'
$! gdiff -u 'orig' 'theirs'
$ if (f$search("''merged'") .nes. "") then -
          delete 'merged';*
$ define sys$output 'merged'
$ gdiff3 -"L" mine -"L" original -"L" theirs -"E" -m 'mine' 'orig' 'theirs'
$ status = $status
$ deassign sys$output
$ convert/fdl=mercurial_root:[vms]stmlf.fdl 'merged' 'merged'
$ purge/nolog 'merged'
$! No conflicts found.  Merge done.
$ if status .eqs. "%X006C8009"
$ then
$   tovms 'p1'
$   mine = tmpfn
$   rename 'merged' 'mine'
$   purge/nolog 'mine'
$   write sys$output "Merged ''mine'"
$   exit 1
$ endif
$
$! In all other cases, diff3 has found conflicts, added the proper conflict
$! markers to the merged file and we should now edit this file.  Fire up an
$! editor with the merged file and let the user manually resolve the conflicts.
$! When the editor exits successfully, there should be no conflict markers in
$! the merged file, otherwise we consider this merge failed.
$
$ if status .eqs. "%X006C8013"
$ then
$   deassign sys$input
$   edit 'merged'
$   open fi 'merged'
$   loop:
$     read fi srec/end=endloop
$     rec7 = f$extract(0, 7, srec)
$     if rec7 .eqs. "<<<<<<<" then goto conflict
$     if rec7 .eqs. "|||||||" then goto conflict
$     if rec7 .eqs. "=======" then goto conflict
$     if rec7 .eqs. ">>>>>>>" then goto conflict
$     goto loop
$   endloop:
$   close fi
$   tovms 'p1'
$   mine = tmpfn
$   rename 'merged' 'mine'
$   purge/nolog 'mine'
$   exit
$ endif
$ if (f$search("''merged'") .nes. "") then -
          delete 'merged';*
$ write sys$output "serious diff3 error, while trying to merge ''mine'"
$ exit 44
$ 
$ conflict:
$ close fi
$ if (f$search("''merged'") .nes. "") then -
          delete 'merged';*
$ write sys$output -
 "conflict markers still found in the working-copy.  Merge aborted for ''mine'"
$ exit 44
