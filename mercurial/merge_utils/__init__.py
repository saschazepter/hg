# merge_utils - collection of logic around merging and updating the working copy
#
# Copyright 2006, 2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import collections
import typing
import weakref

if typing.TYPE_CHECKING:
    from typing import (
        ClassVar,
        Final,
    )


class MergeAction:
    """represent an "action" merge need to take for a given file

    Attributes:

    _short: internal representation used to identify each action

    no_op:  True if the action does affect the file content or tracking status

    narrow_safe:
        True if the action can be safely used for a file outside of the narrow
        set

    changes:
        The types of changes that this actions involves. This is a work in
        progress and not all actions have one yet. In addition, some requires
        user changes and cannot be fully decided. The value currently available
        are:

        - ADDED: the files is new in both parents
        - REMOVED: the files existed in one parent and is getting removed
        - MODIFIED: the files existed in at least one parent and is getting
          changed
    """

    _short: bytes
    no_op: bool
    narrow_safe: bool
    changes: bytes | None

    ALL_ACTIONS: ClassVar[weakref.WeakSet[MergeAction]] = weakref.WeakSet()
    NO_OP_ACTIONS: ClassVar[weakref.WeakSet[MergeAction]] = weakref.WeakSet()

    def __init__(
        self,
        short: bytes,
        no_op: bool = False,
        narrow_safe: bool = False,
        changes: bytes | None = None,
    ) -> None:
        self._short = short
        self.ALL_ACTIONS.add(self)
        self.no_op = no_op
        if self.no_op:
            self.NO_OP_ACTIONS.add(self)
        self.narrow_safe = narrow_safe
        self.changes = changes

    def __hash__(self) -> int:
        return hash(self._short)

    def __repr__(self) -> str:
        return 'MergeAction<%s>' % self._short.decode('ascii')

    def __bytes__(self) -> bytes:
        return self._short

    def __eq__(self, other) -> bool:
        if other is None:
            return False
        assert isinstance(other, MergeAction)
        return self._short == other._short

    def __lt__(self, other: MergeAction) -> bool:
        return self._short < other._short


CHANGE_ADDED: Final[bytes] = b'added'
CHANGE_REMOVED: Final[bytes] = b'removed'
CHANGE_MODIFIED: Final[bytes] = b'modified'

ACTION_FORGET: Final[MergeAction] = MergeAction(
    b'f', narrow_safe=True, changes=CHANGE_REMOVED
)
ACTION_REMOVE: Final[MergeAction] = MergeAction(
    b'r', narrow_safe=True, changes=CHANGE_REMOVED
)
ACTION_ADD: Final[MergeAction] = MergeAction(
    b'a', narrow_safe=True, changes=CHANGE_ADDED
)
ACTION_GET: Final[MergeAction] = MergeAction(
    b'g', narrow_safe=True, changes=CHANGE_MODIFIED
)
ACTION_PATH_CONFLICT: Final[MergeAction] = MergeAction(b'p')
ACTION_PATH_CONFLICT_RESOLVE: Final[MergeAction] = MergeAction(b'pr')
ACTION_ADD_MODIFIED: Final[MergeAction] = MergeAction(
    b'am', narrow_safe=True, changes=CHANGE_ADDED
)  # not 100% about the changes value here
ACTION_CREATED: Final[MergeAction] = MergeAction(
    b'c', narrow_safe=True, changes=CHANGE_ADDED
)
ACTION_DELETED_CHANGED: Final[MergeAction] = MergeAction(b'dc')
ACTION_CHANGED_DELETED: Final[MergeAction] = MergeAction(b'cd')
ACTION_MERGE: Final[MergeAction] = MergeAction(b'm')
ACTION_LOCAL_DIR_RENAME_GET: Final[MergeAction] = MergeAction(b'dg')
ACTION_DIR_RENAME_MOVE_LOCAL: Final[MergeAction] = MergeAction(b'dm')
ACTION_KEEP: Final[MergeAction] = MergeAction(b'k', no_op=True)
# the file was absent on local side before merge and we should
# keep it absent (absent means file not present, it can be a result
# of file deletion, rename etc.)
ACTION_KEEP_ABSENT: Final[MergeAction] = MergeAction(b'ka', no_op=True)
# the file is absent on the ancestor and remote side of the merge
# hence this file is new and we should keep it
ACTION_KEEP_NEW: Final[MergeAction] = MergeAction(b'kn', no_op=True)
ACTION_EXEC: Final[MergeAction] = MergeAction(
    b'e', narrow_safe=True, changes=CHANGE_MODIFIED
)
ACTION_CREATED_MERGE: Final[MergeAction] = MergeAction(
    b'cm', narrow_safe=True, changes=CHANGE_ADDED
)

if typing.TYPE_CHECKING:
    from typing import Iterable, Iterator, Optional

    # TODO: figure out what exactly is in this tuple
    MergeResultData = tuple
    MergeResultAction = tuple[bytes, Optional[MergeResultData], bytes]
    """The filename, data about the merge, and message about the merge."""

    FileMappingValue = tuple[MergeAction, Optional[MergeResultData], bytes]
    """The merge action, data about the merge, and message about the merge, for
    the keyed file."""


class MergeResult:
    """An object representing result of merging manifests.

    It has information about what actions need to be performed on dirstate
    mapping of divergent renames and other such cases."""

    _filemapping: dict[bytes, FileMappingValue]
    _actionmapping: dict[
        MergeAction, dict[bytes, tuple[MergeResultData, bytes]]
    ]

    def __init__(self) -> None:
        """
        filemapping: dict of filename as keys and action related info as values
        diverge: mapping of source name -> list of dest name for
                 divergent renames
        renamedelete: mapping of source name -> list of destinations for files
                      deleted on one side and renamed on other.
        commitinfo: dict containing data which should be used on commit
                    contains a filename -> info mapping
        actionmapping: dict of action names as keys and values are dict of
                       filename as key and related data as values
        """
        self._filemapping = {}
        self._diverge = {}
        self._renamedelete = {}
        self._commitinfo = collections.defaultdict(dict)
        self._actionmapping = collections.defaultdict(dict)

    def updatevalues(self, diverge, renamedelete):
        self._diverge = diverge
        self._renamedelete = renamedelete

    def addfile(
        self,
        filename: bytes,
        action: MergeAction,
        data: MergeResultData | None,
        message,
    ) -> None:
        """adds a new file to the MergeResult object

        filename: file which we are adding
        action: one of ACTION_*
        data: a tuple of information like fctx and ctx related to this merge
        message: a message about the merge
        """
        # if the file already existed, we need to delete it's old
        # entry form _actionmapping too
        if filename in self._filemapping:
            a, d, m = self._filemapping[filename]
            del self._actionmapping[a][filename]

        self._filemapping[filename] = (action, data, message)
        self._actionmapping[action][filename] = (data, message)

    def mapaction(
        self,
        actionfrom: MergeAction,
        actionto: MergeAction,
        transform,
    ):
        """changes all occurrences of action `actionfrom` into `actionto`,
        transforming its args with the function `transform`.
        """
        orig = self._actionmapping[actionfrom]
        del self._actionmapping[actionfrom]
        dest = self._actionmapping[actionto]
        for f, (data, msg) in orig.items():
            data = transform(f, data)
            self._filemapping[f] = (actionto, data, msg)
            dest[f] = (data, msg)

    def getfile(
        self, filename: bytes, default_return: FileMappingValue | None = None
    ) -> FileMappingValue | None:
        """returns (action, args, msg) about this file

        returns default_return if the file is not present"""
        if filename in self._filemapping:
            return self._filemapping[filename]
        return default_return

    def files(
        self, actions: Iterable[MergeAction] | None = None
    ) -> Iterator[bytes]:
        """returns files on which provided action needs to perfromed

        If actions is None, all files are returned
        """
        # TODO: think whether we should return renamedelete and
        # diverge filenames also
        if actions is None:
            yield from self._filemapping

        else:
            for a in actions:
                yield from self._actionmapping[a]

    def removefile(self, filename: bytes) -> None:
        """removes a file from the MergeResult object as the file might
        not merging anymore"""
        action, data, message = self._filemapping[filename]
        del self._filemapping[filename]
        del self._actionmapping[action][filename]

    def getactions(
        self, actions: Iterable[MergeAction], sort: bool = False
    ) -> Iterator[MergeResultAction]:
        """get list of files which are marked with these actions
        if sort is true, files for each action is sorted and then added

        Returns a list of tuple of form (filename, data, message)
        """
        for a in actions:
            if sort:
                for f in sorted(self._actionmapping[a]):
                    args, msg = self._actionmapping[a][f]
                    yield f, args, msg
            else:
                for f, (args, msg) in self._actionmapping[a].items():
                    yield f, args, msg

    def len(self, actions: Iterable[MergeAction] | None = None) -> int:
        """returns number of files which needs actions

        if actions is passed, total of number of files in that action
        only is returned"""

        if actions is None:
            return len(self._filemapping)

        return sum(len(self._actionmapping[a]) for a in actions)

    def filemap(
        self, sort: bool = False
    ) -> Iterator[tuple[bytes, MergeResultData]]:
        if sort:
            yield from sorted(self._filemapping.items())
        else:
            yield from self._filemapping.items()

    def addcommitinfo(self, filename: bytes, key, value) -> None:
        """adds key-value information about filename which will be required
        while committing this merge"""
        self._commitinfo[filename][key] = value

    @property
    def diverge(self):
        return self._diverge

    @property
    def renamedelete(self):
        return self._renamedelete

    @property
    def commitinfo(self):
        return self._commitinfo

    @property
    def actionsdict(
        self,
    ) -> dict[MergeAction, list[MergeResultAction]]:
        """returns a dictionary of actions to be perfomed with action as key
        and a list of files and related arguments as values"""
        res = collections.defaultdict(list)
        for a, d in self._actionmapping.items():
            for f, (args, msg) in d.items():
                res[a].append((f, args, msg))
        return res

    def setactions(self, actions) -> None:
        self._filemapping = actions
        self._actionmapping = collections.defaultdict(dict)
        for f, (act, data, msg) in self._filemapping.items():
            self._actionmapping[act][f] = data, msg

    def hasconflicts(self) -> bool:
        """tells whether this merge resulted in some actions which can
        result in conflicts or not"""
        for a in self._actionmapping.keys():
            if (
                a
                not in (
                    ACTION_GET,
                    ACTION_EXEC,
                    ACTION_REMOVE,
                    ACTION_PATH_CONFLICT_RESOLVE,
                )
                and self._actionmapping[a]
                and not a.no_op
            ):
                return True

        return False
