# mercurial/interfaces/types.py - type alias for interfaces
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This is the main entry point for Mercurial code writing type annotations.
#
# The general principle can be summarized when dealing with <FooBar> object:
# - to type your code: use FooBarT from `mercurial.interface.types`
# - to subclass <FooBar>: use IFooBar from `mercurial.interface.foo_bar`

from __future__ import annotations

from typing import (
    Union,
)

from ._basetypes import (  # noqa: F401 (ignore imported but not used)
    CallbackCategoryT,
    FsPathT,
    HgPathT,
    NeedsTypeHint,
    NodeIdT,
    RepoT,
    RevlogT,
    RevnumT,
    RevsetAliasesT,
    UiT,
    UserMsgT,
    VfsKeyT,
    VfsT,
)

from . import (
    bundle,
    config,
    context,
    matcher,
    misc,
    repository,
    status,
    transaction,
    ui as uimod,
)


Capabilities = dict[bytes, Union[list[bytes], tuple[bytes, ...]]]
ChangeContextT = context.IChangeContext

CfgRemapT = config.CfgRemapT
CfgSectionsT = config.CfgSectionsT

FileStorageT = repository.ifilestorage

HttpPasswordMgrT = uimod.IHttpPasswordMgr

# XXX RepoT should be IlocalRepo
#
# The other are copied for temporary backward compatibility
LocalRepoMainT = repository.IRepo
LocalRepoCompleteT = repository.IRepo
LocalRepoFileStorageT = repository.IRepo

MatcherBadFuncT = matcher.BadFuncT
MatcherKindPatT = matcher.KindPatT
MatcherMatchFuncT = matcher.MatchFuncT
MatcherT = matcher.IMatcher
MatcherTraverseDirFuncT = matcher.TraverseDirFuncT

RevisionDeltaT = repository.irevisiondelta

StatusT = status.Status
SubrepoT = misc.ISubRepo
TransactionT = transaction.ITransaction

UnbundlePartT = bundle.IUnbundlePart

WorkingCommitContextT = context.IWorkingCommitContext
WorkingContextT = context.IWorkingContext
