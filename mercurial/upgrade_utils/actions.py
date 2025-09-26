# upgrade.py - functions for in place upgrade of Mercurial repository
#
# Copyright (c) 2016-present, Gregory Szorc
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import random
import typing

from ..i18n import _
from .. import (
    error,
    requirements,
    revlog,
    util,
)
from ..repo import (
    creation,
)
from ..utils import compression

if typing.TYPE_CHECKING:
    from typing import (
        ClassVar,
        Final,
        TypeVar,
    )
    from ..interfaces.types import (
        RepoT,
        RequirementSetT,
        RequirementT,
        UiT,
    )

    _FormatVariantTypeT = TypeVar(
        '_FormatVariantTypeT', bound=type["formatvariant"]
    )

# list of requirements that request a clone of all revlog if added/removed
RECLONES_REQUIREMENTS: Final[RequirementSetT] = {
    requirements.CHANGELOGV2_REQUIREMENT,
    requirements.DELTA_INFO_REQUIREMENT,
    requirements.GENERALDELTA_REQUIREMENT,
    requirements.REVLOGV2_REQUIREMENT,
    requirements.SPARSEREVLOG_REQUIREMENT,
}


def preservedrequirements(repo: RepoT) -> RequirementSetT:
    preserved = {
        requirements.NARROW_REQUIREMENT,
        requirements.SHARED_REQUIREMENT,
    }
    return preserved & repo.requirements


FORMAT_VARIANT: Final[bytes] = b'deficiency'
OPTIMISATION: Final[bytes] = b'optimization'


class improvement:
    """Represents an improvement that can be made as part of an upgrade."""

    ### The following attributes should be defined for each subclass:

    # Either ``FORMAT_VARIANT`` or ``OPTIMISATION``.
    # A format variant is where we change the storage format. Not all format
    # variant changes are an obvious problem.
    # An optimization is an action (sometimes optional) that
    # can be taken to further improve the state of the repository.
    type = None

    # machine-readable string uniquely identifying this improvement. it will be
    # mapped to an action later in the upgrade process.
    name = None

    # message intended for humans explaining the improvement in more detail,
    # including the implications of it ``FORMAT_VARIANT`` types, should be
    # worded
    # in the present tense.
    description = None

    # message intended for humans explaining what an upgrade addressing this
    # issue will do. should be worded in the future tense.
    upgrademessage = None

    # value of current Mercurial default for new repository
    default = None

    # Message intended for humans which will be shown post an upgrade
    # operation when the improvement will be added
    postupgrademessage = None

    # Message intended for humans which will be shown post an upgrade
    # operation in which this improvement was removed
    postdowngrademessage = None

    # By default we assume that every improvement touches requirements and all revlogs

    # Whether this improvement touches filelogs
    touches_filelogs = True

    # Whether this improvement touches manifests
    touches_manifests = True

    # Whether this improvement touches changelog
    touches_changelog = True

    # Whether this improvement changes repository requirements
    touches_requirements = True

    # Whether this improvement touches the dirstate
    touches_dirstate = False

    # Can this action be run on a share instead of its mains repository
    compatible_with_share = False


allformatvariant: list[type[formatvariant]] = []


def registerformatvariant(cls: _FormatVariantTypeT) -> _FormatVariantTypeT:
    allformatvariant.append(cls)
    return cls


class formatvariant(improvement):
    """an improvement subclass dedicated to repository format"""

    type: ClassVar[bytes] = FORMAT_VARIANT

    @staticmethod
    def fromrepo(repo: RepoT):
        """current value of the variant in the repository"""
        raise NotImplementedError()

    @staticmethod
    def fromconfig(repo: RepoT):
        """current value of the variant in the configuration"""
        raise NotImplementedError()


class requirementformatvariant(formatvariant):
    """formatvariant based on a 'requirement' name.

    Many format variant are controlled by a 'requirement'. We define a small
    subclass to factor the code.
    """

    # the requirement that control this format variant
    _requirement: ClassVar[RequirementT | None] = None

    @staticmethod
    def _newreporequirements(ui: UiT) -> RequirementSetT:
        return creation.new_repo_requirements(
            ui,
            creation.default_create_opts(ui),
        )

    @classmethod
    def fromrepo(cls, repo: RepoT) -> bool:
        assert cls._requirement is not None
        return cls._requirement in repo.requirements

    @classmethod
    def fromconfig(cls, repo: RepoT) -> bool:
        assert cls._requirement is not None
        return cls._requirement in cls._newreporequirements(repo.ui)


@registerformatvariant
class fncache(requirementformatvariant):
    name: ClassVar[bytes] = b'fncache'

    _requirement: ClassVar[RequirementT] = requirements.FNCACHE_REQUIREMENT

    default: ClassVar[bool] = True

    description: ClassVar[bytes] = _(
        b'long and reserved filenames may not work correctly; '
        b'repository performance is sub-optimal'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'repository will be more resilient to storing '
        b'certain paths and performance of certain '
        b'operations should be improved'
    )


@registerformatvariant
class file_index_v1(requirementformatvariant):
    name: ClassVar[bytes] = b'fileindex-v1'

    _requirement: ClassVar[RequirementT] = requirements.FILEINDEXV1_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'replaces the fncache with a more efficient and powerful storage '
        b'format'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'transactions that add files will be faster in large repos'
    )

    touches_filelogs: ClassVar[bool] = False
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False
    touches_requirements: ClassVar[bool] = True
    touches_dirstate: ClassVar[bool] = False
    compatible_with_share: ClassVar[bool] = False


@registerformatvariant
class dirstatev2(requirementformatvariant):
    name: ClassVar[bytes] = b'dirstate-v2'
    _requirement: ClassVar[RequirementT] = requirements.DIRSTATE_V2_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'version 1 of the dirstate file format requires '
        b'reading and parsing it all at once.\n'
        b'Version 2 has a better structure,'
        b'better information and lighter update mechanism'
    )

    upgrademessage: ClassVar[bytes] = _(b'"hg status" will be faster')

    touches_filelogs: ClassVar[bool] = False
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False
    touches_requirements: ClassVar[bool] = True
    touches_dirstate: ClassVar[bool] = True
    compatible_with_share: ClassVar[bool] = True


@registerformatvariant
class dirstatetrackedkey(requirementformatvariant):
    name: ClassVar[bytes] = b'tracked-hint'
    _requirement: ClassVar[RequirementT] = requirements.DIRSTATE_TRACKED_HINT_V1

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'Add a small file to help external tooling that watch the tracked set'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'external tools will be informated of potential change in the tracked set'
    )

    touches_filelogs: ClassVar[bool] = False
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False
    touches_requirements: ClassVar[bool] = True
    touches_dirstate: ClassVar[bool] = True
    compatible_with_share: ClassVar[bool] = True


@registerformatvariant
class dotencode(requirementformatvariant):
    name: ClassVar[bytes] = b'dotencode'

    _requirement: ClassVar[RequirementT] = requirements.DOTENCODE_REQUIREMENT

    default: ClassVar[bool] = True

    description: ClassVar[bytes] = _(
        b'storage of filenames beginning with a period or '
        b'space may not work correctly'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'repository will be better able to store files '
        b'beginning with a space or period'
    )

    touches_filelogs: ClassVar[bool] = True
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False
    touches_requirements: ClassVar[bool] = True
    touches_dirstate: ClassVar[bool] = False
    compatible_with_share: ClassVar[bool] = True


@registerformatvariant
class plain_encode(requirementformatvariant):
    name: ClassVar[bytes] = b'fragile-plain-encode'

    _requirement: ClassVar[RequirementT] = requirements.PLAIN_ENCODE_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'using this option is dangerous and not recommended'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'you will move to this dangerous format, are you sure?'
    )
    touches_filelogs: ClassVar[bool] = True
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False
    touches_requirements: ClassVar[bool] = True
    touches_dirstate: ClassVar[bool] = False
    compatible_with_share: ClassVar[bool] = True


@registerformatvariant
class generaldelta(requirementformatvariant):
    name: ClassVar[bytes] = b'generaldelta'

    _requirement: ClassVar[RequirementT] = requirements.GENERALDELTA_REQUIREMENT

    default: ClassVar[bool] = True

    description: ClassVar[bytes] = _(
        b'deltas within internal storage are unable to '
        b'choose optimal revisions; repository is larger and '
        b'slower than it could be; interaction with other '
        b'repositories may require extra network and CPU '
        b'resources, making "hg push" and "hg pull" slower'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'repository storage will be able to create '
        b'optimal deltas; new repository data will be '
        b'smaller and read times should decrease; '
        b'interacting with other repositories using this '
        b'storage model should require less network and '
        b'CPU resources, making "hg push" and "hg pull" '
        b'faster'
    )


@registerformatvariant
class sharesafe(requirementformatvariant):
    name: ClassVar[bytes] = b'share-safe'
    _requirement: ClassVar[RequirementT] = requirements.SHARESAFE_REQUIREMENT

    default: ClassVar[bool] = True

    description: ClassVar[bytes] = _(
        b'old shared repositories do not share source repository '
        b'requirements and config. This leads to various problems '
        b'when the source repository format is upgraded or some new '
        b'extensions are enabled.'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'Upgrades a repository to share-safe format so that future '
        b'shares of this repository share its requirements and configs.'
    )

    postdowngrademessage: ClassVar[bytes] = _(
        b'repository downgraded to not use share safe mode, '
        b'existing shares will not work and need to be reshared.'
    )

    postupgrademessage: ClassVar[bytes] = _(
        b'repository upgraded to share safe mode, existing'
        b' shares will still work in old non-safe mode. '
        b'Re-share existing shares to use them in safe mode'
        b' New shares will be created in safe mode.'
    )

    # upgrade only needs to change the requirements
    touches_filelogs: ClassVar[bool] = False
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False
    touches_requirements: ClassVar[bool] = True


@registerformatvariant
class hasmeta_filelog(requirementformatvariant):
    name: ClassVar[bytes] = b'hasmeta_flag'

    _requirement: ClassVar[
        RequirementT
    ] = requirements.FILELOG_METAFLAG_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'copy metadata in filelog uses a fragile marking and some cases '
        b'require unpacking file content to determine if copy information '
        b'exists.'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'A dedicated index flag marks file revisions with copy information.'
    )

    # upgrade only needs to process the filelogs
    touches_filelogs: ClassVar[bool] = True
    touches_manifests: ClassVar[bool] = False
    touches_changelog: ClassVar[bool] = False


@registerformatvariant
class sparserevlog(requirementformatvariant):
    name: ClassVar[bytes] = b'sparserevlog'

    _requirement: ClassVar[RequirementT] = requirements.SPARSEREVLOG_REQUIREMENT

    default: ClassVar[bool] = True

    description: ClassVar[bytes] = _(
        b'in order to limit disk reading and memory usage on older '
        b'versions, the span of a delta chain from its root to its '
        b'end is limited, whatever the relevant data in this span. '
        b"This can severely limit Mercurial's ability to build a good "
        b'chain of delta resulting in much more storage space being '
        b'taken, and limit reusability of on disk delta during '
        b'exchange.'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'Revlog supports delta chain with more unused data '
        b'between payloads. These gaps will be skipped at read '
        b'time. This allows for better delta chains, making a '
        b'better compression and faster exchange with the server.'
    )


@registerformatvariant
class delta_info_flags(requirementformatvariant):
    name: ClassVar[bytes] = b'delta-info-flags'

    _requirement: ClassVar[RequirementT] = requirements.DELTA_INFO_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'Store information about stored delta in the index to help optimize '
        b'local and remote delta chain.'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'Using this format will improve local storage, speedup '
        b'local operation and help to preserve storage quality and '
        b'performance during exchanges with other repositories.'
    )

    touches_filelogs: ClassVar[bool] = True
    touches_manifests: ClassVar[bool] = True
    touches_changelog: ClassVar[bool] = False


@registerformatvariant
class persistentnodemap(requirementformatvariant):
    name: ClassVar[bytes] = b'persistent-nodemap'

    _requirement: ClassVar[RequirementT] = requirements.NODEMAP_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'persist the node -> rev mapping on disk to speedup lookup'
    )

    upgrademessage: ClassVar[bytes] = _(b'Speedup revision lookup by node id.')


@registerformatvariant
class copiessdc(requirementformatvariant):
    name: ClassVar[bytes] = b'copies-sdc'

    _requirement: ClassVar[RequirementT] = requirements.COPIESSDC_REQUIREMENT

    default: ClassVar[bool] = False

    description: ClassVar[bytes] = _(
        b'Stores copies information alongside changesets.'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'Allows to use more efficient algorithm to deal with copy tracing.'
    )

    touches_filelogs: ClassVar[bool] = False
    touches_manifests: ClassVar[bool] = False


@registerformatvariant
class revlogv2(requirementformatvariant):
    name: ClassVar[bytes] = b'revlog-v2'
    _requirement: ClassVar[RequirementT] = requirements.REVLOGV2_REQUIREMENT
    default: ClassVar[bool] = False
    description: ClassVar[bytes] = _(b'Version 2 of the revlog.')
    upgrademessage: ClassVar[bytes] = _(b'very experimental')


@registerformatvariant
class changelogv2(requirementformatvariant):
    name: ClassVar[bytes] = b'changelog-v2'
    _requirement: ClassVar[RequirementT] = requirements.CHANGELOGV2_REQUIREMENT
    default: ClassVar[bool] = False
    description: ClassVar[bytes] = _(
        b'An iteration of the revlog focussed on changelog needs.'
    )
    upgrademessage: ClassVar[bytes] = _(b'quite experimental')

    touches_filelogs: ClassVar[bool] = False
    touches_manifests: ClassVar[bool] = False


@registerformatvariant
class removecldeltachain(formatvariant):
    name: ClassVar[bytes] = b'plain-cl-delta'

    default: ClassVar[bool] = True

    description: ClassVar[bytes] = _(
        b'changelog storage is using deltas instead of '
        b'raw entries; changelog reading and any '
        b'operation relying on changelog data are slower '
        b'than they could be'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'changelog storage will be reformated to '
        b'store raw entries; changelog reading will be '
        b'faster; changelog size may be reduced'
    )

    @staticmethod
    def fromrepo(repo: RepoT) -> bool:
        # Mercurial 4.0 changed changelogs to not use delta chains. Search for
        # changelogs with deltas.
        cl = repo.unfiltered().changelog
        if len(cl) <= 1000:
            some_rev = list(cl)
        else:
            # do a random sampling to speeds things up Scanning the whole
            # repository can get really slow on bigger repo.
            some_rev = sorted(
                {random.randint(0, len(cl) - 1) for x in range(1000)}
            )
        chainbase = cl.chainbase
        return all(rev == chainbase(rev) for rev in some_rev)

    @staticmethod
    def fromconfig(repo: RepoT) -> bool:
        return True


_has_zstd: Final[bool] = bool(
    b'zstd' in util.compengines
    and util.compengines[b'zstd'].available()
    and util.compengines[b'zstd'].revlogheader()
)


@registerformatvariant
class compressionengine(formatvariant):
    name: ClassVar[bytes] = b'compression'

    default: ClassVar[bytes] = b'zstd' if _has_zstd else b'zlib'

    description: ClassVar[bytes] = _(
        b'Compresion algorithm used to compress data. '
        b'Some engine are faster than other'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'revlog content will be recompressed with the new algorithm.'
    )

    @classmethod
    def fromrepo(cls, repo: RepoT) -> bytes:
        # we allow multiple compression engine requirement to co-exist because
        # strickly speaking, revlog seems to support mixed compression style.
        #
        # The compression used for new entries will be "the last one"
        compression = b'zlib'
        for req in repo.requirements:
            prefix = req.startswith
            if prefix(b'revlog-compression-') or prefix(b'exp-compression-'):
                compression = req.split(b'-', 2)[2]
        return compression

    @classmethod
    def fromconfig(cls, repo: RepoT) -> bytes:
        compengines = repo.ui.configlist(b'format', b'revlog-compression')
        # return the first valid value as the selection code would do
        for comp in compengines:
            if comp in util.compengines:
                e = util.compengines[comp]
                if e.available() and e.revlogheader():
                    return comp

        # no valide compression found lets display it all for clarity
        return b','.join(compengines)


@registerformatvariant
class compressionlevel(formatvariant):
    name: ClassVar[bytes] = b'compression-level'
    default: ClassVar[bytes] = b'default'

    description: ClassVar[bytes] = _(b'compression level')

    upgrademessage: ClassVar[bytes] = _(b'revlog content will be recompressed')

    @classmethod
    def fromrepo(cls, repo: RepoT) -> bytes:
        comp = compressionengine.fromrepo(repo)
        level = None
        if comp == b'zlib':
            level = repo.ui.configint(b'storage', b'revlog.zlib.level')
        elif comp == b'zstd':
            level = repo.ui.configint(b'storage', b'revlog.zstd.level')
        if level is None:
            return b'default'
        return b"%d" % level

    @classmethod
    def fromconfig(cls, repo: RepoT) -> bytes:
        comp = compressionengine.fromconfig(repo)
        level = None
        if comp == b'zlib':
            level = repo.ui.configint(b'storage', b'revlog.zlib.level')
        elif comp == b'zstd':
            level = repo.ui.configint(b'storage', b'revlog.zstd.level')
        if level is None:
            return b'default'
        return b"%d" % level


def find_format_upgrades(repo: RepoT):
    """returns a list of format upgrades which can be perform on the repo"""
    upgrades = []

    # We could detect lack of revlogv1 and store here, but they were added
    # in 0.9.2 and we don't support upgrading repos without these
    # requirements, so let's not bother.

    for fv in allformatvariant:
        if not fv.fromrepo(repo):
            upgrades.append(fv)

    return upgrades


def find_format_downgrades(repo: RepoT):
    """returns a list of format downgrades which will be performed on the repo
    because of disabled config option for them"""

    downgrades = []

    for fv in allformatvariant:
        if fv.name == b'compression':
            # If there is a compression change between repository
            # and config, destination repository compression will change
            # and current compression will be removed.
            if fv.fromrepo(repo) != fv.fromconfig(repo):
                downgrades.append(fv)
            continue
        # format variant exist in repo but does not exist in new repository
        # config
        if fv.fromrepo(repo) and not fv.fromconfig(repo):
            downgrades.append(fv)

    return downgrades


ALL_OPTIMISATIONS = []


def register_optimization(obj):
    ALL_OPTIMISATIONS.append(obj)
    return obj


class optimization(improvement):
    """an improvement subclass dedicated to optimizations"""

    type: ClassVar[bytes] = OPTIMISATION


@register_optimization
class ReDeltaQuick(optimization):
    name: ClassVar[bytes] = b're-delta-quick'

    type: ClassVar[bytes] = OPTIMISATION

    description: ClassVar[bytes] = _(
        b'deltas within internal storage will be reprocessed with minimal '
        b'overhead, deltas already in store will be reused as often as '
        b'possible. This provides a way to smooth out potential problematic '
        b'deltas while avoiding deeper but slower optimization that might '
        b'not be necessary'
    )

    upgrademessage: ClassVar[bytes] = _(
        b"deltas within internal storage will choose a new "
        b"base revision when the previous one wasn't suitable"
    )


@register_optimization
class redeltaparents(optimization):
    name: ClassVar[bytes] = b're-delta-parent'

    type: ClassVar[bytes] = OPTIMISATION

    description: ClassVar[bytes] = _(
        b'deltas within internal storage will be recalculated to '
        b'choose an optimal base revision where this was not '
        b'already done; the size of the repository may shrink and '
        b'various operations may become faster; the first time '
        b'this optimization is performed could slow down upgrade '
        b'execution considerably; subsequent invocations should '
        b'not run noticeably slower'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'deltas within internal storage will choose a new '
        b'base revision if needed'
    )


@register_optimization
class redeltamultibase(optimization):
    name: ClassVar[bytes] = b're-delta-multibase'

    type: ClassVar[bytes] = OPTIMISATION

    description: ClassVar[bytes] = _(
        b'deltas within internal storage will be recalculated '
        b'against multiple base revision and the smallest '
        b'difference will be used; the size of the repository may '
        b'shrink significantly when there are many merges; this '
        b'optimization will slow down execution in proportion to '
        b'the number of merges in the repository and the amount '
        b'of files in the repository; this slow down should not '
        b'be significant unless there are tens of thousands of '
        b'files and thousands of merges'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'deltas within internal storage will choose an '
        b'optimal delta by computing deltas against multiple '
        b'parents; may slow down execution time '
        b'significantly'
    )


@register_optimization
class redeltaall(optimization):
    name: ClassVar[bytes] = b're-delta-all'

    type: ClassVar[bytes] = OPTIMISATION

    description: ClassVar[bytes] = _(
        b'deltas within internal storage will always be '
        b'recalculated without reusing prior deltas; this will '
        b'likely make execution run several times slower; this '
        b'optimization is typically not needed'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'deltas within internal storage will be fully '
        b'recomputed; this will likely drastically slow down '
        b'execution time'
    )


@register_optimization
class redeltafulladd(optimization):
    name: ClassVar[bytes] = b're-delta-fulladd'

    type: ClassVar[bytes] = OPTIMISATION

    description: ClassVar[bytes] = _(
        b'every revision will be re-added as if it was new '
        b'content. It will go through the full storage '
        b'mechanism giving extensions a chance to process it '
        b'(eg. lfs). This is similar to "re-delta-all" but even '
        b'slower since more logic is involved.'
    )

    upgrademessage: ClassVar[bytes] = _(
        b'each revision will be added as new content to the '
        b'internal storage; this will likely drastically slow '
        b'down execution time, but some extensions might need '
        b'it'
    )


# TODO: UpgradeOperation lacks a repo object, and passes None here.  Either fix
#  that or drop the repo arg here?
def findoptimizations(repo: RepoT | None):
    """Determine optimisation that could be used during upgrade"""
    # These are unconditionally added. There is logic later that figures out
    # which ones to apply.
    return list(ALL_OPTIMISATIONS)


def determine_upgrade_actions(
    repo: RepoT,
    format_upgrades,
    optimizations,
    sourcereqs: RequirementSetT,
    destreqs: RequirementSetT,
):
    """Determine upgrade actions that will be performed.

    Given a list of improvements as returned by ``find_format_upgrades`` and
    ``findoptimizations``, determine the list of upgrade actions that
    will be performed.

    The role of this function is to filter improvements if needed, apply
    recommended optimizations from the improvements list that make sense,
    etc.

    Returns a list of action names.
    """
    newactions = []

    for d in format_upgrades:
        if hasattr(d, '_requirement'):
            name = d._requirement
        else:
            name = None

        # If the action is a requirement that doesn't show up in the
        # destination requirements, prune the action.
        if name is not None and name not in destreqs:
            continue

        newactions.append(d)

    newactions.extend(
        o
        for o in sorted(optimizations, key=(lambda x: x.name))
        if o not in newactions
    )

    # FUTURE consider adding some optimizations here for certain transitions.
    # e.g. adding generaldelta could schedule parent redeltas.

    return newactions


class BaseOperation:
    """base class that contains the minimum for an upgrade to work

    (this might need to be extended as the usage for subclass alternative to
    UpgradeOperation extends)
    """

    new_requirements: RequirementSetT

    def __init__(
        self,
        new_requirements: RequirementSetT,
        backup_store,
    ):
        self.new_requirements = new_requirements
        # should this operation create a backup of the store
        self.backup_store = backup_store


class UpgradeOperation(BaseOperation):
    """represent the work to be done during an upgrade"""

    def __init__(
        self,
        ui: UiT,
        new_requirements: RequirementSetT,
        current_requirements: RequirementSetT,
        upgrade_actions,
        removed_actions,
        revlogs_to_process,
        backup_store,
    ):
        super().__init__(
            new_requirements,
            backup_store,
        )
        self.ui = ui
        self.current_requirements = current_requirements
        # list of upgrade actions the operation will perform
        self.upgrade_actions = upgrade_actions
        self.removed_actions = removed_actions
        self.revlogs_to_process = revlogs_to_process
        # requirements which will be added by the operation
        self._added_requirements = (
            self.new_requirements - self.current_requirements
        )
        # requirements which will be removed by the operation
        self._removed_requirements = (
            self.current_requirements - self.new_requirements
        )
        # requirements which will be preserved by the operation
        self._preserved_requirements = (
            self.current_requirements & self.new_requirements
        )
        # optimizations which are not used and it's recommended that they
        # should use them
        all_optimizations = findoptimizations(None)
        self.unused_optimizations = [
            i for i in all_optimizations if i not in self.upgrade_actions
        ]

        # delta reuse mode of this upgrade operation
        upgrade_actions_names = self.upgrade_actions_names
        self.delta_reuse_mode = revlog.revlog.DELTAREUSEALWAYS
        if b're-delta-all' in upgrade_actions_names:
            self.delta_reuse_mode = revlog.revlog.DELTAREUSENEVER
        elif b're-delta-parent' in upgrade_actions_names:
            self.delta_reuse_mode = revlog.revlog.DELTAREUSESAMEREVS
        elif b're-delta-multibase' in upgrade_actions_names:
            self.delta_reuse_mode = revlog.revlog.DELTAREUSESAMEREVS
        elif b're-delta-fulladd' in upgrade_actions_names:
            self.delta_reuse_mode = revlog.revlog.DELTAREUSEFULLADD
        elif b're-delta-quick' in upgrade_actions_names:
            self.delta_reuse_mode = revlog.revlog.DELTAREUSEALWAYS

        # should this operation force re-delta of both parents
        self.force_re_delta_both_parents = (
            b're-delta-multibase' in upgrade_actions_names
        )

    @property
    def upgrade_actions_names(self) -> set[bytes]:
        return {a.name for a in self.upgrade_actions}

    @property
    def requirements_only(self) -> bool:
        # does the operation only touches repository requirement
        return (
            self.touches_requirements
            and not self.touches_filelogs
            and not self.touches_manifests
            and not self.touches_changelog
            and not self.touches_dirstate
        )

    @property
    def touches_filelogs(self) -> bool:
        for a in self.upgrade_actions:
            # in optimisations, we re-process the revlogs again
            if a.type == OPTIMISATION:
                return True
            elif a.touches_filelogs:
                return True
        for a in self.removed_actions:
            if a.touches_filelogs:
                return True
        return False

    @property
    def touches_manifests(self) -> bool:
        for a in self.upgrade_actions:
            # in optimisations, we re-process the revlogs again
            if a.type == OPTIMISATION:
                return True
            elif a.touches_manifests:
                return True
        for a in self.removed_actions:
            if a.touches_manifests:
                return True
        return False

    @property
    def touches_changelog(self) -> bool:
        for a in self.upgrade_actions:
            # in optimisations, we re-process the revlogs again
            if a.type == OPTIMISATION:
                return True
            elif a.touches_changelog:
                return True
        for a in self.removed_actions:
            if a.touches_changelog:
                return True
        return False

    @property
    def touches_requirements(self) -> bool | None:  # TODO: fix return paths
        for a in self.upgrade_actions:
            # optimisations are used to re-process revlogs and does not result
            # in a requirement being added or removed
            if a.type == OPTIMISATION:
                pass
            elif a.touches_requirements:
                return True
        for a in self.removed_actions:
            if a.touches_requirements:
                return True

    @property
    def touches_dirstate(self) -> bool:
        for a in self.upgrade_actions:
            # revlog optimisations do not affect the dirstate
            if a.type == OPTIMISATION:
                pass
            elif a.touches_dirstate:
                return True
        for a in self.removed_actions:
            if a.touches_dirstate:
                return True

        return False

    def _write_labeled(self, l, label: bytes) -> None:
        """
        Utility function to aid writing of a list under one label
        """
        first = True
        for r in sorted(l):
            if not first:
                self.ui.write(b', ')
            self.ui.write(r, label=label)
            first = False

    def print_requirements(self) -> None:
        self.ui.write(_(b'requirements\n'))
        self.ui.write(_(b'   preserved: '))
        self._write_labeled(
            self._preserved_requirements, b"upgrade-repo.requirement.preserved"
        )
        self.ui.writenoi18n(b'\n')
        if self._removed_requirements:
            self.ui.write(_(b'   removed: '))
            self._write_labeled(
                self._removed_requirements, b"upgrade-repo.requirement.removed"
            )
            self.ui.writenoi18n(b'\n')
        if self._added_requirements:
            self.ui.write(_(b'   added: '))
            self._write_labeled(
                self._added_requirements, b"upgrade-repo.requirement.added"
            )
            self.ui.writenoi18n(b'\n')
        self.ui.write(b'\n')

    def print_optimisations(self) -> None:
        optimisations = [
            a for a in self.upgrade_actions if a.type == OPTIMISATION
        ]
        optimisations.sort(key=lambda a: a.name)
        if optimisations:
            self.ui.write(_(b'optimisations: '))
            self._write_labeled(
                [a.name for a in optimisations],
                b"upgrade-repo.optimisation.performed",
            )
            self.ui.write(b'\n\n')

    def print_upgrade_actions(self) -> None:
        for a in self.upgrade_actions:
            self.ui.status(b'%s\n   %s\n\n' % (a.name, a.upgrademessage))

    def print_affected_revlogs(self) -> None:
        if not self.revlogs_to_process:
            self.ui.writenoi18n(b'no revlogs to process\n')
        else:
            self.ui.writenoi18n(b'processed revlogs:\n')
            for r in sorted(self.revlogs_to_process):
                self.ui.writenoi18n(b'  - %s\n' % r)
        self.ui.writenoi18n(b'\n')

    def print_unused_optimizations(self) -> None:
        for i in self.unused_optimizations:
            self.ui.status(_(b'%s\n   %s\n\n') % (i.name, i.description))

    def has_upgrade_action(self, name: bytes) -> bool:
        """Check whether the upgrade operation will perform this action"""
        return name in self.upgrade_actions_names

    def print_post_op_messages(self) -> None:
        """print post upgrade operation warning messages"""
        for a in self.upgrade_actions:
            if a.postupgrademessage is not None:
                self.ui.warn(b'%s\n' % a.postupgrademessage)
        for a in self.removed_actions:
            if a.postdowngrademessage is not None:
                self.ui.warn(b'%s\n' % a.postdowngrademessage)


###  Code checking if a repository can got through the upgrade process at all. #


def requiredsourcerequirements(repo: RepoT) -> RequirementSetT:
    """Obtain requirements required to be present to upgrade a repo.

    An upgrade will not be allowed if the repository doesn't have the
    requirements returned by this function.
    """
    return {
        # Introduced in Mercurial 0.9.2.
        requirements.STORE_REQUIREMENT,
    }


def blocksourcerequirements(repo: RepoT) -> RequirementSetT:
    """Obtain requirements that will prevent an upgrade from occurring.

    An upgrade cannot be performed if the source repository contains a
    requirements in the returned set.
    """
    return {
        # This was a precursor to generaldelta and was never enabled by default.
        # It should (hopefully) not exist in the wild.
        b'parentdelta',
    }


def check_revlog_version(reqs: RequirementSetT) -> None:
    """Check that the requirements contain at least one Revlog version"""
    all_revlogs = {
        requirements.REVLOGV1_REQUIREMENT,
        requirements.REVLOGV2_REQUIREMENT,
    }
    if not all_revlogs.intersection(reqs):
        msg = _(b'cannot upgrade repository; missing a revlog version')
        raise error.Abort(msg)


def check_source_requirements(repo: RepoT) -> None:
    """Ensure that no existing requirements prevent the repository upgrade"""

    check_revlog_version(repo.requirements)
    required = requiredsourcerequirements(repo)
    missingreqs = required - repo.requirements
    if missingreqs:
        msg = _(b'cannot upgrade repository; requirement missing: %s')
        missingreqs = b', '.join(sorted(missingreqs))
        raise error.Abort(msg % missingreqs)

    blocking = blocksourcerequirements(repo)
    blockingreqs = blocking & repo.requirements
    if blockingreqs:
        m = _(b'cannot upgrade repository; unsupported source requirement: %s')
        blockingreqs = b', '.join(sorted(blockingreqs))
        raise error.Abort(m % blockingreqs)
    # Upgrade should operate on the actual store, not the shared link.

    bad_share = (
        requirements.SHARED_REQUIREMENT in repo.requirements
        and requirements.SHARESAFE_REQUIREMENT not in repo.requirements
    )
    if bad_share:
        m = _(b'cannot upgrade repository; share repository without share-safe')
        h = _(b'check :hg:`help config.format.use-share-safe`')
        raise error.Abort(m, hint=h)


### Verify the validity of the planned requirement changes ####################


def supportremovedrequirements(
    repo: RepoT, new_reqs: RequirementSetT
) -> RequirementSetT:
    """Obtain requirements that can be removed during an upgrade.

    If an upgrade were to create a repository that dropped a requirement,
    the dropped requirement must appear in the returned set for the upgrade
    to be allowed.
    """
    supported = {
        requirements.CHANGELOGV2_REQUIREMENT,
        requirements.COPIESSDC_REQUIREMENT,
        requirements.DELTA_INFO_REQUIREMENT,
        requirements.DIRSTATE_TRACKED_HINT_V1,
        requirements.DIRSTATE_V2_REQUIREMENT,
        requirements.DOTENCODE_REQUIREMENT,
        requirements.FILELOG_METAFLAG_REQUIREMENT,
        requirements.NODEMAP_REQUIREMENT,
        requirements.PLAIN_ENCODE_REQUIREMENT,
        requirements.REVLOGV1_REQUIREMENT,
        requirements.REVLOGV2_REQUIREMENT,
        requirements.SHARESAFE_REQUIREMENT,
        requirements.SPARSEREVLOG_REQUIREMENT,
    }
    if requirements.FILEINDEXV1_REQUIREMENT in new_reqs:
        supported.add(requirements.FNCACHE_REQUIREMENT)
    elif requirements.FNCACHE_REQUIREMENT in new_reqs:
        supported.add(requirements.FILEINDEXV1_REQUIREMENT)
    for name in compression.compengines:
        engine = compression.compengines[name]
        if engine.available() and engine.revlogheader():
            supported.add(b'exp-compression-%s' % name)
            if engine.name() == b'zstd':
                supported.add(b'revlog-compression-zstd')
    return supported


def supporteddestrequirements(repo: RepoT) -> RequirementSetT:
    """Obtain requirements that upgrade supports in the destination.

    If the result of the upgrade would have requirements not in this set,
    the upgrade is disallowed.

    Extensions should monkeypatch this to add their custom requirements.
    """
    supported = {
        requirements.CHANGELOGV2_REQUIREMENT,
        requirements.COPIESSDC_REQUIREMENT,
        requirements.DELTA_INFO_REQUIREMENT,
        requirements.DIRSTATE_TRACKED_HINT_V1,
        requirements.DIRSTATE_V2_REQUIREMENT,
        requirements.DOTENCODE_REQUIREMENT,
        requirements.FILEINDEXV1_REQUIREMENT,
        requirements.FILELOG_METAFLAG_REQUIREMENT,
        requirements.FNCACHE_REQUIREMENT,
        requirements.GENERALDELTA_REQUIREMENT,
        requirements.NARROW_REQUIREMENT,
        requirements.NODEMAP_REQUIREMENT,
        requirements.PLAIN_ENCODE_REQUIREMENT,
        requirements.REVLOGV1_REQUIREMENT,  # allowed in case of downgrade
        requirements.REVLOGV2_REQUIREMENT,
        requirements.SHARED_REQUIREMENT,
        requirements.SHARESAFE_REQUIREMENT,
        requirements.SPARSEREVLOG_REQUIREMENT,
        requirements.STORE_REQUIREMENT,
        requirements.TREEMANIFEST_REQUIREMENT,
    }
    for name in compression.compengines:
        engine = compression.compengines[name]
        if engine.available() and engine.revlogheader():
            supported.add(b'exp-compression-%s' % name)
            if engine.name() == b'zstd':
                supported.add(b'revlog-compression-zstd')
    return supported


def allowednewrequirements(repo: RepoT) -> RequirementSetT:
    """Obtain requirements that can be added to a repository during upgrade.

    This is used to disallow proposed requirements from being added when
    they weren't present before.

    We use a list of allowed requirement additions instead of a list of known
    bad additions because the whitelist approach is safer and will prevent
    future, unknown requirements from accidentally being added.
    """
    supported = {
        requirements.CHANGELOGV2_REQUIREMENT,
        requirements.COPIESSDC_REQUIREMENT,
        requirements.DELTA_INFO_REQUIREMENT,
        requirements.DIRSTATE_TRACKED_HINT_V1,
        requirements.DIRSTATE_V2_REQUIREMENT,
        requirements.DOTENCODE_REQUIREMENT,
        requirements.FILEINDEXV1_REQUIREMENT,
        requirements.FILELOG_METAFLAG_REQUIREMENT,
        requirements.FNCACHE_REQUIREMENT,
        requirements.GENERALDELTA_REQUIREMENT,
        requirements.NODEMAP_REQUIREMENT,
        requirements.PLAIN_ENCODE_REQUIREMENT,
        requirements.REVLOGV1_REQUIREMENT,
        requirements.REVLOGV2_REQUIREMENT,
        requirements.SHARESAFE_REQUIREMENT,
        requirements.SPARSEREVLOG_REQUIREMENT,
    }
    for name in compression.compengines:
        engine = compression.compengines[name]
        if engine.available() and engine.revlogheader():
            supported.add(b'exp-compression-%s' % name)
            if engine.name() == b'zstd':
                supported.add(b'revlog-compression-zstd')
    return supported


def check_requirements_changes(repo: RepoT, new_reqs: RequirementSetT) -> None:
    old_reqs = repo.requirements
    check_revlog_version(repo.requirements)
    support_removal = supportremovedrequirements(repo, new_reqs)
    no_remove_reqs = old_reqs - new_reqs - support_removal
    if no_remove_reqs:
        msg = _(b'cannot upgrade repository; requirement would be removed: %s')
        no_remove_reqs = b', '.join(sorted(no_remove_reqs))
        raise error.Abort(msg % no_remove_reqs)

    support_addition = allowednewrequirements(repo)
    no_add_reqs = new_reqs - old_reqs - support_addition
    if no_add_reqs:
        m = _(b'cannot upgrade repository; do not support adding requirement: ')
        no_add_reqs = b', '.join(sorted(no_add_reqs))
        raise error.Abort(m + no_add_reqs)

    supported = supporteddestrequirements(repo)
    unsupported_reqs = new_reqs - supported
    if unsupported_reqs:
        msg = _(
            b'cannot upgrade repository; do not support destination '
            b'requirement: %s'
        )
        unsupported_reqs = b', '.join(sorted(unsupported_reqs))
        raise error.Abort(msg % unsupported_reqs)
