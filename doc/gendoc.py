#!/usr/bin/env python3
"""usage: %s DOC ...

where DOC is the name of a document
"""


import os
import sys
import textwrap
import argparse

try:
    import msvcrt

    msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
    msvcrt.setmode(sys.stderr.fileno(), os.O_BINARY)
except ImportError:
    pass

# This script is executed during installs and may not have C extensions
# available. Relax C module requirements.
os.environ['HGMODULEPOLICY'] = 'allow'
# import from the live mercurial repo
sys.path.insert(0, os.path.abspath(".."))
from mercurial import demandimport

demandimport.enable()

from mercurial import (
    commands,
    encoding,
    extensions,
    fancyopts,
    help,
    minirst,
    pycompat,
    ui as uimod,
)
from mercurial.i18n import (
    gettext,
    _,
)
from mercurial.utils import stringutil

table = commands.table
globalopts = commands.globalopts
helptable = help.helptable
loaddoc = help.loaddoc


def get_desc(docstr):
    if not docstr:
        return b"", b""
    # sanitize
    docstr = docstr.strip(b"\n")
    docstr = docstr.rstrip()
    shortdesc = docstr.splitlines()[0].strip()

    i = docstr.find(b"\n")
    if i != -1:
        desc = docstr[i + 2 :]
    else:
        desc = shortdesc

    desc = textwrap.dedent(desc.decode('latin1')).encode('latin1')

    return (shortdesc, desc)


def get_opts(opts):
    for opt in opts:
        if len(opt) == 5:
            shortopt, longopt, default, desc, optlabel = opt
        else:
            shortopt, longopt, default, desc = opt
            optlabel = _(b"VALUE")
        allopts = []
        if shortopt:
            allopts.append(b"-%s" % shortopt)
        if longopt:
            allopts.append(b"--%s" % longopt)
        if isinstance(default, list):
            allopts[-1] += b" <%s[+]>" % optlabel
        elif (default is not None) and not isinstance(default, bool):
            allopts[-1] += b" <%s>" % optlabel
        if b'\n' in desc:
            # only remove line breaks and indentation
            desc = b' '.join(l.lstrip() for l in desc.split(b'\n'))
        if isinstance(default, fancyopts.customopt):
            default = default.getdefaultvalue()
        if default:
            default = stringutil.forcebytestr(default)
            desc += _(b" (default: %s)") % default
        yield (b", ".join(allopts), desc)


def get_cmd(cmd, cmdtable):
    d = {}
    attr = cmdtable[cmd]
    cmds = cmd.lstrip(b"^").split(b"|")

    d[b'cmd'] = cmds[0]
    d[b'aliases'] = cmd.split(b"|")[1:]
    d[b'desc'] = get_desc(gettext(pycompat.getdoc(attr[0])))
    d[b'opts'] = list(get_opts(attr[1]))

    s = b'hg ' + cmds[0]
    if len(attr) > 2:
        if not attr[2].startswith(b'hg'):
            s += b' ' + attr[2]
        else:
            s = attr[2]
    d[b'synopsis'] = s.strip()

    return d


def showdoc(ui, debugcmds=False):
    # print options
    ui.write(minirst.section(_(b"Options")))
    multioccur = False
    for optstr, desc in get_opts(globalopts):
        ui.write(b"%s\n    %s\n\n" % (optstr, desc))
        if optstr.endswith(b"[+]>"):
            multioccur = True
    if multioccur:
        ui.write(_(b"\n[+] marked option can be specified multiple times\n"))
        ui.write(b"\n")

    # print cmds
    ui.write(minirst.section(_(b"Commands")))
    commandprinter(
        ui,
        table,
        minirst.subsection,
        minirst.subsubsection,
        debugcmds=debugcmds,
    )

    # print help topics
    # The config help topic is included in the hgrc.5 man page.
    topics = findtopics(helptable, exclude=[b'config'])
    helpprinter(ui, topics, minirst.section)

    ui.write(minirst.section(_(b"Extensions")))
    ui.write(
        _(
            b"This section contains help for extensions that are "
            b"distributed together with Mercurial. Help for other "
            b"extensions is available in the help system."
        )
    )
    ui.writenoi18n(
        b"\n\n"
        b".. contents::\n"
        b"   :class: htmlonly\n"
        b"   :local:\n"
        b"   :depth: 1\n\n"
    )

    for extensionname in sorted(allextensionnames()):
        mod = extensions.load(ui, extensionname, None)
        ui.write(minirst.subsection(extensionname))
        ext_doc = help.ext_help(ui, mod)
        ui.write(b"%s\n\n" % ext_doc)
        cmdtable = getattr(mod, 'cmdtable', None)
        if cmdtable:
            ui.write(minirst.subsubsection(_(b'Commands')))
            commandprinter(
                ui,
                cmdtable,
                minirst.subsubsubsection,
                minirst.subsubsubsubsection,
                debugcmds=debugcmds,
            )


def showcommandlist(ui, debugcmds=False):
    """Render a plain text list of all command names

    Args:
        ui: the UI object to output to
        debugcmds: whether to include debug commands
    """
    cmdnames = allcommandnames(table, debugcmds=debugcmds)
    for mainname in cmdnames.keys():
        # Make does not like semicolons in filenames (or what it
        # considers as filenames). We use command names as targets so
        # it applies here. For now let's skip commands with semicolons
        # in them (at this time it only includes the `admin::verify`
        # advanced command).
        if b'::' in mainname:
            continue
        ui.write(mainname)
        ui.write(b" ")


def showtopiclist(ui):
    """Render a plain text list of all help topic names

    Args:
        ui: the UI object to output to
    """
    for topic in helptable:
        topicname = topic[0][0]
        if help.filtertopic(ui, topicname):
            continue
        ui.write(topicname)
        ui.write(b" ")


def showextensionlist(ui):
    """Render a plain text list of all extension names

    Args:
        ui: the UI object to output to
    """
    for extensionname in allextensionnames():
        ui.write(extensionname)
        ui.write(b" ")


def showhelpindex(ui, debugcmds=False):
    """Render restructured text for a complete mercurial help index

    This index will show a list of commands, followed by a list of help topics,
    and finally a list of extensions. These lists are split in categories and
    ordered 'nicely' as defined by alphabetical and categeory order.

    Each entry in this index is a reference to the specific help page of the
    command, topic, or extension at hand.
    """
    ui.write(minirst.section(_(b"Mercurial Distributed SCM")))

    missingdoc = _(b"(no help text available)")

    cats, h, syns = help._getcategorizedhelpcmds(ui, table, None)
    ui.write(minirst.subsection(_(b"Commands")))

    for cat in help.CATEGORY_ORDER:
        catfns = sorted(cats.get(cat, []))
        if not catfns:
            continue

        catname = gettext(help.CATEGORY_NAMES[cat])
        ui.write(minirst.subsubsection(catname))
        for c in catfns:
            url = b'hg-%s.html' % c
            ui.write(b" :`%s <%s>`__: %s" % (c, url, h[c]))
            syns[c].remove(c)
            if syns[c]:
                ui.write(_(b" (aliases: *%s*)") % (b', '.join(syns[c])))
            ui.write(b"\n")
        ui.write(b"\n\n")

    ui.write(b"\n\n")

    ui.write(minirst.subsection(_(b"Additional Help Topics")))
    topiccats, topicsyns = help._getcategorizedhelptopics(ui, helptable)
    for cat in help.TOPIC_CATEGORY_ORDER:
        topics = topiccats.get(cat, [])
        if not topics:
            continue

        catname = gettext(help.TOPIC_CATEGORY_NAMES[cat])
        ui.write(minirst.subsubsection(catname))
        for t, desc in topics:
            url = b'topic-%s.html' % t
            ui.write(b" :`%s <%s>`__: %s" % (t, url, desc))
            topicsyns[t].remove(t)
            if topicsyns[t]:
                ui.write(_(b" (aliases: *%s*)") % (b', '.join(topicsyns[t])))
            ui.write(b"\n")
        ui.write(b"\n\n")

    ui.write(b"\n\n")

    # Add an alphabetical list of extensions, categorized by group.
    sectionkeywords = [
        (b"(ADVANCED)", _(b"(ADVANCED)")),
        (b"(EXPERIMENTAL)", _(b"(EXPERIMENTAL)")),
        (b"(DEPRECATED)", _(b"(DEPRECATED)")),
    ]
    extensionsections = [
        (b"Extensions", []),
        (b"Advanced Extensions", []),
        (b"Experimental Extensions", []),
        (b"Deprecated Extensions", []),
    ]
    for extensionname in allextensionnames():
        mod = extensions.load(ui, extensionname, None)
        shortdoc, longdoc = _splitdoc(mod)
        for i, kwds in enumerate(sectionkeywords):
            if any([kwd in shortdoc for kwd in kwds]):
                extensionsections[i + 1][1].append(
                    (extensionname, mod, shortdoc)
                )
                break
        else:
            extensionsections[0][1].append((extensionname, mod, shortdoc))
    for sectiontitle, extinfos in extensionsections:
        ui.write(minirst.subsection(_(sectiontitle)))
        for extinfo in sorted(extinfos, key=lambda ei: ei[0]):
            extensionname, mod, shortdoc = extinfo
            url = b'ext-%s.html' % extensionname
            ui.write(
                minirst.subsubsection(b'`%s <%s>`__' % (extensionname, url))
            )
            ui.write(shortdoc)
            ui.write(b'\n\n')
            cmdtable = getattr(mod, 'cmdtable', None)
            if cmdtable:
                cmdnames = allcommandnames(cmdtable, debugcmds=debugcmds)
                for f in sorted(cmdnames.keys()):
                    d = get_cmd(cmdnames[f], cmdtable)
                    ui.write(b':%s: ' % d[b'cmd'])
                    ui.write(d[b'desc'][0] or (missingdoc + b"\n"))
                    ui.write(b'\n')
            ui.write(b'\n')


def showcommand(ui, mainname):
    # Always pass debugcmds=True so that we find whatever command we are told
    # to display.
    cmdnames = allcommandnames(table, debugcmds=True)
    allnames = cmdnames[mainname]
    d = get_cmd(allnames, table)

    header = _rendertpl(
        'cmdheader.txt',
        {
            'cmdname': mainname,
            'cmdtitle': minirst.section(b'hg ' + mainname),
            'cmdshortdesc': minirst.subsection(d[b'desc'][0]),
            'cmdlongdesc': d[b'desc'][1],
            'cmdsynopsis': d[b'synopsis'],
        },
    )
    ui.write(header.encode())

    _optionsprinter(ui, d, minirst.subsubsection)
    if d[b'aliases']:
        ui.write(minirst.subsubsection(_(b"Aliases")))
        ui.write(b"::\n\n   ")
        ui.write(b", ".join(d[b'aliases']))
        ui.write(b"\n")


def _splitdoc(obj):
    objdoc = pycompat.getdoc(obj)
    firstnl = objdoc.find(b'\n')
    if firstnl > 0:
        shortdoc = objdoc[:firstnl]
        longdoc = objdoc[firstnl + 1 :]
    else:
        shortdoc = objdoc
        longdoc = ''
    return shortdoc.lstrip(), longdoc.lstrip()


def _rendertpl(tplname, data):
    tplpath = os.path.join(os.path.dirname(__file__), 'templates', tplname)
    with open(tplpath) as f:
        tpl = f.read()

    if isinstance(tpl, bytes):
        tpl = tpl.decode()
    for k in data:
        data[k] = data[k].decode()

    return tpl % data


def gettopicstable():
    extrahelptable = [
        ([b"common"], b'', loaddoc(b'common'), help.TOPIC_CATEGORY_MISC),
        ([b"hg.1"], b'', loaddoc(b'hg.1'), help.TOPIC_CATEGORY_CONFIG),
        ([b"hg-ssh.8"], b'', loaddoc(b'hg-ssh.8'), help.TOPIC_CATEGORY_CONFIG),
        (
            [b"hgignore.5"],
            b'',
            loaddoc(b'hgignore.5'),
            help.TOPIC_CATEGORY_CONFIG,
        ),
        ([b"hgrc.5"], b'', loaddoc(b'hgrc.5'), help.TOPIC_CATEGORY_CONFIG),
        ([b"hg-ssh.8.gendoc"], b'', b'', help.TOPIC_CATEGORY_CONFIG),
        (
            [b"hgignore.5.gendoc"],
            b'',
            loaddoc(b'hgignore'),
            help.TOPIC_CATEGORY_CONFIG,
        ),
        (
            [b"hgrc.5.gendoc"],
            b'',
            loaddoc(b'config'),
            help.TOPIC_CATEGORY_CONFIG,
        ),
    ]
    return helptable + extrahelptable


def findtopics(helptable, include=[], exclude=[]):
    """Find topics whose names match the given include/exclude rules

    Note that exclude rules take precedence over include rules.
    """
    found = []
    for h in helptable:
        names, sec, doc = h[0:3]
        if exclude and names[0] in exclude:
            continue
        if include and names[0] not in include:
            continue
        found.append((names, sec, doc))
    return found


def showtopic(ui, topic, wraptpl=False):
    """Render a help topic

    Args:
        ui: the UI object to output to
        topic: the topic name to output
        wraptpl: whether to wrap the output in the individual help topic
            pages' header/footer
    """
    found = findtopics(gettopicstable(), include=[topic])
    if not found:
        ui.write_err(_(b"ERROR: no such topic: %s\n") % topic)
        sys.exit(1)

    if wraptpl:
        header = _rendertpl(
            'topicheader.txt',
            {'topicname': topic, 'topictitle': minirst.section(found[0][1])},
        )
        ui.write(header.encode())
    helpprinter(ui, found, None)
    return True


def helpprinter(ui, topics, sectionfunc):
    """Print a help topic

    Args:
        ui: the UI object to output to
        topics: a list of help topics to output
        sectionfunc: a callback to write the section title
    """
    for h in topics:
        names, sec, doc = h[0:3]
        for name in names:
            ui.write(b".. _%s:\n" % name)
        ui.write(b"\n")
        if sectionfunc:
            ui.write(sectionfunc(sec))
        if callable(doc):
            doc = doc(ui)
        ui.write(doc)
        ui.write(b"\n")


def showextension(ui, extensionname, debugcmds=False):
    """Render the help text for an extension

    Args:
        ui: the UI object to output to
        extensionname: the name of the extension to output
        debugcmds: whether to include the extension's debug commands, if any
    """
    mod = extensions.load(ui, extensionname, None)

    header = _rendertpl(
        'extheader.txt',
        {'extname': extensionname, 'exttitle': minirst.section(extensionname)},
    )
    ui.write(header.encode())

    shortdoc, longdoc = _splitdoc(mod)
    if shortdoc:
        ui.write(b"%s\n\n" % gettext(shortdoc))
    if longdoc:
        ui.write(minirst.subsection(_(b"Description")))
        ui.write(b"%s\n\n" % gettext(longdoc))

    cmdtable = getattr(mod, 'cmdtable', None)
    if cmdtable:
        ui.write(minirst.subsection(_(b'Commands')))
        commandprinter(
            ui,
            cmdtable,
            minirst.subsubsection,
            minirst.subsubsubsection,
            debugcmds=debugcmds,
        )


def commandprinter(ui, cmdtable, sectionfunc, subsectionfunc, debugcmds=False):
    """Render restructuredtext describing a list of commands and their
    documentations, grouped by command category.

    Args:
      ui: UI object to write the output to
      cmdtable: a dict that maps a string of the command name plus its aliases
        (separated with pipes) to a 3-tuple of (the command's function, a list
        of its option descriptions, and a string summarizing available
        options). Example, with aliases added for demonstration purposes:

          'phase|alias1|alias2': (
             <function phase at 0x7f0816b05e60>,
             [ ('p', 'public', False, 'set changeset phase to public'),
               ...,
               ('r', 'rev', [], 'target revision', 'REV')],
             '[-p|-d|-s] [-f] [-r] [REV...]'
          )
      sectionfunc: minirst function to format command category headers
      subsectionfunc: minirst function to format command headers
    """
    h = allcommandnames(cmdtable, debugcmds=debugcmds)
    cmds = h.keys()

    def helpcategory(cmd):
        """Given a canonical command name from `cmds` (above), retrieve its
        help category. If helpcategory is None, default to CATEGORY_NONE.
        """
        fullname = h[cmd]
        details = cmdtable[fullname]
        helpcategory = details[0].helpcategory
        return helpcategory or help.registrar.command.CATEGORY_NONE

    cmdsbycategory = {category: [] for category in help.CATEGORY_ORDER}
    for cmd in cmds:
        # If a command category wasn't registered, the command won't get
        # rendered below, so we raise an AssertionError.
        if helpcategory(cmd) not in cmdsbycategory:
            raise AssertionError(
                "The following command did not register its (category) in "
                "help.CATEGORY_ORDER: %s (%s)" % (cmd, helpcategory(cmd))
            )
        cmdsbycategory[helpcategory(cmd)].append(cmd)

    # Print the help for each command. We present the commands grouped by
    # category, and we use help.CATEGORY_ORDER as a guide for a helpful order
    # in which to present the categories.
    for category in help.CATEGORY_ORDER:
        categorycmds = cmdsbycategory[category]
        if not categorycmds:
            # Skip empty categories
            continue
        # Print a section header for the category.
        # For now, the category header is at the same level as the headers for
        # the commands in the category; this is fixed in the next commit.
        ui.write(sectionfunc(help.CATEGORY_NAMES[category]))
        # Print each command in the category
        for f in sorted(categorycmds):
            d = get_cmd(h[f], cmdtable)
            ui.write(subsectionfunc(d[b'cmd']))
            # short description
            ui.write(d[b'desc'][0])
            # synopsis
            ui.write(b"::\n\n")
            synopsislines = d[b'synopsis'].splitlines()
            for line in synopsislines:
                # some commands (such as rebase) have a multi-line
                # synopsis
                ui.write(b"   %s\n" % line)
            ui.write(b'\n')
            # description
            ui.write(b"%s\n\n" % d[b'desc'][1])

            # options
            def _optsection(s):
                return b"%s:\n\n" % s

            _optionsprinter(ui, d, _optsection)
            # aliases
            if d[b'aliases']:
                # Note the empty comment, this is required to separate this
                # (which should be a blockquote) from any preceding things (such
                # as a definition list).
                ui.write(
                    _(b"..\n\n    aliases: %s\n\n") % b" ".join(d[b'aliases'])
                )


def _optionsprinter(ui, cmd, sectionfunc):
    """Outputs the list of options for a given command object"""
    opt_output = list(cmd[b'opts'])
    if opt_output:
        opts_len = max([len(line[0]) for line in opt_output])
        ui.write(sectionfunc(_(b"Options")))
        multioccur = False
        for optstr, desc in opt_output:
            if desc:
                s = b"%-*s  %s" % (opts_len, optstr, desc)
            else:
                s = optstr
            ui.write(b"%s\n" % s)
            if optstr.endswith(b"[+]>"):
                multioccur = True
        if multioccur:
            ui.write(
                _(b"\n[+] marked option can be specified multiple times\n")
            )
        ui.write(b"\n")


def allcommandnames(cmdtable, debugcmds=False):
    """Get a collection of all command names in the given command table

    Args:
        cmdtable: the command table to get the names from
        debugcmds: whether to include debug commands

    Returns a dictionary where the keys are the main command names, and the
    values are the "raw" names (in the form of `name|alias1|alias2`).
    """
    allcmdnames = {}
    for rawnames, attr in cmdtable.items():
        mainname = rawnames.split(b"|")[0].lstrip(b"^")
        if not debugcmds and mainname.startswith(b"debug"):
            continue
        allcmdnames[mainname] = rawnames
    return allcmdnames


def allextensionnames():
    """Get a set of all known extension names"""
    return set(extensions.enabled().keys()) | set(extensions.disabled().keys())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        prog='gendoc', description="Generate mercurial documentation files"
    )
    parser.add_argument('doc', default='hg.1.gendoc', nargs='?')
    parser.add_argument(
        '-d',
        '--debug-cmds',
        action='store_true',
        help="Show debug commands in help pages",
    )
    args = parser.parse_args()

    doc = encoding.strtolocal(args.doc)
    debugcmds = args.debug_cmds

    ui = uimod.ui.load()
    # Trigger extensions to load. This is disabled by default because it uses
    # the current user's configuration, which is often not what is wanted.
    if encoding.environ.get(b'GENDOC_LOAD_CONFIGURED_EXTENSIONS', b'0') != b'0':
        extensions.loadall(ui)

    # ui.debugflag determines if the help module returns debug commands to us.
    ui.debugflag = debugcmds

    # Render the 'all-in-one' giant documentation file
    if doc == b'hg.1.gendoc':
        showdoc(ui)
    # Render a command/help-topic/extension name list (for internal use)
    elif doc == b'commandlist':
        showcommandlist(ui, debugcmds=debugcmds)
    elif doc == b'topiclist':
        showtopiclist(ui)
    elif doc == b'extensionlist':
        showextensionlist(ui)
    # Render the help index/main page
    elif doc == b'index':
        showhelpindex(ui, debugcmds=debugcmds)
    # Render an individual command/help-topic/extension page
    elif doc.startswith(b'cmd-'):
        showcommand(ui, doc[4:])
    elif doc.startswith(b'topic-'):
        showtopic(ui, doc[6:], wraptpl=True)
    elif doc.startswith(b'ext-'):
        showextension(ui, doc[4:], debugcmds=debugcmds)
    # Render a help-topic page without any title/footer, for later inclusion
    # into a hand-written help text file
    else:
        showtopic(ui, doc)
