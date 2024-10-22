# Gather code related to command dealing with configuration.

from __future__ import annotations

import os

from typing import Any, Collection, Dict, Optional

from ..i18n import _

from .. import (
    cmdutil,
    error,
    formatter,
    pycompat,
    requirements,
    ui as uimod,
    util,
    vfs as vfsmod,
)

from . import (
    ConfigLevelT,
    EDIT_LEVELS,
    LEVEL_GLOBAL,
    LEVEL_LOCAL,
    LEVEL_NON_SHARED,
    LEVEL_SHARED,
    LEVEL_USER,
    rcutil,
)

EDIT_FLAG = 'edit'


def find_edit_level(
    ui: uimod.ui,
    repo,
    opts: Dict[str, Any],
) -> Optional[ConfigLevelT]:
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


def edit_config(ui: uimod.ui, repo, level: ConfigLevelT) -> None:
    """let the user edit configuration file for the given level"""

    if level == LEVEL_USER:
        paths = rcutil.userrcpath()
    elif level == LEVEL_GLOBAL:
        paths = rcutil.systemrcpath()
    elif level == LEVEL_LOCAL:
        if not repo:
            raise error.InputError(_(b"can't use --local outside a repository"))
        paths = [repo.vfs.join(b'hgrc')]
    elif level == LEVEL_NON_SHARED:
        paths = [repo.vfs.join(b'hgrc-not-shared')]
    elif level == LEVEL_SHARED:
        if not repo.shared():
            raise error.InputError(
                _(b"repository is not shared; can't use --shared")
            )
        if requirements.SHARESAFE_REQUIREMENT not in repo.requirements:
            raise error.InputError(
                _(
                    b"share safe feature not enabled; "
                    b"unable to edit shared source repository config"
                )
            )
        paths = [vfsmod.vfs(repo.sharedpath).join(b'hgrc')]
    else:
        msg = 'unknown config level: %s' % level
        raise error.ProgrammingError(msg)

    for f in paths:
        if os.path.exists(f):
            break
    else:
        if LEVEL_GLOBAL:
            samplehgrc = uimod.samplehgrcs[b'global']
        elif LEVEL_LOCAL:
            samplehgrc = uimod.samplehgrcs[b'local']
        else:
            samplehgrc = uimod.samplehgrcs[b'user']

        f = paths[0]
        util.writefile(f, util.tonativeeol(samplehgrc))

    editor = ui.geteditor()
    ui.system(
        b"%s \"%s\"" % (editor, f),
        onerr=error.InputError,
        errprefix=_(b"edit failed"),
        blockedtag=b'config_edit',
    )


def show_component(ui: uimod.ui, repo) -> None:
    """show the component used to build the config

    XXX this skip over various source and ignore the repository config, so it
    XXX is probably useless old code.
    """
    for t, f in rcutil.rccomponents():
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
