# pullext.py - Simple extension to test pulling
#
# Copyright 2018 Gregory Szorc <gregory.szorc@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import absolute_import

from mercurial.i18n import _
from mercurial import (
    commands,
    extensions,
    localrepo,
    repository,
)

def clonecommand(orig, ui, repo, *args, **kwargs):
    if kwargs.get(r'include') or kwargs.get(r'exclude'):
        kwargs[r'narrow'] = True

    return orig(ui, repo, *args, **kwargs)

def featuresetup(ui, features):
    features.add(repository.NARROW_REQUIREMENT)

def extsetup(ui):
    entry = extensions.wrapcommand(commands.table, 'clone', clonecommand)

    hasinclude = any(x[1] == 'include' for x in entry[1])

    if not hasinclude:
        entry[1].append(('', 'include', [],
                         _('pattern of file/directory to clone')))
        entry[1].append(('', 'exclude', [],
                         _('pattern of file/directory to not clone')))

    localrepo.featuresetupfuncs.add(featuresetup)
