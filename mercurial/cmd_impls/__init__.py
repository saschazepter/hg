# cmd_impls - utilities to implement commands
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This file import few modules on purpose. It should remains fairly neutral as
# any module it imports also become a dependencies for its sub modules.

from __future__ import annotations

import typing

from ..i18n import _
from .. import encoding


if typing.TYPE_CHECKING:
    CmdOptionsT = list[
        tuple[
            bytes,
            bytes,
            bool | bytes | None | list,
            bytes,
        ]
        | tuple[
            bytes,
            bytes,
            bool | bytes | None | list,
            bytes,
            bytes,
        ]
    ]

# command options common to all commands
global_opts: CmdOptionsT = [
    (
        b'R',
        b'repository',
        b'',
        _(b'repository root directory or name of overlay bundle file'),
        _(b'REPO'),
    ),
    (b'', b'cwd', b'', _(b'change working directory'), _(b'DIR')),
    (
        b'y',
        b'noninteractive',
        None,
        _(
            b'do not prompt, automatically pick the first choice for all prompts'
        ),
    ),
    (b'q', b'quiet', None, _(b'suppress output')),
    (b'v', b'verbose', None, _(b'enable additional output')),
    (
        b'',
        b'color',
        b'',
        # i18n: 'always', 'auto', 'never', and 'debug' are keywords
        # and should not be translated
        _(b"when to colorize (boolean, always, auto, never, or debug)"),
        _(b'TYPE'),
    ),
    (
        b'',
        b'config',
        [],
        _(b'set/override config option (use \'section.name=value\')'),
        _(b'CONFIG'),
    ),
    (
        b'',
        b'config-file',
        [],
        _(b'load config file to set/override config options'),
        _(b'HGRC'),
    ),
    (b'', b'debug', None, _(b'enable debugging output')),
    (b'', b'debugger', None, _(b'start debugger')),
    (
        b'',
        b'encoding',
        encoding.encoding,
        _(b'set the charset encoding'),
        _(b'ENCODE'),
    ),
    (
        b'',
        b'encodingmode',
        encoding.encodingmode,
        _(b'set the charset encoding mode'),
        _(b'MODE'),
    ),
    (b'', b'traceback', None, _(b'always print a traceback on exception')),
    (b'', b'time', None, _(b'time how long the command takes')),
    (b'', b'profile', None, _(b'print command execution profile')),
    (b'', b'version', None, _(b'output version information and exit')),
    (b'h', b'help', None, _(b'display help and exit')),
    (b'', b'hidden', False, _(b'consider hidden changesets')),
    (
        b'',
        b'pager',
        b'auto',
        _(b"when to paginate (boolean, always, auto, or never)"),
        _(b'TYPE'),
    ),
]

# templates of common command options

dry_run_opts: CmdOptionsT = [
    (b'n', b'dry-run', None, _(b'do not perform actions, just print output')),
]

confirm_opts: CmdOptionsT = [
    (b'', b'confirm', None, _(b'ask before applying actions')),
]

remote_opts: CmdOptionsT = [
    (b'e', b'ssh', b'', _(b'specify ssh command to use'), _(b'CMD')),
    (
        b'',
        b'remotecmd',
        b'',
        _(b'specify hg command to run on the remote side'),
        _(b'CMD'),
    ),
    (
        b'',
        b'insecure',
        None,
        _(b'do not verify server certificate (ignoring web.cacerts config)'),
    ),
]

walk_opts: CmdOptionsT = [
    (
        b'I',
        b'include',
        [],
        _(b'include names matching the given patterns'),
        _(b'PATTERN'),
    ),
    (
        b'X',
        b'exclude',
        [],
        _(b'exclude names matching the given patterns'),
        _(b'PATTERN'),
    ),
]

commit_opts: CmdOptionsT = [
    (b'm', b'message', b'', _(b'use text as commit message'), _(b'TEXT')),
    (b'l', b'logfile', b'', _(b'read commit message from file'), _(b'FILE')),
]

commit_opts2: CmdOptionsT = [
    (
        b'd',
        b'date',
        b'',
        _(b'record the specified date as commit date'),
        _(b'DATE'),
    ),
    (
        b'u',
        b'user',
        b'',
        _(b'record the specified user as committer'),
        _(b'USER'),
    ),
]

commit_opts3: CmdOptionsT = [
    (b'D', b'currentdate', None, _(b'record the current date as commit date')),
    (b'U', b'currentuser', None, _(b'record the current user as committer')),
]

formatter_opts: CmdOptionsT = [
    (b'T', b'template', b'', _(b'display with template'), _(b'TEMPLATE')),
]

template_opts: CmdOptionsT = [
    (
        b'',
        b'style',
        b'',
        _(b'display using template map file (DEPRECATED)'),
        _(b'STYLE'),
    ),
    (b'T', b'template', b'', _(b'display with template'), _(b'TEMPLATE')),
]

log_opts: CmdOptionsT = [
    (b'p', b'patch', None, _(b'show patch')),
    (b'g', b'git', None, _(b'use git extended diff format')),
    (b'l', b'limit', b'', _(b'limit number of changes displayed'), _(b'NUM')),
    (b'M', b'no-merges', None, _(b'do not show merges')),
    (b'', b'stat', None, _(b'output diffstat-style summary of changes')),
    (b'G', b'graph', None, _(b"show the revision DAG")),
] + template_opts

diff_opts: CmdOptionsT = [
    (b'a', b'text', None, _(b'treat all files as text')),
    (
        b'g',
        b'git',
        None,
        _(b'use git extended diff format (DEFAULT: diff.git)'),
    ),
    (b'', b'binary', None, _(b'generate binary diffs in git mode (default)')),
    (b'', b'nodates', None, _(b'omit dates from diff headers')),
]

diff_ws_opts: CmdOptionsT = [
    (
        b'w',
        b'ignore-all-space',
        None,
        _(b'ignore white space when comparing lines'),
    ),
    (
        b'b',
        b'ignore-space-change',
        None,
        _(b'ignore changes in the amount of white space'),
    ),
    (
        b'B',
        b'ignore-blank-lines',
        None,
        _(b'ignore changes whose lines are all blank'),
    ),
    (
        b'Z',
        b'ignore-space-at-eol',
        None,
        _(b'ignore changes in whitespace at EOL'),
    ),
]

diff_opts2: CmdOptionsT = (
    [
        (b'', b'noprefix', None, _(b'omit a/ and b/ prefixes from filenames')),
        (
            b'p',
            b'show-function',
            None,
            _(
                b'show which function each change is in (DEFAULT: diff.showfunc)'
            ),
        ),
        (b'', b'reverse', None, _(b'produce a diff that undoes the changes')),
    ]
    + diff_ws_opts
    + [
        (
            b'U',
            b'unified',
            b'',
            _(b'number of lines of context to show'),
            _(b'NUM'),
        ),
        (b'', b'stat', None, _(b'output diffstat-style summary of changes')),
        (
            b'',
            b'root',
            b'',
            _(b'produce diffs relative to subdirectory'),
            _(b'DIR'),
        ),
    ]
)

merge_tool_opts: CmdOptionsT = [
    (b't', b'tool', b'', _(b'specify merge tool'), _(b'TOOL')),
]

similarity_opts: CmdOptionsT = [
    (
        b's',
        b'similarity',
        b'',
        _(b'guess renamed files by similarity (0<=s<=100)'),
        _(b'SIMILARITY'),
    )
]

subrepo_opts: CmdOptionsT = [
    (b'S', b'subrepos', None, _(b'recurse into subrepositories')),
]

debug_revlog_opts: CmdOptionsT = [
    (b'c', b'changelog', False, _(b'open changelog')),
    (b'm', b'manifest', False, _(b'open manifest')),
    (b'', b'dir', b'', _(b'open directory manifest')),
]
