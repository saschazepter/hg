$!
$! Set hg and hgeditor symbol
$!
$ HG == "$ PYTHON$ROOT:[BIN]PYTHON /MERCURIAL_ROOT/HG"
$ HGEDITOR == "@MERCURIAL_ROOT:[VMS]HGEDITOR"
$
$ exit