# merge_utils.diff - logic to diff merges.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from ..node import (
    nullrev,
)


def diff_parent(ctx):
    """get the context object to use as parent when diffing


    If diff.merge is enabled, an overlayworkingctx of the auto-merged parents
    will be returned.
    """
    # avoid a cycle
    from .. import (
        merge,
    )

    repo = ctx.repo()
    if repo.ui.configbool(b"diff", b"merge") and ctx.p2().rev() != nullrev:
        wctx = ctx.p1_overlay()
        with repo.ui.configoverride(
            {
                (
                    b"ui",
                    b"forcemerge",
                ): b"internal:merge3-lie-about-conflicts",
            },
            b"merge-diff",
        ):
            with repo.ui.silent():
                merge.merge(ctx.p2(), wc=wctx)
        return wctx
    else:
        return ctx.p1()
