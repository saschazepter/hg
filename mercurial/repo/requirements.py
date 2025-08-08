# repo.requirements - small utilities around requirements for repositories
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from .. import (
    extensions,
    requirements as requirementsmod,
    util,
)

# Functions receiving (ui, features) that extensions can register to impact
# the ability to load repositories with custom requirements. Only
# functions defined in loaded extensions are called.
#
# The function receives a set of requirement strings that the repository
# is capable of opening. Functions will typically add elements to the
# set to reflect that the extension knows how to handle that requirements.
feature_setup_funcs = set()

BASE_SUPPORTED = {
    requirementsmod.ARCHIVED_PHASE_REQUIREMENT,
    requirementsmod.BOOKMARKS_IN_STORE_REQUIREMENT,
    requirementsmod.CHANGELOGV2_REQUIREMENT,
    requirementsmod.COPIESSDC_REQUIREMENT,
    requirementsmod.DELTA_INFO_REQUIREMENT,
    requirementsmod.DIRSTATE_TRACKED_HINT_V1,
    requirementsmod.DIRSTATE_V2_REQUIREMENT,
    requirementsmod.DOTENCODE_REQUIREMENT,
    requirementsmod.FILEINDEXV1_REQUIREMENT,
    requirementsmod.FILELOG_METAFLAG_REQUIREMENT,
    requirementsmod.FNCACHE_REQUIREMENT,
    requirementsmod.GENERALDELTA_REQUIREMENT,
    requirementsmod.INTERNAL_PHASE_REQUIREMENT,
    requirementsmod.NODEMAP_REQUIREMENT,
    requirementsmod.PLAIN_ENCODE_REQUIREMENT,
    requirementsmod.RELATIVE_SHARED_REQUIREMENT,
    requirementsmod.REVLOGV1_REQUIREMENT,
    requirementsmod.REVLOGV2_REQUIREMENT,
    requirementsmod.SHARED_REQUIREMENT,
    requirementsmod.SHARESAFE_REQUIREMENT,
    requirementsmod.SPARSEREVLOG_REQUIREMENT,
    requirementsmod.SPARSE_REQUIREMENT,
    requirementsmod.STORE_REQUIREMENT,
    requirementsmod.TREEMANIFEST_REQUIREMENT,
}


def gather_supported_requirements(ui):
    """Determine the complete set of recognized requirements."""
    # Start with all requirements supported by this file.
    supported = set(BASE_SUPPORTED)

    # Execute ``feature_setup_funcs`` entries if they belong to an extension
    # relevant to this ui instance.
    modules = {m.__name__ for n, m in extensions.extensions(ui)}

    for fn in feature_setup_funcs:
        if fn.__module__ in modules:
            fn(ui, supported)

    # Add derived requirements from registered compression engines.
    for name in util.compengines:
        engine = util.compengines[name]
        if engine.available() and engine.revlogheader():
            supported.add(b'exp-compression-%s' % name)
            if engine.name() == b'zstd':
                supported.add(requirementsmod.REVLOG_COMPRESSION_ZSTD)

    return supported
