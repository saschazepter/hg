# merge_utils - collection of logic around merging and updating the working copy
#
# Copyright 2006, 2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import weakref


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

    ALL_ACTIONS = weakref.WeakSet()
    NO_OP_ACTIONS = weakref.WeakSet()

    def __init__(self, short, no_op=False, narrow_safe=False, changes=None):
        self._short = short
        self.ALL_ACTIONS.add(self)
        self.no_op = no_op
        if self.no_op:
            self.NO_OP_ACTIONS.add(self)
        self.narrow_safe = narrow_safe
        self.changes = changes

    def __hash__(self):
        return hash(self._short)

    def __repr__(self):
        return 'MergeAction<%s>' % self._short.decode('ascii')

    def __bytes__(self):
        return self._short

    def __eq__(self, other):
        if other is None:
            return False
        assert isinstance(other, MergeAction)
        return self._short == other._short

    def __lt__(self, other):
        return self._short < other._short


CHANGE_ADDED = b'added'
CHANGE_REMOVED = b'removed'
CHANGE_MODIFIED = b'modified'

ACTION_FORGET = MergeAction(b'f', narrow_safe=True, changes=CHANGE_REMOVED)
ACTION_REMOVE = MergeAction(b'r', narrow_safe=True, changes=CHANGE_REMOVED)
ACTION_ADD = MergeAction(b'a', narrow_safe=True, changes=CHANGE_ADDED)
ACTION_GET = MergeAction(b'g', narrow_safe=True, changes=CHANGE_MODIFIED)
ACTION_PATH_CONFLICT = MergeAction(b'p')
ACTION_PATH_CONFLICT_RESOLVE = MergeAction(b'pr')
ACTION_ADD_MODIFIED = MergeAction(
    b'am', narrow_safe=True, changes=CHANGE_ADDED
)  # not 100% about the changes value here
ACTION_CREATED = MergeAction(b'c', narrow_safe=True, changes=CHANGE_ADDED)
ACTION_DELETED_CHANGED = MergeAction(b'dc')
ACTION_CHANGED_DELETED = MergeAction(b'cd')
ACTION_MERGE = MergeAction(b'm')
ACTION_LOCAL_DIR_RENAME_GET = MergeAction(b'dg')
ACTION_DIR_RENAME_MOVE_LOCAL = MergeAction(b'dm')
ACTION_KEEP = MergeAction(b'k', no_op=True)
# the file was absent on local side before merge and we should
# keep it absent (absent means file not present, it can be a result
# of file deletion, rename etc.)
ACTION_KEEP_ABSENT = MergeAction(b'ka', no_op=True)
# the file is absent on the ancestor and remote side of the merge
# hence this file is new and we should keep it
ACTION_KEEP_NEW = MergeAction(b'kn', no_op=True)
ACTION_EXEC = MergeAction(b'e', narrow_safe=True, changes=CHANGE_MODIFIED)
ACTION_CREATED_MERGE = MergeAction(
    b'cm', narrow_safe=True, changes=CHANGE_ADDED
)
