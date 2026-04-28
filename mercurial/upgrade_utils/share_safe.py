# upgrade.py - functions for in place upgrade of Mercurial repository
#
# Copyright (c) 2016-present, Gregory Szorc
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import typing

from ..i18n import _
from .. import (
    error,
    lock as lockmod,
    requirements as requirementsmod,
    scmutil,
)

from ..utils import (
    stringutil,
)

if typing.TYPE_CHECKING:
    from ..interfaces.types import (
        RequirementSetT,
        UiT,
        VfsT,
    )


def upgrade_share_to_safe(
    ui: UiT,
    hgvfs: VfsT,
    current_requirements: RequirementSetT,
    mismatch_config: bytes,
    mismatch_warn: bool,
    mismatch_verbose_upgrade: bool,
) -> None:
    """Upgrades a share to use share-safe mechanism"""
    wlock = None
    original_crequirements = current_requirements.copy()
    # After the upgrade, store requirements will be shared, so let's write only
    # the working dir (non-store) requirements to the share's .hg/requires.
    # Some definitions:
    # * R = W + S = all wdir + store requirements known to this version of hg
    # * C = current_requirements
    # * X = source repo's store requirements
    # Note that C ⊆ R and X ⊆ R, otherwise we would have aborted earlier.
    # Below we define diffrequires as:
    #     C & W
    #   = C - S
    #   = C - (S & X) - (S - X)
    # Therefore C - S (removing all known store requirements) is similar to
    # C - X (removing all actual store requirements) but with two differences:
    # * Only remove (S & X), not (W & X). The only way the latter could be
    #   nonempty is if some version of hg moves an existing requirement into
    #   requirementsmod.WORKING_DIR_REQUIREMENTS. We should not do that.
    # * Additionally remove (S - X). For example, if the source repo is upgraded
    #   to a new format after the share is created, then the share could have
    #   stale store requirements no longer in X.
    diffrequires = (
        current_requirements & requirementsmod.WORKING_DIR_REQUIREMENTS
    )
    # add share-safe requirement as it will mark the share as share-safe
    diffrequires.add(requirementsmod.SHARESAFE_REQUIREMENT)
    current_requirements.add(requirementsmod.SHARESAFE_REQUIREMENT)
    # in `allow` case, we don't try to upgrade, we just respect the source
    # state, update requirements and continue
    if mismatch_config == b'allow':
        return
    try:
        wlock = lockmod.trylock(ui, hgvfs, b'wlock', 0, 0)
        # some process might change the requirement in between, re-read
        # and update current_requirements
        locked_requirements = scmutil.readrequires(hgvfs, True)
        if locked_requirements != original_crequirements:
            removed = current_requirements - locked_requirements
            # update current_requirements in place because it's passed
            # as reference
            current_requirements -= removed
            current_requirements |= locked_requirements
            diffrequires = (
                current_requirements & requirementsmod.WORKING_DIR_REQUIREMENTS
            )
            # add share-safe requirement as it will mark the share as share-safe
            diffrequires.add(requirementsmod.SHARESAFE_REQUIREMENT)
            current_requirements.add(requirementsmod.SHARESAFE_REQUIREMENT)
        scmutil.writerequires(hgvfs, diffrequires)
        if mismatch_verbose_upgrade:
            ui.warn(_(b'repository upgraded to use share-safe mode\n'))
    except error.LockError as e:
        hint = _(
            b"see `hg help config.format.use-share-safe` for more information"
        )
        if mismatch_config == b'upgrade-abort':
            raise error.Abort(
                _(b'failed to upgrade share, got error: %s')
                % stringutil.forcebytestr(e.strerror),
                hint=hint,
            )
        elif mismatch_warn:
            ui.warn(
                _(b'failed to upgrade share, got error: %s\n')
                % stringutil.forcebytestr(e.strerror),
                hint=hint,
            )
    finally:
        if wlock:
            wlock.release()


def downgrade_share_to_non_safe(
    ui: UiT,
    hgvfs: VfsT,
    sharedvfs: VfsT,
    current_requirements: RequirementSetT,
    mismatch_config: bytes,
    mismatch_warn: bool,
    mismatch_verbose_upgrade: bool,
) -> None:
    """Downgrades a share which use share-safe to not use it"""
    wlock = None
    source_requirements = scmutil.readrequires(sharedvfs, True)
    original_crequirements = current_requirements.copy()
    # we cannot be 100% sure on which requirements were present in store when
    # the source supported share-safe. However, we do know that working
    # directory requirements were not there. Hence we remove them
    source_requirements -= requirementsmod.WORKING_DIR_REQUIREMENTS
    current_requirements |= source_requirements
    current_requirements.remove(requirementsmod.SHARESAFE_REQUIREMENT)
    if mismatch_config == b'allow':
        return

    try:
        wlock = lockmod.trylock(ui, hgvfs, b'wlock', 0, 0)
        # some process might change the requirement in between, re-read
        # and update current_requirements
        locked_requirements = scmutil.readrequires(hgvfs, True)
        if locked_requirements != original_crequirements:
            removed = current_requirements - locked_requirements
            # update current_requirements in place because it's passed
            # as reference
            current_requirements -= removed
            current_requirements |= locked_requirements
            current_requirements |= source_requirements
            current_requirements -= set(requirementsmod.SHARESAFE_REQUIREMENT)
        scmutil.writerequires(hgvfs, current_requirements)
        if mismatch_verbose_upgrade:
            ui.warn(_(b'repository downgraded to not use share-safe mode\n'))
    except error.LockError as e:
        hint = _(
            b"see `hg help config.format.use-share-safe` for more information"
        )
        # If upgrade-abort is set, abort when upgrade fails, else let the
        # process continue as `upgrade-allow` is set
        if mismatch_config == b'downgrade-abort':
            raise error.Abort(
                _(b'failed to downgrade share, got error: %s')
                % stringutil.forcebytestr(e.strerror),
                hint=hint,
            )
        elif mismatch_warn:
            ui.warn(
                _(b'failed to downgrade share, got error: %s\n')
                % stringutil.forcebytestr(e.strerror),
                hint=hint,
            )
    finally:
        if wlock:
            wlock.release()
