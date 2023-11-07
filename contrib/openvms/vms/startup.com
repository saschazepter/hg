$!
$! Mercurial startup file
$!
$ proc = f$environment("PROCEDURE")
$ cur_dev = f$parse(proc,,,"DEVICE","SYNTAX_ONLY")
$ cur_dir = f$parse(proc,,,"DIRECTORY","SYNTAX_ONLY")
$!
$! Define logicals
$!
$ @'cur_dev''cur_dir'logicals "/system/exec"
$
$ exit
