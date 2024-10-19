# Gather code related to command dealing with configuration.

from __future__ import annotations

import os

from typing import Any, Collection, TYPE_CHECKING

from ..i18n import _
from ..interfaces.types import (
    RepoT,
    VfsT,
)

from .. import (
    cmdutil,
    config as configmod,
    error,
    formatter,
    lock as lockmod,
    pycompat,
    requirements,
    ui as uimod,
    util,
    vfs as vfsmod,
)

from . import (
    ConfigLevelT,
    EDIT_LEVELS,
    LEVEL_SHARED,
    NO_REPO_EDIT_LEVELS,
    rcutil,
)

EDIT_FLAG = 'edit'

if TYPE_CHECKING:
    ConfigSpecT = tuple[bytes, bytes, bytes]


def find_edit_level(
    ui: uimod.ui,
    repo,
    opts: dict[str, Any],
) -> ConfigLevelT | None:
    """return the level we should edit, if any.

    Parse the command option to detect when an edit is requested, and if so the
    configuration level we should edit.
    """
    if opts.get(EDIT_FLAG) or any(opts.get(o) for o in EDIT_LEVELS):
        cmdutil.check_at_most_one_arg(opts, *EDIT_LEVELS)
        for level in EDIT_LEVELS:
            if opts.get(level):
                return level
        return EDIT_LEVELS[0]
    return None


def _files_by_level(repo) -> dict[ConfigLevelT, list[bytes]]:
    """Find all config files used in the current environment

    The file paths of all these files are returned in a dict, grouped by
    configuration level.

    This is used to find the file to be editing by level.
    """
    repo_path = None
    if repo is not None:
        repo_path = repo.root
    all_rcs = rcutil.all_rc_components(repo_path)
    rc_by_level = {}
    for lvl, rc_type, value in all_rcs:
        if rc_type != b'path':
            continue
        assert isinstance(value, bytes)
        rc_by_level.setdefault(lvl, []).append(value)
    return rc_by_level


# machine writes go to "<hgrc><-suffix>[.<ext>]"
MANAGED_SUFFIX = b'-managed'

# edits are covered by a lock file in the same dir as the file we edit.
CONFIG_LOCK_NAME = b'config.lock'

_MANAGED_HEADER = (
    b"# This file is managed by Mercurial, do not edit it by hand.\n"
    b"# Use `hg config --set` to change the values it holds.\n"
)


def parse_config_args(values: Collection[bytes]) -> Collection[ConfigSpecT]:
    configs = []
    for value_spec in values:
        try:
            configs.append(configmod.parse_single_arg(value_spec))
        except ValueError:
            msg = _(b'malformed --set option: \'%s\'')
            hint = _(b'use --set section.name=value')
            raise error.InputError(msg % value_spec, hint=hint)
    return configs


def _target_by_level(
    repo: RepoT,
    level: ConfigLevelT,
) -> tuple[VfsT, bytes, bytes,]:
    """return the vfs, and base file name and the managed file name

    create the associated directory if needed
    """
    rc_by_level = _files_by_level(repo)
    level_files = rc_by_level.get(level)
    if not level_files:
        # every platform is expected to provide a user-level config file
        # location, so this is mostly a safety net
        msg = _(
            b'no "%s" configuration file location known'
            % pycompat.bytestr(level)
        )
        raise error.Abort(msg)

    base_file = level_files[0]
    directory = os.path.dirname(base_file)
    assert directory
    if not os.path.isdir(directory):
        util.makedirs(directory)
    base_file = os.path.basename(base_file)
    core, ext = os.path.splitext(base_file)
    managed = core + MANAGED_SUFFIX + ext
    return (
        vfsmod.vfs(directory),
        base_file,
        managed,
    )


def set_config(
    ui: uimod.ui,
    repo,
    values: Collection[ConfigSpecT],
    level: ConfigLevelT,
) -> int:
    """persist ``section.key=value`` to the managed configuration

    Values are stored in a machine-managed companion file so the file the user
    edits by hand is never rewritten, and its content always wins.
    """

    timeout = ui.configint(b'ui', b'timeout')
    warntimeout = ui.configint(b'ui', b'timeout.warn')
    vfs, base_file, managed_file = _target_by_level(repo, level)
    # grab some lock so concurrent `--set` don't clobber each other's writes.
    with lockmod.trylock(
        ui,
        vfs,
        CONFIG_LOCK_NAME,
        timeout,
        warntimeout,
        desc=_(b'config update for %s') % base_file,
    ):
        # write the new values in the machine-managed file…
        cfg = configmod.config()
        managed_content = vfs.tryread(managed_file)
        if managed_content:
            cfg.parse(b'<managed>', managed_content)
        for section, key, value in values:
            cfg.set(section, key, value)
        managed_content = _MANAGED_HEADER + cfg.serialize()
        vfs.write(managed_file, managed_content, atomictemp=True)

        # … and make sure the base file pulls it in.
        base_content = vfs.tryread(base_file)
        new_content = _inject_managed_include(base_content, managed_file)
        if new_content != base_content:
            vfs.write(base_file, new_content, atomictemp=True)
    return 0


def _inject_managed_include(base_content: bytes, target: bytes) -> bytes:
    """return `base_content` with a single `%include` of `target` on top

    The include must stay the first line. Manually set value always wins.

    >>> _inject_managed_include(b'[ui]\\nusername = Foo\\n', b'.hgrc.managed')
    b'%include .hgrc.managed\\n[ui]\\nusername = Foo\\n'
    >>> _inject_managed_include(b'%include .hgrc.managed\\n', b'.hgrc.managed')
    b'%include .hgrc.managed\\n'
    >>> _inject_managed_include(b'no newline', b'.hgrc.managed')
    b'%include .hgrc.managed\\nno newline\\n'
    >>> _inject_managed_include(
    ...     b'[ui]\\nusername = Foo\\n%include .hgrc.managed\\n',
    ...     b'.hgrc.managed',
    ... )
    b'%include .hgrc.managed\\n[ui]\\nusername = Foo\\n'
    """
    # `%include` is resolved relative to the including file, and both files
    # live in the same directory, so a bare basename is enough (and stays
    # valid if the configuration directory is moved around).
    include_line = b"%%include %s" % target
    lines = base_content.splitlines(True)
    if lines and lines[0].rstrip() == include_line:
        # already included first, nothing to do
        return base_content
    # drop any occurrence further down before re-inserting it at the top
    lines = [l for l in lines if l.rstrip() != include_line]
    base_content = b"".join(lines)
    if base_content and not base_content.endswith(b'\n'):
        base_content += b'\n'
    return include_line + b"\n" + base_content


def edit_config(ui: uimod.ui, repo, level: ConfigLevelT) -> None:
    """let the user edit configuration file for the given level"""

    # validate input
    if repo is None and level not in NO_REPO_EDIT_LEVELS:
        msg = b"can't use --%s outside a repository" % pycompat.bytestr(level)
        raise error.InputError(_(msg))
    if level == LEVEL_SHARED:
        if not repo.shared():
            msg = _(b"repository is not shared; can't use --shared")
            raise error.InputError(msg)
        if requirements.SHARESAFE_REQUIREMENT not in repo.requirements:
            raise error.InputError(
                _(
                    b"share safe feature not enabled; "
                    b"unable to edit shared source repository config"
                )
            )

    rc_by_level = _files_by_level(repo)

    if level not in rc_by_level:
        msg = 'unknown config level: %s' % level
        raise error.ProgrammingError(msg)

    paths = rc_by_level[level]
    for f in paths:
        if os.path.exists(f):
            break
    else:
        samplehgrc = uimod.samplehgrcs.get(level)

        f = paths[0]
        if samplehgrc is not None:
            util.writefile(f, util.tonativeeol(samplehgrc))

    editor = ui.geteditor()
    ui.system(
        b"%s \"%s\"" % (editor, f),
        onerr=error.InputError,
        errprefix=_(b"edit failed"),
        blockedtag=b'config_edit',
    )


def show_component(ui: uimod.ui, repo) -> None:
    """show the component used to build the config"""
    repo_root = None
    if repo is not None:
        repo_root = repo.root
    for _lvl, t, f in rcutil.all_rc_components(repo_root, use_hgrcpath=True):
        if t == b'path':
            ui.debug(b'read config from: %s\n' % f)
        elif t == b'resource':
            ui.debug(b'read config from: resource:%s.%s\n' % (f[0], f[1]))
        elif t == b'items':
            # Don't print anything for 'items'.
            pass
        else:
            raise error.ProgrammingError(b'unknown rctype: %s' % t)


def show_config(
    ui: uimod.ui,
    repo,
    value_filters: Collection[bytes],
    formatter_options: dict,
    untrusted: bool = False,
    all_known: bool = False,
    show_source: bool = False,
) -> bool:
    """Display config value to the user

    The display is done using a dedicated `formatter` object.


    :value_filters:
        if non-empty filter the display value according to these filters. If
        the filter does not match any value, the function return False. True
        otherwise.

    :formatter_option:
        options passed to the formatter

    :untrusted:
        When set, use untrusted value instead of ignoring them

    :all_known:
        Display all known config item, not just the one with an explicit value.

    :show_source:
        Show where each value has been defined.
    """
    fm = ui.formatter(b'config', formatter_options)
    selsections = selentries = []
    filtered = False
    if value_filters:
        selsections = [v for v in value_filters if b'.' not in v]
        selentries = [v for v in value_filters if b'.' in v]
        filtered = True
    uniquesel = len(selentries) == 1 and not selsections
    selsections = set(selsections)
    selentries = set(selentries)

    matched = False
    entries = ui.walkconfig(untrusted=untrusted, all_known=all_known)
    for section, name, value in entries:
        source = ui.configsource(section, name, untrusted)
        value = pycompat.bytestr(value)
        defaultvalue = ui.configdefault(section, name)
        if fm.isplain():
            source = source or b'none'
            value = value.replace(b'\n', b'\\n')
        entryname = section + b'.' + name
        if filtered and not (section in selsections or entryname in selentries):
            continue
        fm.startitem()
        fm.condwrite(show_source, b'source', b'%s: ', source)
        if uniquesel:
            fm.data(name=entryname)
            fm.write(b'value', b'%s\n', value)
        else:
            fm.write(b'name value', b'%s=%s\n', entryname, value)
        if formatter.isprintable(defaultvalue):
            fm.data(defaultvalue=defaultvalue)
        elif isinstance(defaultvalue, list) and all(
            formatter.isprintable(e) for e in defaultvalue
        ):
            fm.data(defaultvalue=fm.formatlist(defaultvalue, name=b'value'))
        # TODO: no idea how to process unsupported defaultvalue types
        matched = True
    fm.end()
    return matched
