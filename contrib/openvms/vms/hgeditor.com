$!
$! Call OpenVMS editor with a conversion from Unix filename syntax to OpenVMS syntax 
$!
$ set proc/par=extend
$ ufile = p1
$ tovms :== $ MERCURIAL_ROOT:[vms]tovms
$ tovms 'ufile'
$ vfile = tmpfn
$ deassign sys$input
$ edit 'vfile'
$ purge/nolog 'vfile'
$ exit
