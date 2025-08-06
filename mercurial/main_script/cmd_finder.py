# cmd_finder - utilities to find a command
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations


from .. import error


def parse_aliases(cmd):
    base_aliases = cmd.split(b"|")
    all_aliases = set(base_aliases)
    extra_aliases = []
    for alias in base_aliases:
        if b'-' in alias:
            folded_alias = alias.replace(b'-', b'')
            if folded_alias not in all_aliases:
                all_aliases.add(folded_alias)
                extra_aliases.append(folded_alias)
    base_aliases.extend(extra_aliases)
    return base_aliases


def find_possible(cmd, table, strict=False):
    """
    Return cmd -> (aliases, command table entry)
    for each matching command.
    Return debug commands (or their aliases) only if no normal command matches.
    """
    choice = {}
    debugchoice = {}

    if cmd in table:
        # short-circuit exact matches, "log" alias beats "log|history"
        keys = [cmd]
    else:
        keys = table.keys()

    allcmds = []
    for e in keys:
        aliases = parse_aliases(e)
        allcmds.extend(aliases)
        found = None
        if cmd in aliases:
            found = cmd
        elif not strict:
            for a in aliases:
                if a.startswith(cmd):
                    found = a
                    break
        if found is not None:
            if aliases[0].startswith(b"debug") or found.startswith(b"debug"):
                debugchoice[found] = (aliases, table[e])
            else:
                choice[found] = (aliases, table[e])

    if not choice and debugchoice:
        choice = debugchoice

    return choice, allcmds


def find_cmd(cmd, table, strict=True):
    """Return (aliases, command table entry) for command string."""
    choice, allcmds = find_possible(cmd, table, strict)

    if cmd in choice:
        return choice[cmd]

    if len(choice) > 1:
        clist = sorted(choice)
        raise error.AmbiguousCommand(cmd, clist)

    if choice:
        return list(choice.values())[0]

    raise error.UnknownCommand(cmd, allcmds)
