# initialization.py - modules initialization for Mercurial
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""Modules initialization for Mercurial

This module is in charge of making sure that all modules that are necessary for
the "initialization" of the mercurial module are properly imported and
initialized.

This module exists for two reasons:

  - First, to avoid circular module imports, Mercurial started to use a
    pattern where modules that need to register "items" (e.g. a new command)
    use small top-level "inert" modules with almost no imports in them (e.g.
    `mercurial.tables`) to store these items. Modules that need to use these
    items then do so through the small "inert" modules. That way even if two
    different subsystems need information about the other, they don't need to
    import deeply into each other, avoiding cycles.

    However this system means we can't rely on the user to explicitly import
    the module that defines the code it will need. So this module is in charge
    of making sure each module that does this kind of registration has been
    properly imported and initialized early on.

    If you add one such module, you need to add it to the current
    initialization module.

  - Second, because Mercurial uses a lazy import system by default, having a
    module importing another one is not enough to ensure its code has been run,
    so this module is also responsible to make sure these important modules have
    been actually imported. Do so and, for the sake of clarity, we use a
    convention of calling an `init()` function on these modules. That function
    does nothing in most cases, but calling it will trigger the import of the
    module.
"""

from __future__ import annotations

from . import (
    admin_commands,
    bundle2_part_handlers,
    commands,
    debugcommands,
    revset,
    revset_predicates,
    strip,
    subrepo,
    templatekw,
)

from .admin import (
    chainsaw as admin_chainsaw,
)
from .hgweb import (
    webcommands,
)


def init():
    """noop function that is called to make sure the module is loaded and has
    registered the necessary items."""


admin_chainsaw.init()
admin_commands.init()
commands.init()
debugcommands.init()
revset_predicates.init()
# register all other revset first because of the i18nfunctions business.
revset.init()
strip.init()
webcommands.init()
bundle2_part_handlers.init()
templatekw.init()
subrepo.init()
