# Gather code related to command dealing with configuration.

from __future__ import annotations

import os

from typing import Any, Collection

from ..i18n import _
from ..interfaces.types import (
    HgPathT,
    RepoT,
    VfsT,
)

from .. import (
    cmdutil,
    config as configmod,
    error,
    formatter,
    pycompat,
    requirements,
    ui as uimod,
    util,
    vfs as vfsmod,
)

from . import (
    ConfigKeyT,
    ConfigLevelT,
    ConfigSpecT,
    EDIT_LEVELS,
    LEVEL_GLOBAL,
    LEVEL_LOCAL,
    LEVEL_NON_SHARED,
    LEVEL_SHARED,
    NO_REPO_EDIT_LEVELS,
    SHADOW,
    Shadowing,
    managed,
    rcutil,
)

EDIT_FLAG = 'edit'


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


def parse_config_keys(values: Collection[bytes]) -> Collection[ConfigKeyT]:
    keys = []
    for key_spec in values:
        try:
            keys.append(configmod.parse_single_key(key_spec))
        except ValueError:
            msg = _(b'malformed --del option: \'%s\'')
            hint = _(b'use --del section.name')
            raise error.InputError(msg % key_spec, hint=hint)
    return keys


def _target_by_level(
    repo: RepoT,
    level: ConfigLevelT,
) -> tuple[VfsT, HgPathT, HgPathT]:
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
    return (
        vfsmod.vfs(directory),
        base_file,
        managed.sibling(base_file),
    )


def _higher_level_boundaries(
    repo,
    level: ConfigLevelT,
) -> list[tuple[ConfigLevelT, bytes]]:
    """each configuration level read after `level`, with its first file

    In read order. A definition from one of these files, or from anything
    read after it, belongs to that higher configuration level, where
    overriding the value we write is legitimate.
    """
    repo_path = None
    if repo is not None:
        repo_path = repo.root
    boundaries = []
    seen = set()
    passed_level = False
    for lvl, rc_type, value in rcutil.all_rc_components(repo_path):
        if lvl == level:
            passed_level = True
        elif passed_level and rc_type == b'path' and lvl not in seen:
            assert isinstance(value, bytes)
            seen.add(lvl)
            boundaries.append((lvl, value))
    return boundaries


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

    vfs, base_file, managed_file = _target_by_level(repo, level)
    managed.write_values(ui, vfs, base_file, values)

    # reflect the new values in the configuration we already loaded, for
    # whatever runs later in this process (hooks, extensions, …)
    managed_path = os.path.normpath(vfs.join(managed_file))
    base_path = os.path.normpath(vfs.join(base_file))
    low_ui = None
    root = os.path.expanduser(b'~')
    if repo is not None:
        assert repo.ui is ui
        if level in NO_REPO_EDIT_LEVELS:
            # the ui that ignores repository files also read that file
            low_ui = repo.baseui
        else:
            # only the repository ui reads repository level files
            #
            # `repo.root` is right for LEVEL_SHARED too: the first read of the
            # shared file, in `main_script.paths`, uses the share root, and
            # relative paths keep the root of their first read.
            root = repo.root

    boundaries = _higher_level_boundaries(repo, level)
    for section, key, value in values:
        shadowing = ui.register_config_write(
            section,
            key,
            value,
            managed_path,
            base_path,
            root=root,
            higher_level_boundaries=boundaries,
        )
        if low_ui is not None:
            low_ui.register_config_write(
                section,
                key,
                value,
                managed_path,
                base_path,
                root=root,
                higher_level_boundaries=boundaries,
            )
        _report_if_shadowed(ui, section, key, value, shadowing)
    return 0


def delete_config(
    ui: uimod.ui,
    repo,
    keys: Collection[ConfigKeyT],
    level: ConfigLevelT,
) -> int:
    """drop ``section.key`` from the managed configuration

    Only the managed value is dropped, so a definition the user wrote by
    hand, or one coming from another configuration level, is left alone and
    still applies.
    """

    vfs, base_file, managed_file = _target_by_level(repo, level)
    dropped = managed.drop_values(ui, vfs, base_file, keys)

    managed_path = os.path.normpath(vfs.join(managed_file))
    base_path = os.path.normpath(vfs.join(base_file))
    boundaries = _higher_level_boundaries(repo, level)
    missing = False
    for section, key in keys:
        if (section, key) not in dropped:
            # Nothing to delete is not a failure, `--del` got us where the
            # user asked to be, so this is only worth a note. The definition
            # in use is still reported below: it would have hidden a managed
            # value too, so it is what the user has to deal with.
            missing = True
            if not ui.quiet:
                msg = _(b"note: no managed value for '%s.%s'\n")
                ui.warn(msg % (section, key))
        shadowing = ui.find_config_write_shadow(
            section,
            key,
            managed_path,
            base_path,
            higher_level_boundaries=boundaries,
        )
        # no value of ours is in play any more, hence the None
        _report_if_shadowed(ui, section, key, None, shadowing)
    # the file we looked into is named once, after all of them
    if missing and not ui.quiet:
        ui.warn(_(b"(nothing to delete in %s)\n") % managed_path)
    return 0


# the `hg config` flag acting at a given configuration level
#
# the user level is the default one and has no flag of its own.
_LEVEL_FLAGS: dict[ConfigLevelT, bytes] = {
    LEVEL_GLOBAL: b'--global',
    LEVEL_LOCAL: b'--local',
    LEVEL_SHARED: b'--shared',
    LEVEL_NON_SHARED: b'--non-shared',
}


def _report_if_shadowed(
    ui: uimod.ui,
    section: bytes,
    key: bytes,
    value: bytes | None,
    shadowing: Shadowing | None,
) -> None:
    """tell the user when the value we just wrote is not the one in use

    This is a sub section of `set_config` extracted for readability.

    `value` is the value we wrote, or None when we dropped one instead. The
    two cases are reported the same way, only the wording differs.

    A definition from a higher configuration level legitimately wins over
    what we just wrote, so it only gets a note pointing at the flag that
    writes at that level. A command line override only gets a mention at
    debug level, it goes away with the command.
    """
    if shadowing is None or ui.quiet:
        return
    if value is None:
        # we dropped our value, so the item keeps the definition that was
        # hiding it, and the user sees no change at all.
        shadow_msg = _(b"'%s.%s' is still defined by %s\n")
        level_hint = _(b"(use %s to delete '%s.%s' at that level)\n")
        env_hint = _(b"(unset %s to use --del on '%s.%s')\n")
        manual_hint = _(b"(clean your manual config to drop '%s.%s')\n")
    else:
        shadow_msg = _(b"new value for '%s.%s' is shadowed by %s\n")
        level_hint = _(b"(use %s to set '%s.%s' at that level)\n")
        env_hint = _(b"(unset %s to use --set on '%s.%s')\n")
        manual_hint = _(b"(clean your manual config to use --set on '%s.%s')\n")
    shadow_msg %= (section, key, shadowing.source)
    if shadowing.status is SHADOW.OVERRIDE:
        # the override goes away with the command, so this is not worth a
        # warning, just a mention for whoever debugs the configuration.
        ui.debug(shadow_msg)
        return
    if shadowing.status is SHADOW.HIGHER_LEVEL:
        # softer than a warning, but still a message about the command we
        # just ran, so it goes to stderr like the others.
        ui.warn(_(b"note: %s") % shadow_msg)
        flag = _LEVEL_FLAGS.get(shadowing.config_level)
        if flag is not None:
            ui.warn(level_hint % (flag, section, key))
        return
    if shadowing.value == value:
        # the user sees the value they asked for, so this is not worth a
        # warning, just a mention for whoever debugs the configuration.
        ui.debug(shadow_msg)
        return
    ui.warn(_(b"warning: %s") % shadow_msg)
    if shadowing.status is SHADOW.ENVIRONMENT:
        ui.warn(env_hint % (shadowing.source, section, key))
    else:
        assert shadowing.status is SHADOW.SAME_LEVEL
        ui.warn(manual_hint % (section, key))


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
