from mercurial import demandimport

demandimport.enable()

import os
import subprocess
import sys
import types

# Don't import pycompat because it has too many side-effects.
ispy311 = (sys.version_info.major, sys.version_info.minor) >= (3, 11)

# Only run if demandimport is allowed
if subprocess.call(
    [os.environ['PYTHON'], '%s/hghave' % os.environ['TESTDIR'], 'demandimport']
):
    sys.exit(80)

# We rely on assert, which gets optimized out.
if sys.flags.optimize:
    sys.exit(80)

# The demand importer doesn't work on Python 3.5.
if sys.version_info[0:2] == (3, 5):
    sys.exit(80)

from importlib.util import _LazyModule

try:
    from importlib.util import _Module as moduletype
except ImportError:
    moduletype = types.ModuleType

import re

rsub = re.sub


def f(obj):
    l = repr(obj)
    l = rsub("0x[0-9a-fA-F]+", "0x?", l)
    l = rsub("from '.*'", "from '?'", l)
    l = rsub("'<[a-z]*>'", "'<whatever>'", l)
    return l


demandimport.disable()
os.environ['HGDEMANDIMPORT'] = 'disable'
# this enable call should not actually enable demandimport!
demandimport.enable()
from mercurial import node

# We use assert instead of a unittest test case because having imports inside
# functions changes behavior of the demand importer.
assert not isinstance(node, _LazyModule)

# now enable it for real
del os.environ['HGDEMANDIMPORT']
demandimport.enable()

# Test access to special attributes through demandmod proxy
assert 'mercurial.error' not in sys.modules
from mercurial import error as errorproxy

assert isinstance(errorproxy, _LazyModule)
assert f(errorproxy) == "<module 'mercurial.error' from '?'>", f(errorproxy)

doc = ' '.join(errorproxy.__doc__.split()[:3])
assert doc == 'Mercurial exceptions. This', doc
assert errorproxy.__name__ == 'mercurial.error', errorproxy.__name__

# __name__ must be accessible via __dict__ so the relative imports can be
# resolved
name = errorproxy.__dict__['__name__']
assert name == 'mercurial.error', name

assert not isinstance(errorproxy, _LazyModule)
assert f(errorproxy) == "<module 'mercurial.error' from '?'>", f(errorproxy)

import os

assert not isinstance(os, _LazyModule)
if ispy311:
    assert f(os) == "<module 'os' (frozen)>", f(os)
else:
    assert f(os) == "<module 'os' from '?'>", f(os)

assert f(os.system) == '<built-in function system>', f(os.system)
if ispy311:
    assert f(os) == "<module 'os' (frozen)>", f(os)
else:
    assert f(os) == "<module 'os' from '?'>", f(os)

assert 'mercurial.utils.procutil' not in sys.modules
from mercurial.utils import procutil

assert isinstance(procutil, _LazyModule)
assert f(procutil) == "<module 'mercurial.utils.procutil' from '?'>", f(
    procutil
)

assert f(procutil.system) == '<function system at 0x?>', f(procutil.system)
assert procutil.__class__ == moduletype, procutil.__class__
assert f(procutil) == "<module 'mercurial.utils.procutil' from '?'>", f(
    procutil
)
assert f(procutil.system) == '<function system at 0x?>', f(procutil.system)

assert 'mercurial.hgweb' not in sys.modules
from mercurial import hgweb

assert isinstance(hgweb, _LazyModule)
assert f(hgweb) == "<module 'mercurial.hgweb' from '?'>", f(hgweb)
assert isinstance(hgweb.hgweb_mod, _LazyModule)
assert f(hgweb.hgweb_mod) == "<module 'mercurial.hgweb.hgweb_mod' from '?'>", f(
    hgweb.hgweb_mod
)

assert f(hgweb) == "<module 'mercurial.hgweb' from '?'>", f(hgweb)

import re as fred

assert not isinstance(fred, _LazyModule)
assert f(fred) == "<module 're' from '?'>"

import re as remod

assert not isinstance(remod, _LazyModule)
assert f(remod) == "<module 're' from '?'>"

import sys as re

assert not isinstance(re, _LazyModule)
assert f(re) == "<module 'sys' (built-in)>"

assert not isinstance(fred, _LazyModule)
assert f(fred) == "<module 're' from '?'>", f(fred)

assert f(fred.sub) == '<function sub at 0x?>', f(fred.sub)

assert not isinstance(fred, _LazyModule)
assert f(fred) == "<module 're' from '?'>", f(fred)

remod.escape  # use remod
assert f(remod) == "<module 're' from '?'>", f(remod)

assert not isinstance(re, _LazyModule)
assert f(re) == "<module 'sys' (built-in)>"
assert f(type(re.stderr)) == "<class '_io.TextIOWrapper'>", f(type(re.stderr))
assert f(re) == "<module 'sys' (built-in)>"

assert 'wsgiref' not in sys.modules
import wsgiref

assert isinstance(wsgiref, _LazyModule)
assert f(wsgiref) == "<module 'wsgiref' from '?'>"

try:
    from wsgiref import unknownattr

    assert False, (
        'no demandmod should be created for attribute of non-package '
        'module:\nwsgiref.unknownattr = %s' % f(unknownattr)
    )
except ImportError as inst:
    assert rsub(r"'", '', str(inst)).startswith(
        'cannot import name unknownattr'
    )

# Unlike the import statement, __import__() function should not raise
# ImportError even if fromlist has an unknown item
# (see Python/import.c:import_module_level() and ensure_fromlist())
assert 'ftplib' not in sys.modules
zipfileimp = __import__('ftplib', globals(), locals(), ['unknownattr'])
assert f(zipfileimp) == "<module 'ftplib' from '?'>", f(zipfileimp)
assert not hasattr(zipfileimp, 'unknownattr')


# test deactivation for issue6725
del sys.modules['wsgiref']
with demandimport.deactivated():
    import wsgiref
assert wsgiref.__loader__ == wsgiref.__spec__.loader
assert wsgiref.__loader__.get_resource_reader
