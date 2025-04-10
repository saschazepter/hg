#!/usr/bin/env python3

from __future__ import annotations

import ast
import collections
import os
import sys

# Import a minimal set of stdlib modules needed for list_stdlib_modules()
# to work when run from a virtualenv.  The modules were chosen empirically
# so that the return value matches the return value without virtualenv.
if True:  # disable lexical sorting checks
    import argparse
    import zlib

import testparseutil

# Allow list of modules that symbols can be directly imported from.
allowsymbolimports = (
    '__future__',
    'breezy',
    'concurrent',
    'hgclient',
    'packaging.version',
    'mercurial',
    'mercurial.hgweb.common',
    'mercurial.hgweb.request',
    'mercurial.i18n',
    'mercurial.interfaces',
    'mercurial.interfaces._basetypes',
    'mercurial.interfaces.types',
    'mercurial.node',
    'mercurial.pycompat',
    # for revlog to re-export constant to extensions
    'mercurial.revlogutils.constants',
    'mercurial.revlogutils.flagutil',
    # for cffi modules to re-export pure functions
    'mercurial.pure.base85',
    'mercurial.pure.bdiff',
    'mercurial.pure.mpatch',
    'mercurial.pure.osutil',
    'mercurial.pure.parsers',
    # third-party imports should be directly imported
    'mercurial.thirdparty',
    'mercurial.thirdparty.attr',
    'mercurial.thirdparty.jaraco.collections',
    'mercurial.thirdparty.tomli',
    'typing',
    'xml.etree.ElementTree',
)

# Allow list of symbols that can be directly imported.
directsymbols = ('demandimport',)

# Modules that must be aliased because they are commonly confused with
# common variables and can create aliasing and readability issues.
requirealias = {
    'ui': 'uimod',
}


def walklocal(root):
    """Recursively yield all descendant nodes but not in a different scope"""
    todo = collections.deque(ast.iter_child_nodes(root))
    yield root, False
    while todo:
        node = todo.popleft()
        newscope = isinstance(node, ast.FunctionDef)
        if not newscope:
            todo.extend(ast.iter_child_nodes(node))
        yield node, newscope


def dotted_name_of_path(path):
    """Given a relative path to a source file, return its dotted module name.

    >>> dotted_name_of_path('mercurial/error.py')
    'mercurial.error'
    >>> dotted_name_of_path('zlibmodule.so')
    'zlib'
    """
    parts = path.replace(os.sep, '/').split('/')
    parts[-1] = parts[-1].split('.', 1)[0]  # remove .py and .so and .ARCH.so
    if parts[-1].endswith('module'):
        parts[-1] = parts[-1][:-6]
    return '.'.join(parts)


def fromlocalfunc(modulename, localmods):
    """Get a function to examine which locally defined module the
    target source imports via a specified name.

    `modulename` is an `dotted_name_of_path()`-ed source file path,
    which may have `.__init__` at the end of it, of the target source.

    `localmods` is a set of absolute `dotted_name_of_path()`-ed source file
    paths of locally defined (= Mercurial specific) modules.

    This function assumes that module names not existing in
    `localmods` are from the Python standard library.

    This function returns the function, which takes `name` argument,
    and returns `(absname, dottedpath, hassubmod)` tuple if `name`
    matches against locally defined module. Otherwise, it returns
    False.

    It is assumed that `name` doesn't have `.__init__`.

    `absname` is an absolute module name of specified `name`
    (e.g. "hgext.convert"). This can be used to compose prefix for sub
    modules or so.

    `dottedpath` is a `dotted_name_of_path()`-ed source file path
    (e.g. "hgext.convert.__init__") of `name`. This is used to look
    module up in `localmods` again.

    `hassubmod` is whether it may have sub modules under it (for
    convenient, even though this is also equivalent to "absname !=
    dottednpath")

    >>> localmods = {'foo.__init__', 'foo.foo1',
    ...              'foo.bar.__init__', 'foo.bar.bar1',
    ...              'baz.__init__', 'baz.baz1'}
    >>> fromlocal = fromlocalfunc('foo.xxx', localmods)
    >>> # relative
    >>> fromlocal('foo1')
    ('foo.foo1', 'foo.foo1', False)
    >>> fromlocal('bar')
    ('foo.bar', 'foo.bar.__init__', True)
    >>> fromlocal('bar.bar1')
    ('foo.bar.bar1', 'foo.bar.bar1', False)
    >>> # absolute
    >>> fromlocal('baz')
    ('baz', 'baz.__init__', True)
    >>> fromlocal('baz.baz1')
    ('baz.baz1', 'baz.baz1', False)
    >>> # unknown = maybe standard library
    >>> fromlocal('os')
    False
    >>> fromlocal(None, 1)
    ('foo', 'foo.__init__', True)
    >>> fromlocal('foo1', 1)
    ('foo.foo1', 'foo.foo1', False)
    >>> fromlocal2 = fromlocalfunc('foo.xxx.yyy', localmods)
    >>> fromlocal2(None, 2)
    ('foo', 'foo.__init__', True)
    >>> fromlocal2('bar2', 1)
    False
    >>> fromlocal2('bar', 2)
    ('foo.bar', 'foo.bar.__init__', True)
    """
    if not isinstance(modulename, str):
        modulename = modulename.decode('ascii')
    prefix = '.'.join(modulename.split('.')[:-1])
    if prefix:
        prefix += '.'

    def fromlocal(name, level=0):
        # name is false value when relative imports are used.
        if not name:
            # If relative imports are used, level must not be absolute.
            assert level > 0
            candidates = ['.'.join(modulename.split('.')[:-level])]
        else:
            if not level:
                # Check relative name first.
                candidates = [prefix + name, name]
            else:
                candidates = [
                    '.'.join(modulename.split('.')[:-level]) + '.' + name
                ]

        for n in candidates:
            if n in localmods:
                return (n, n, False)
            dottedpath = n + '.__init__'
            if dottedpath in localmods:
                return (n, dottedpath, True)
        return False

    return fromlocal


def populateextmods(localmods):
    """Populate C extension modules based on pure modules"""
    newlocalmods = set(localmods)
    for n in localmods:
        if n.startswith('mercurial.pure.'):
            m = n[len('mercurial.pure.') :]
            newlocalmods.add('mercurial.cext.' + m)
            newlocalmods.add('mercurial.cffi._' + m)
    return newlocalmods


def list_stdlib_modules():
    """List the modules present in the stdlib.

    >>> mods = set(list_stdlib_modules())
    >>> 'http' in mods
    True

    os.path isn't really a module, so it's missing:

    >>> 'os.path' in mods
    False

    sys requires special treatment, because it's baked into the
    interpreter, but it should still appear:

    >>> 'sys' in mods
    True

    >>> 'collections' in mods
    True

    >>> 'array' in mods
    True

    >>> 'cffi' in mods
    True
    """
    yield from sys.builtin_module_names
    # These modules only exist on windows, but we should always
    # consider them stdlib.
    yield from ['msvcrt', '_winreg']
    yield '__builtin__'
    yield 'builtins'  # python3 only
    yield 'importlib.abc'  # python3 only
    yield 'importlib.machinery'  # python3 only
    yield 'importlib.util'  # python3 only
    yield 'packaging.version'
    yield from ['fcntl', 'grp', 'pwd', 'select', 'termios']
    yield from ['cPickle', 'datetime']
    yield from ['cffi']
    stdlib_prefixes = {sys.prefix, sys.exec_prefix}
    # We need to supplement the list of prefixes for the search to work
    # when run from within a virtualenv.
    for mod in (argparse, zlib):
        if mod is None:
            continue
        try:
            # Not all module objects have a __file__ attribute.
            filename = mod.__file__
        except AttributeError:
            continue
        dirname = os.path.dirname(filename)
        for prefix in stdlib_prefixes:
            if dirname.startswith(prefix):
                # Then this directory is redundant.
                break
        else:
            stdlib_prefixes.add(dirname)
    sourceroot = os.path.abspath(os.path.dirname(os.path.dirname(__file__)))
    for libpath in sys.path:
        # We want to walk everything in sys.path that starts with something in
        # stdlib_prefixes, but not directories from the hg sources.
        if os.path.abspath(libpath).startswith(sourceroot) or not any(
            libpath.startswith(p) for p in stdlib_prefixes
        ):
            continue
        for top, dirs, files in os.walk(libpath):
            if 'dist-packages' in top.split(os.path.sep):
                continue
            for i, d in reversed(list(enumerate(dirs))):
                if (
                    not os.path.exists(os.path.join(top, d, '__init__.py'))
                    or top == libpath
                    and d in ('hgdemandimport', 'hgext', 'mercurial')
                ):
                    del dirs[i]
            for name in files:
                if not name.endswith(('.py', '.so', '.pyc', '.pyo', '.pyd')):
                    continue
                if name.startswith('__init__.py'):
                    full_path = top
                else:
                    full_path = os.path.join(top, name)
                rel_path = full_path[len(libpath) + 1 :]
                mod = dotted_name_of_path(rel_path)
                yield mod


stdlib_modules = set(list_stdlib_modules())


def imported_modules(source, modulename, f, localmods, ignore_nested=False):
    """Given the source of a file as a string, yield the names
    imported by that file.

    Args:
      source: The python source to examine as a string.
      modulename: of specified python source (may have `__init__`)
      localmods: set of locally defined module names (may have `__init__`)
      ignore_nested: If true, import statements that do not start in
                     column zero will be ignored.

    Returns:
      A list of absolute module names imported by the given source.

    >>> f = 'foo/xxx.py'
    >>> modulename = 'foo.xxx'
    >>> localmods = {'foo.__init__': True,
    ...              'foo.foo1': True, 'foo.foo2': True,
    ...              'foo.bar.__init__': True, 'foo.bar.bar1': True,
    ...              'baz.__init__': True, 'baz.baz1': True }
    >>> # standard library (= not locally defined ones)
    >>> sorted(imported_modules(
    ...        'from stdlib1 import foo, bar; import stdlib2',
    ...        modulename, f, localmods))
    []
    >>> # relative importing
    >>> sorted(imported_modules(
    ...        'import foo1; from bar import bar1',
    ...        modulename, f, localmods))
    ['foo.bar.bar1', 'foo.foo1']
    >>> sorted(imported_modules(
    ...        'from bar.bar1 import name1, name2, name3',
    ...        modulename, f, localmods))
    ['foo.bar.bar1']
    >>> # absolute importing
    >>> sorted(imported_modules(
    ...        'from baz import baz1, name1',
    ...        modulename, f, localmods))
    ['baz.__init__', 'baz.baz1']
    >>> # mixed importing, even though it shouldn't be recommended
    >>> sorted(imported_modules(
    ...        'import stdlib, foo1, baz',
    ...        modulename, f, localmods))
    ['baz.__init__', 'foo.foo1']
    >>> # ignore_nested
    >>> sorted(imported_modules(
    ... '''import foo
    ... def wat():
    ...     import bar
    ... ''', modulename, f, localmods))
    ['foo.__init__', 'foo.bar.__init__']
    >>> sorted(imported_modules(
    ... '''import foo
    ... def wat():
    ...     import bar
    ... ''', modulename, f, localmods, ignore_nested=True))
    ['foo.__init__']
    """
    fromlocal = fromlocalfunc(modulename, localmods)
    for node in ast.walk(ast.parse(source, f)):
        if ignore_nested and getattr(node, 'col_offset', 0) > 0:
            continue
        if isinstance(node, ast.Import):
            for n in node.names:
                found = fromlocal(n.name)
                if not found:
                    # this should import standard library
                    continue
                yield found[1]
        elif isinstance(node, ast.ImportFrom):
            found = fromlocal(node.module, node.level)
            if not found:
                # this should import standard library
                continue

            absname, dottedpath, hassubmod = found
            if not hassubmod:
                # "dottedpath" is not a package; must be imported
                yield dottedpath
                # examination of "node.names" should be redundant
                # e.g.: from mercurial.node import nullid, nullrev
                continue

            modnotfound = False
            prefix = absname + '.'
            for n in node.names:
                found = fromlocal(prefix + n.name)
                if not found:
                    # this should be a function or a property of "node.module"
                    modnotfound = True
                    continue
                yield found[1]
            if modnotfound and dottedpath != modulename:
                # "dottedpath" is a package, but imported because of non-module
                # lookup
                # specifically allow "from . import foo" from __init__.py
                yield dottedpath


def verify_import_convention(module, source, localmods):
    """Verify imports match our established coding convention."""
    root = ast.parse(source)

    return verify_modern_convention(module, root, localmods)


def verify_modern_convention(module, root, localmods, root_col_offset=0):
    """Verify a file conforms to the modern import convention rules.

    The rules of the modern convention are:

    * Ordering is stdlib followed by local imports. Each group is lexically
      sorted.
    * Importing multiple modules via "import X, Y" is not allowed: use
      separate import statements.
    * Importing multiple modules via "from X import ..." is allowed if using
      parenthesis and one entry per line.
    * Only 1 relative import statement per import level ("from .", "from ..")
      is allowed.
    * Relative imports from higher levels must occur before lower levels. e.g.
      "from .." must be before "from .".
    * Imports from peer packages should use relative import (e.g. do not
      "import mercurial.foo" from a "mercurial.*" module).
    * Symbols can only be imported from specific modules (see
      `allowsymbolimports`). For other modules, first import the module then
      assign the symbol to a module-level variable. In addition, these imports
      must be performed before other local imports. This rule only
      applies to import statements outside of any blocks.
    * Relative imports from the standard library are not allowed, unless that
      library is also a local module.
    * Certain modules must be aliased to alternate names to avoid aliasing
      and readability problems. See `requirealias`.
    """
    if not isinstance(module, str):
        module = module.decode('ascii')
    topmodule = module.split('.')[0]
    fromlocal = fromlocalfunc(module, localmods)

    # Whether a local/non-stdlib import has been performed.
    seenlocal = None
    # Whether a local/non-stdlib, non-symbol import has been seen.
    seennonsymbollocal = False
    # The last name to be imported (for sorting).
    lastname = None
    laststdlib = None
    # Relative import levels encountered so far.
    seenlevels = set()

    for node, newscope in walklocal(root):

        def msg(fmt, *args):
            return (fmt % args, node.lineno)

        if newscope:
            # Check for local imports in function
            yield from verify_modern_convention(
                module, node, localmods, node.col_offset + 4
            )
        elif isinstance(node, ast.Import):
            # Disallow "import foo, bar" and require separate imports
            # for each module.
            if len(node.names) > 1:
                yield msg(
                    'multiple imported names: %s',
                    ', '.join(n.name for n in node.names),
                )

            name = node.names[0].name
            asname = node.names[0].asname

            stdlib = name in stdlib_modules

            # Ignore sorting rules on imports inside blocks.
            if node.col_offset == root_col_offset:
                if lastname and name < lastname and laststdlib == stdlib:
                    yield msg(
                        'imports not lexically sorted: %s < %s', name, lastname
                    )

            lastname = name
            laststdlib = stdlib

            # stdlib imports should be before local imports.
            if stdlib and seenlocal and node.col_offset == root_col_offset:
                yield msg(
                    'stdlib import "%s" follows local import: %s',
                    name,
                    seenlocal,
                )

            if not stdlib:
                seenlocal = name

            # Import of sibling modules should use relative imports.
            topname = name.split('.')[0]
            if topname == topmodule:
                yield msg('import should be relative: %s', name)

            if name in requirealias and asname != requirealias[name]:
                yield msg(
                    '%s module must be "as" aliased to %s',
                    name,
                    requirealias[name],
                )

        elif isinstance(node, ast.ImportFrom):
            # Resolve the full imported module name.
            if node.level > 0:
                fullname = '.'.join(module.split('.')[: -node.level])
                if node.module:
                    fullname += '.%s' % node.module
            else:
                assert node.module
                fullname = node.module

                topname = fullname.split('.')[0]
                if topname == topmodule:
                    yield msg('import should be relative: %s', fullname)

            # __future__ is special since it needs to come first and use
            # symbol import.
            if fullname != '__future__':
                if not fullname or (
                    fullname in stdlib_modules
                    # allow standard 'from typing import ...' style
                    and fullname.startswith('.')
                    and fullname not in localmods
                    and fullname + '.__init__' not in localmods
                ):
                    yield msg('relative import of stdlib module')
                else:
                    seenlocal = fullname

            # Direct symbol import is only allowed from certain modules and
            # must occur before non-symbol imports.
            found = fromlocal(node.module, node.level)
            if found and found[2]:  # node.module is a package
                prefix = found[0] + '.'
                symbols = (
                    n.name for n in node.names if not fromlocal(prefix + n.name)
                )
            else:
                symbols = (n.name for n in node.names)
            symbols = [sym for sym in symbols if sym not in directsymbols]
            if node.module and node.col_offset == root_col_offset:
                if symbols and fullname not in allowsymbolimports:
                    yield msg(
                        'direct symbol import %s from %s',
                        ', '.join(symbols),
                        fullname,
                    )

                if symbols and seennonsymbollocal:
                    yield msg(
                        'symbol import follows non-symbol import: %s', fullname
                    )
            if not symbols and fullname not in stdlib_modules:
                seennonsymbollocal = True

            if not node.module:
                assert node.level

                # Only allow 1 group per level.
                if (
                    node.level in seenlevels
                    and node.col_offset == root_col_offset
                ):
                    yield msg(
                        'multiple "from %s import" statements', '.' * node.level
                    )

                # Higher-level groups come before lower-level groups.
                if any(node.level > l for l in seenlevels):
                    yield msg(
                        'higher-level import should come first: %s', fullname
                    )

                seenlevels.add(node.level)

            # Entries in "from .X import ( ... )" lists must be lexically
            # sorted.
            lastentryname = None

            for n in node.names:
                if lastentryname and n.name < lastentryname:
                    yield msg(
                        'imports from %s not lexically sorted: %s < %s',
                        fullname,
                        n.name,
                        lastentryname,
                    )

                lastentryname = n.name

                if n.name in requirealias and n.asname != requirealias[n.name]:
                    yield msg(
                        '%s from %s must be "as" aliased to %s',
                        n.name,
                        fullname,
                        requirealias[n.name],
                    )


class CircularImport(Exception):
    pass


def checkmod(mod, imports):
    shortest = {}
    visit = [[mod]]
    while visit:
        path = visit.pop(0)
        for i in sorted(imports.get(path[-1], [])):
            if len(path) < shortest.get(i, 1000):
                shortest[i] = len(path)
                if i in path:
                    if i == path[0]:
                        raise CircularImport(path)
                    continue
                visit.append(path + [i])


def rotatecycle(cycle):
    """arrange a cycle so that the lexicographically first module listed first

    >>> rotatecycle(['foo', 'bar'])
    ['bar', 'foo', 'bar']
    """
    lowest = min(cycle)
    idx = cycle.index(lowest)
    return cycle[idx:] + cycle[:idx] + [lowest]


def find_cycles(imports):
    """Find cycles in an already-loaded import graph.

    All module names recorded in `imports` should be absolute one.

    >>> imports = {'top.foo': ['top.bar', 'os.path', 'top.qux'],
    ...            'top.bar': ['top.baz', 'sys'],
    ...            'top.baz': ['top.foo'],
    ...            'top.qux': ['top.foo']}
    >>> print('\\n'.join(sorted(find_cycles(imports))))
    top.bar -> top.baz -> top.foo -> top.bar
    top.foo -> top.qux -> top.foo
    """
    cycles = set()
    for mod in sorted(imports.keys()):
        try:
            checkmod(mod, imports)
        except CircularImport as e:
            cycle = e.args[0]
            cycles.add(" -> ".join(rotatecycle(cycle)))
    return cycles


def _cycle_sortkey(c):
    return len(c), c


def embedded(f, modname, src):
    """Extract embedded python code

    >>> def _forcestr(thing):
    ...     if not isinstance(thing, str):
    ...         return thing.decode('ascii')
    ...     return thing
    >>> def test(fn, lines):
    ...     for s, m, f, l in embedded(fn, b"example", lines):
    ...         print("%s %s %d" % (_forcestr(m), _forcestr(f), l))
    ...         print(repr(_forcestr(s)))
    >>> lines = [
    ...   'comment',
    ...   '  >>> from __future__ import print_function',
    ...   "  >>> ' multiline",
    ...   "  ... string'",
    ...   '  ',
    ...   'comment',
    ...   '  $ cat > foo.py <<EOF',
    ...   '  > from __future__ import print_function',
    ...   '  > EOF',
    ... ]
    >>> test(b"example.t", lines)
    example[2] doctest.py 1
    "from __future__ import print_function\\n' multiline\\nstring'\\n\\n"
    example[8] foo.py 7
    'from __future__ import print_function\\n'
    """
    errors = []
    for name, starts, ends, code in testparseutil.pyembedded(f, src, errors):
        if not name:
            # use 'doctest.py', in order to make already existing
            # doctest above pass instantly
            name = 'doctest.py'
        # "starts" is "line number" (1-origin), but embedded() is
        # expected to return "line offset" (0-origin). Therefore, this
        # yields "starts - 1".
        if not isinstance(modname, str):
            modname = modname.decode('utf8')
        yield code, "%s[%d]" % (modname, starts), name, starts - 1


def sources(f, modname):
    """Yields possibly multiple sources from a filepath

    input: filepath, modulename
    yields:  script(string), modulename, filepath, linenumber

    For embedded scripts, the modulename and filepath will be different
    from the function arguments. linenumber is an offset relative to
    the input file.
    """
    py = False
    if not f.endswith('.t'):
        with open(f, 'rb') as src:
            yield src.read(), modname, f, 0
            py = True
    if py or f.endswith('.t'):
        # Strictly speaking we should sniff for the magic header that denotes
        # Python source file encoding. But in reality we don't use anything
        # other than ASCII (mainly) and UTF-8 (in a few exceptions), so
        # simplicity is fine.
        with open(f, encoding='utf-8') as src:
            for script, modname, t, line in embedded(f, modname, src):
                yield script, modname.encode('utf8'), t, line


def main(argv):
    if len(argv) < 2 or (argv[1] == '-' and len(argv) > 2):
        print('Usage: %s {-|file [file] [file] ...}')
        return 1
    if argv[1] == '-':
        argv = argv[:1]
        argv.extend(l.rstrip() for l in sys.stdin.readlines())
    localmodpaths = {}
    used_imports = {}
    any_errors = False
    for source_path in argv[1:]:
        modname = dotted_name_of_path(source_path)
        localmodpaths[modname] = source_path
    localmods = populateextmods(localmodpaths)
    for localmodname, source_path in sorted(localmodpaths.items()):
        if not isinstance(localmodname, bytes):
            # This is only safe because all hg's files are ascii
            localmodname = localmodname.encode('ascii')
        for src, modname, name, line in sources(source_path, localmodname):
            try:
                used_imports[modname] = sorted(
                    imported_modules(
                        src, modname, name, localmods, ignore_nested=True
                    )
                )
                for error, lineno in verify_import_convention(
                    modname, src, localmods
                ):
                    any_errors = True
                    print('%s:%d: %s' % (source_path, lineno + line, error))
            except SyntaxError as e:
                print(
                    '%s:%d: SyntaxError: %s' % (source_path, e.lineno + line, e)
                )
    cycles = find_cycles(used_imports)
    if cycles:
        firstmods = set()
        for c in sorted(cycles, key=_cycle_sortkey):
            first = c.split()[0]
            # As a rough cut, ignore any cycle that starts with the
            # same module as some other cycle. Otherwise we see lots
            # of cycles that are effectively duplicates.
            if first in firstmods:
                continue
            print('Import cycle:', c)
            firstmods.add(first)
        any_errors = True
    return any_errors != 0


if __name__ == '__main__':
    sys.exit(int(main(sys.argv)))
