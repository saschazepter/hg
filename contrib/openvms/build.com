$!
$! Build Python C extension
$!
$ cc/name=(short,as_is)-
	/incl=("/python$root/include", "../../mercurial") -
	[--.mercurial.cext]base85.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial]bdiff.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.cext]bdiff.c -
	/obj=[]bdiff-mod.obj
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.thirdparty.xdiff]xdiffi.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.thirdparty.xdiff]xprepare.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
	[--.mercurial.thirdparty.xdiff]xutils.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.cext]mpatch.c/obj=mpatch-mod.obj
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial]mpatch.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
	/warn=disa=QUESTCOMPARE -
        [--.mercurial.cext]dirs.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.cext]charencode.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.cext]revlog.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.cext]manifest.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
        [--.mercurial.cext]pathencode.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
	/warn=disa=CVTDIFTYPES -
        [--.mercurial.cext]osutil.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial") -
	/warn=disa=EXTRASEMI -
        [--.mercurial.cext]parsers.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
		"../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard]zstd.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]frameparams.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressobj.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
		"../python-zstandard/zstd/common") -
        [-.python-zstandard.c-ext]compressor.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]bufferutil.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]decompressoriterator.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
		"../python-zstandard/zstd/common") -
        [-.python-zstandard.c-ext]decompressor.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]frameparams.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]constants.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]decompressionreader.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]decompressionwriter.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressiondict.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]decompressobj.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressionwriter.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressionreader.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressoriterator.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressionparams.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.c-ext]compressionchunker.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
		"../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.zstd.common]zstd_common.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder") -
        [-.python-zstandard.zstd.common]error_private.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
		"../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_compress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
		"../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_ldm.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_opt.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_lazy.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.compress]huf_compress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.common]entropy_common.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.compress]fse_compress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_fast.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.common]fse_decompress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.compress]hist.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_double_fast.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.common]pool.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.common]xxhash.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_compress_sequences.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstd_compress_literals.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.decompress]zstd_ddict.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.decompress]zstd_decompress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.decompress]huf_decompress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.decompress]zstd_decompress_block.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
	/warn=disa=TOOFEWACTUALS -
        [-.python-zstandard.zstd.compress]zstdmt_compress.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.dictBuilder]cover.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.dictBuilder]fastcover.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.dictBuilder]divsufsort.c
$ cc/name=(short,as_is)-
        /incl=("/python$root/include", "../../mercurial", -
                "../python-zstandard/c-ext", "../python-zstandard/zstd", -
                "../python-zstandard/zstd/dictBuilder", -
                "../python-zstandard/zstd/common") -
        [-.python-zstandard.zstd.dictBuilder]zdict.c
$ 
$ link/share=base65.exe sys$input/opt
GSMATCH=lequal,1,1000
case_sensitive=YES
SYMBOL_VECTOR = (PyInit_base85=PROCEDURE)
SYMBOL_VECTOR = (PYINIT_BASE85/PyInit_base85=PROCEDURE)
base85.obj
python$shr/share
case_sensitive=NO
$
$ link/share=bdiff.exe sys$input/opt
GSMATCH=lequal,1,1000
case_sensitive=YES
SYMBOL_VECTOR = (PyInit_bdiff=PROCEDURE)
SYMBOL_VECTOR = (PYINIT_BDIFF/PyInit_bdiff=PROCEDURE)
bdiff.obj
bdiff-mod.obj
xdiffi.obj
xprepare.obj
xutils.obj
python$shr/share
case_sensitive=NO
$
$ link/share=mpatch.exe sys$input/opt
GSMATCH=lequal,1,1000
case_sensitive=YES
SYMBOL_VECTOR = (PyInit_mpatch=PROCEDURE)
SYMBOL_VECTOR = (PYINIT_MPATCH/PyInit_mpatch=PROCEDURE)
mpatch.obj
mpatch-mod.obj
python$shr/share
case_sensitive=NO
$
$ link/share=osutil.exe sys$input/opt
GSMATCH=lequal,1,1000
case_sensitive=YES
SYMBOL_VECTOR = (PyInit_osutil=PROCEDURE)
SYMBOL_VECTOR = (PYINIT_OSUTIL/PyInit_osutil=PROCEDURE)
osutil.obj
python$shr/share
case_sensitive=NO
$
$ link/share=parsers.exe sys$input/opt
GSMATCH=lequal,1,1000
case_sensitive=YES
SYMBOL_VECTOR = (PyInit_parsers=PROCEDURE)
SYMBOL_VECTOR = (PYINIT_PARSERS/PyInit_parsers=PROCEDURE)
parsers.obj
dirs.obj
charencode.obj
pathencode.obj
revlog.obj
manifest.obj
python$shr/share
case_sensitive=NO
$
$ link/share=zstd.exe sys$input/opt
GSMATCH=lequal,1,1000
case_sensitive=YES
SYMBOL_VECTOR = (PyInit_zstd=PROCEDURE)
SYMBOL_VECTOR = (PYINIT_ZSTD/PyInit_zstd=PROCEDURE)
zstd.obj
frameparams.obj
decompressobj.obj
zstd_common.obj
compressionreader.obj
compressionwriter.obj
compressoriterator.obj
zstd_compress.obj
zstd_opt.obj
zstd_lazy.obj
huf_compress.obj
entropy_common.obj
fse_compress.obj
fse_decompress.obj
zstd_fast.obj
zstd_ldm.obj
hist.obj
zstd_double_fast.obj
zstd_compress_sequences.obj
zstd_compress_literals.obj
zstdmt_compress.obj
compressiondict.obj
zstd_ddict.obj
zstd_decompress.obj
zstd_decompress_block.obj
zdict.obj
huf_decompress.obj
compressionparams.obj
compressobj.obj
decompressionreader.obj
compressionchunker.obj
decompressionwriter.obj
decompressor.obj
decompressoriterator.obj
compressor.obj
divsufsort.obj
bufferutil.obj
constants.obj
error_private.obj
cover.obj
fastcover.obj
pool.obj
xxhash.obj
python$shr/share
case_sensitive=NO
$
$ delete/noconf *.obj;
$ rename zstd.exe [--.mercurial]/log
$ rename *.exe [--.mercurial.cext]/log
$
$ exit
