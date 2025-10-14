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
    Callable,
    Union,
)

from ._basetypes import (  # noqa: F401 (ignore imported but not used)
    CallbackCategoryT,
    FsPathT,
    HgPathT,
    NeedsTypeHint,
    NodeIdT,
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

RepoT = repository.IRepo
# The other are copied for temporary backward compatibility
LocalRepoMainT = repository.IRepo
LocalRepoCompleteT = repository.IRepo
LocalRepoFileStorageT = repository.IRepo

RepoFileFnT = repository.IRepoFileFn

RequirementT = repository.RequirementT
RequirementSetT = repository.RequirementSetT

MatcherBadFuncT = matcher.BadFuncT
MatcherKindPatT = matcher.KindPatT
MatcherMatchFuncT = matcher.MatchFuncT
MatcherT = matcher.MatcherT
MatcherTraverseDirFuncT = matcher.TraverseDirFuncT

OutboundRevisionT = repository.IOutboundRevision
InboundRevisionT = repository.IInboundRevision

StatusT = status.Status
SubrepoT = misc.ISubRepo
TransactionT = transaction.ITransaction

UnbundlePartT = bundle.IUnbundlePart

WorkingCommitContextT = context.IWorkingCommitContext
WorkingContextT = context.IWorkingContext


ExtSetupFnT = Callable[[UiT], None]
"""The signature of ``extsetup()``, typically used by extensions."""

RepoSetupFnT = Callable[[UiT, RepoT], None]
"""The signature of ``reposetup()``, typically used by extensions."""

UiPopulateFnT = Callable[[UiT], None]
"""The signature of ``uipopulate()``, typically used by extensions."""

UiSetupFnT = Callable[[UiT], None]
"""The signature of ``uisetup()``, typically used by extensions."""
