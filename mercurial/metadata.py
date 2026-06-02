# metadata.py -- code related to various metadata computation and access.
#
# Copyright 2019 Google, Inc <martinvonz@google.com>
# Copyright 2020 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import struct

from .interfaces.types import (
    HgPathT,
)
from .node import nullrev
from . import (
    error,
    util,
)
from .interfaces import (
    revlog as rl_t,
)


class ChangingFiles(rl_t.IChangedFiles):
    """A class recording the changes made to files by a changeset

    Actions performed on files are gathered into 3 sets:

    - added:   files actively added in the changeset.
    - merged:  files whose history got merged
    - removed: files removed in the revision
    - salvaged: files that might have been deleted by a merge but were not
    - touched: files affected by the merge

    and copies information is held by 2 mappings

    - copied_from_p1: {"<new-name>": "<source-name-in-p1>"} mapping for copies
    - copied_from_p2: {"<new-name>": "<source-name-in-p2>"} mapping for copies

    See their inline help for details.
    """

    def __init__(
        self,
        touched=None,
        added=None,
        removed=None,
        merged=None,
        salvaged=None,
        p1_copies=None,
        p2_copies=None,
    ):
        self._added = set(() if added is None else added)
        self._merged = set(() if merged is None else merged)
        self._removed = set(() if removed is None else removed)
        self._touched = set(() if touched is None else touched)
        self._salvaged = set(() if salvaged is None else salvaged)
        self._touched.update(self._added)
        self._touched.update(self._merged)
        self._touched.update(self._removed)
        self._p1_copies = dict(() if p1_copies is None else p1_copies)
        self._p2_copies = dict(() if p2_copies is None else p2_copies)

    def __bool__(self):
        return bool(self._touched)

    def __eq__(self, other):
        return (
            self.added == other.added
            and self.merged == other.merged
            and self.removed == other.removed
            and self.salvaged == other.salvaged
            and self.touched == other.touched
            and self.copied_from_p1 == other.copied_from_p1
            and self.copied_from_p2 == other.copied_from_p2
        )

    @property
    def has_copies_info(self):
        return bool(
            self.removed
            or self.merged
            or self.salvaged
            or self.copied_from_p1
            or self.copied_from_p2
        )

    @util.propertycache
    def added(self) -> frozenset[HgPathT]:
        """files actively added in the changeset

        Any file present in that revision that was absent in all the changeset's
        parents.

        In case of merge, this means a file absent in one of the parents but
        existing in the other will *not* be contained in this set. (They were
        added by an ancestor)
        """
        return frozenset(self._added)

    def mark_added(self, filename):
        if 'added' in vars(self):
            del self.added
        self._added.add(filename)
        self.mark_touched(filename)

    def update_added(self, filenames):
        for f in filenames:
            self.mark_added(f)

    @util.propertycache
    def merged(self) -> frozenset[HgPathT]:
        """files actively merged during a merge

        Any modified files which had modification on both size that needed merging.

        In this case a new filenode was created and it has two parents.
        """
        return frozenset(self._merged)

    def mark_merged(self, filename):
        if 'merged' in vars(self):
            del self.merged
        self._merged.add(filename)
        self.mark_touched(filename)

    def update_merged(self, filenames):
        for f in filenames:
            self.mark_merged(f)

    @util.propertycache
    def removed(self) -> frozenset[HgPathT]:
        """files actively removed by the changeset

        In case of merge this will only contain the set of files removing "new"
        content. For any file absent in the current changeset:

        a) If the file exists in both parents, it is clearly "actively" removed
        by this changeset.

        b) If a file exists in only one parent and in none of the common
        ancestors, then the file was newly added in one of the merged branches
        and then got "actively" removed.

        c) If a file exists in only one parent and at least one of the common
        ancestors using the same filenode, then the file was unchanged on one
        side and deleted on the other side. The merge "passively" propagated
        that deletion, but didn't "actively" remove the file. In this case the
        file is *not* included in the `removed` set.

        d) If a file exists in only one parent and at least one of the common
        ancestors using a different filenode, then the file was changed on one
        side and removed on the other side. The merge process "actively"
        decided to drop the new change and delete the file. Unlike in the
        previous case, (c), the file included in the `removed` set.

        Summary table for merge:

        case | exists in parents | exists in gca || removed
         (a) |       both        |     *         ||   yes
         (b) |       one         |     none      ||   yes
         (c) |       one         | same filenode ||   no
         (d) |       one         |  new filenode ||   yes
        """
        return frozenset(self._removed)

    def mark_removed(self, filename):
        if 'removed' in vars(self):
            del self.removed
        self._removed.add(filename)
        self.mark_touched(filename)

    def update_removed(self, filenames):
        for f in filenames:
            self.mark_removed(f)

    @util.propertycache
    def salvaged(self) -> frozenset[HgPathT]:
        """files that might have been deleted by a merge, but still exists.

        During a merge, the manifest merging might select some files for
        removal, or for a removed/changed conflict. If at commit time the file
        still exists, its removal was "reverted" and the file is "salvaged"
        """
        return frozenset(self._salvaged)

    def mark_salvaged(self, filename):
        if "salvaged" in vars(self):
            del self.salvaged
        self._salvaged.add(filename)
        self.mark_touched(filename)

    def update_salvaged(self, filenames):
        for f in filenames:
            self.mark_salvaged(f)

    @util.propertycache
    def touched(self) -> frozenset[HgPathT]:
        """files either actively modified, added or removed"""
        return frozenset(self._touched)

    def mark_touched(self, filename):
        if 'touched' in vars(self):
            del self.touched
        self._touched.add(filename)

    def update_touched(self, filenames):
        for f in filenames:
            self.mark_touched(f)

    @util.propertycache
    def copied_from_p1(self) -> dict[HgPathT, HgPathT]:
        return self._p1_copies.copy()

    def mark_copied_from_p1(self, source, dest):
        if 'copied_from_p1' in vars(self):
            del self.copied_from_p1
        self._p1_copies[dest] = source

    def update_copies_from_p1(self, copies):
        for dest, source in copies.items():
            self.mark_copied_from_p1(source, dest)

    @util.propertycache
    def copied_from_p2(self) -> dict[HgPathT, HgPathT]:
        return self._p2_copies.copy()

    def mark_copied_from_p2(self, source, dest):
        if 'copied_from_p2' in vars(self):
            del self.copied_from_p2
        self._p2_copies[dest] = source

    def update_copies_from_p2(self, copies):
        for dest, source in copies.items():
            self.mark_copied_from_p2(source, dest)


def compute_all_files_changes(ctx):
    """compute the files changed by a revision"""
    p1 = ctx.p1()
    p2 = ctx.p2()
    if p1.rev() == nullrev and p2.rev() == nullrev:
        return _process_root(ctx)
    elif p1.rev() != nullrev and p2.rev() == nullrev:
        return _process_linear(p1, ctx)
    elif p1.rev() == nullrev and p2.rev() != nullrev:
        # In the wild, one can encounter changeset where p1 is null but p2 is not
        return _process_linear(p2, ctx, parent=2)
    elif p1.rev() == p2.rev():
        # In the wild, one can encounter such "non-merge"
        return _process_linear(p1, ctx)
    else:
        return _process_merge(p1, p2, ctx)


def _process_root(ctx):
    """compute the appropriate changed files for a changeset with no parents"""
    # Simple, there was nothing before it, so everything is added.
    md = ChangingFiles()
    manifest = ctx.manifest()
    for filename in manifest:
        md.mark_added(filename)
    return md


def _process_linear(parent_ctx, children_ctx, parent=1):
    """compute the appropriate changed files for a changeset with a single parent"""
    md = ChangingFiles()
    parent_manifest = parent_ctx.manifest()
    children_manifest = children_ctx.manifest()

    copies_candidate = []

    for filename, d in parent_manifest.diff(children_manifest).items():
        if d[1][0] is None:
            # no filenode for the "new" value, file is absent
            md.mark_removed(filename)
        else:
            copies_candidate.append(filename)
            if d[0][0] is None:
                # not filenode for the "old" value file was absent
                md.mark_added(filename)
            else:
                # filenode for both "old" and "new"
                md.mark_touched(filename)

    if parent == 1:
        copied = md.mark_copied_from_p1
    elif parent == 2:
        copied = md.mark_copied_from_p2
    else:
        assert False, "bad parent value %d" % parent

    for filename in copies_candidate:
        copy_info = children_ctx[filename].renamed()
        if copy_info:
            source, srcnode = copy_info
            copied(source, filename)

    return md


def _process_merge(p1_ctx, p2_ctx, ctx):
    """compute the appropriate changed files for a changeset with two parents

    This is a more advance case. The information we need to record is summarise
    in the following table:

    ┌──────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
    │ diff ╲  diff │       ø      │ (Some, None) │ (None, Some) │ (Some, Some) │
    │  p2   ╲  p1  │              │              │              │              │
    ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┤
    │              │              │🄱  No Changes │🄳  No Changes │              │
    │  ø           │🄰  No Changes │      OR      │     OR       │🄵  No Changes │
    │              │              │🄲  Deleted[1] │🄴  Salvaged[2]│     [3]      │
    ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┤
    │              │🄶  No Changes │              │              │              │
    │ (Some, None) │      OR      │🄻  Deleted    │       ø      │      ø       │
    │              │🄷  Deleted[1] │              │              │              │
    ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┤
    │              │🄸  No Changes │              │              │   🄽 Touched  │
    │ (None, Some) │     OR       │      ø       │🄼   Added     │OR 🅀 Salvaged │
    │              │🄹  Salvaged[2]│              │   (copied?)  │   (copied?)  │
    ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┤
    │              │              │              │   🄾 Touched  │   🄿 Merged   │
    │ (Some, Some) │🄺  No Changes │      ø       │OR 🅁 Salvaged │OR 🅂 Touched  │
    │              │     [3]      │              │   (copied?)  │   (copied?)  │
    └──────────────┴──────────────┴──────────────┴──────────────┴──────────────┘

    Special case [1]:

      The situation is:
        - parent-A:     file exists,
        - parent-B:     no file,
        - working-copy: no file.

      Detecting a "deletion" will depend on the presence of actual change on
      the "parent-A" branch:

      Subcase 🄱 or 🄶 : if the state of the file in "parent-A" is unchanged
      compared to the merge ancestors, then parent-A branch left the file
      untouched while parent-B deleted it. We simply apply the change from
      "parent-B" branch the file was automatically dropped.
      The result is:
          - file is not recorded as touched by the merge.

      Subcase 🄲 or 🄷 : otherwise, the change from parent-A branch were explicitly dropped and
      the file was "deleted again". From a user perspective, the message
      about "locally changed" while "remotely deleted" (or the other way
      around) was issued and the user chose to deleted the file.
      The result:
          - file is recorded as touched by the merge.


    Special case [2]:

      The situation is:
        - parent-A:     no file,
        - parent-B:     file,
        - working-copy: file (same content as parent-B).

      There are three subcases depending on the ancestors contents:

      - A) the file is missing in all ancestors,
      - B) at least one ancestor has the file with filenode ≠ from parent-B,
      - C) all ancestors use the same filenode as parent-B,

      Subcase (A) is the simpler, nothing happend on parent-A side while
      parent-B added it.

        The result:
            - the file is not marked as touched by the merge.

      Subcase (B) is the counter part of "Special case [1]", the file was
        modified on parent-B side, while parent-A side deleted it. However this
        time, the conflict was solved by keeping the file (and its
        modification). We consider the file as "salvaged".

        The result:
            - the file is marked as "salvaged" by the merge.

      Subcase (C) is subtle variation of the case above. In this case, the
        file in unchanged on the parent-B side and actively removed on the
        parent-A side. So the merge machinery correctly decide it should be
        removed. However, the file was explicitly restored to its parent-B
        content before the merge was commited. The file is be marked
        as salvaged too. From the merge result perspective, this is similar to
        Subcase (B), however from the merge resolution perspective they differ
        since in (C), there was some conflict not obvious solution to the
        merge (That got reversed)

    Special case [3]:

      The situation is:
        - parent-A:     file,
        - parent-B:     file (different filenode as parent-A),
        - working-copy: file (same filenode as parent-B).

      This case is in theory much simple, for this to happens, this mean the
      filenode in parent-A is purely replacing the one in parent-B (either a
      descendant, or a full new file history, see changeset). So the merge
      introduce no changes, and the file is not affected by the merge...

      However, in the wild it is possible to find commit with the above is not
      True. For example repository have some commit where the *new* node is an
      ancestor of the node in parent-A, or where parent-A and parent-B are two
      branches of the same file history, yet not merge-filenode were created
      (while the "merge" should have led to a "modification").

      Detecting such cases (and not recording the file as modified) would be a
      nice bonus. However do not any of this yet.
    """

    repo = ctx.repo()
    md = ChangingFiles()

    m = ctx.manifest()
    p1m = p1_ctx.manifest()
    p2m = p2_ctx.manifest()
    diff_p1 = p1m.diff(m)
    diff_p2 = p2m.diff(m)

    cahs = ctx.repo().changelog.commonancestorsheads(
        p1_ctx.node(), p2_ctx.node()
    )
    if not cahs:
        cahs = [nullrev]
    mas = [ctx.repo()[r].manifest() for r in cahs]

    copy_candidates = []

    # Dealing with case 🄰 happens automatically.  Since there are no entry in
    # d1 nor d2, we won't iterate on it ever.

    # Iteration over d1 content will deal with all cases, but the one in the
    # first column of the table.
    for filename, d1 in diff_p1.items():
        d2 = diff_p2.pop(filename, None)

        if d2 is None:
            # this deal with the first line of the table.
            _process_other_unchanged(md, mas, filename, d1)
        else:
            if d1[0][0] is None and d2[0][0] is None:
                # case 🄼 — both deleted the file.
                md.mark_added(filename)
                copy_candidates.append(filename)
            elif d1[1][0] is None and d2[1][0] is None:
                # case 🄻 — both deleted the file.
                md.mark_removed(filename)
            elif d1[1][0] is not None and d2[1][0] is not None:
                if d1[0][0] is None or d2[0][0] is None:
                    if any(_find(ma, filename) is not None for ma in mas):
                        # case 🅀 or 🅁
                        md.mark_salvaged(filename)
                    else:
                        # case 🄽 🄾 : touched
                        md.mark_touched(filename)
                else:
                    fctx = repo.filectx(filename, fileid=d1[1][0])
                    if fctx.p2().rev() == nullrev:
                        # case 🅂
                        # lets assume we can trust the file history. If the
                        # filenode is not a merge, the file was not merged.
                        md.mark_touched(filename)
                    else:
                        # case 🄿
                        md.mark_merged(filename)
                copy_candidates.append(filename)
            else:
                # Impossible case, the post-merge file status cannot be None on
                # one side and Something on the other side.
                assert False, "unreachable"

    # Iteration over remaining d2 content deal with the first column of the
    # table.
    for filename, d2 in diff_p2.items():
        _process_other_unchanged(md, mas, filename, d2)

    for filename in copy_candidates:
        copy_info = ctx[filename].renamed()
        if copy_info:
            source, srcnode = copy_info
            if source in p1_ctx and p1_ctx[source].filenode() == srcnode:
                md.mark_copied_from_p1(source, filename)
            elif source in p2_ctx and p2_ctx[source].filenode() == srcnode:
                md.mark_copied_from_p2(source, filename)
    return md


def _find(manifest, filename):
    """return the associate filenode or None"""
    if filename not in manifest:
        return None
    return manifest.find(filename)[0]


def _process_other_unchanged(md, mas, filename, diff):
    source_node = diff[0][0]
    target_node = diff[1][0]

    if source_node is not None and target_node is None:
        if any(not _find(ma, filename) == source_node for ma in mas):
            # case 🄲 of 🄷
            md.mark_removed(filename)
        # else, we have case 🄱 or 🄶 : no change need to be recorded
    elif source_node is None and target_node is not None:
        if any(_find(ma, filename) is not None for ma in mas):
            # case 🄴 or 🄹
            md.mark_salvaged(filename)
        # else, we have case 🄳 or 🄸 : simple merge without intervention
    elif source_node is not None and target_node is not None:
        # case 🄵  or 🄺 : simple merge without intervention
        #
        # In buggy case where source_node is not an ancestors of target_node.
        # There should have a been a new filenode created, recording this as
        # "modified". We do not deal with them yet.
        pass
    else:
        # An impossible case, the diff algorithm should not return entry if the
        # file is missing on both side.
        assert False, "unreachable"


def _missing_from_all_ancestors(mas, filename):
    return all(_find(ma, filename) is None for ma in mas)


def computechangesetfilesadded(ctx):
    """return the list of files added in a changeset"""
    added = []
    for f in ctx.files():
        if not any(f in p for p in ctx.parents()):
            added.append(f)
    return added


def get_removal_filter(ctx, x=None):
    """return a function to detect files "wrongly" detected as `removed`

    When a file is removed relative to p1 in a merge, this
    function determines whether the absence is due to a
    deletion from a parent, or whether the merge commit
    itself deletes the file. We decide this by doing a
    simplified three way merge of the manifest entry for
    the file. There are two ways we decide the merge
    itself didn't delete a file:
    - neither parent (nor the merge) contain the file
    - exactly one parent contains the file, and that
      parent has the same filelog entry as the merge
      ancestor (or all of them if there two). In other
      words, that parent left the file unchanged while the
      other one deleted it.
    One way to think about this is that deleting a file is
    similar to emptying it, so the list of changed files
    should be similar either way. The computation
    described above is not done directly in _filecommit
    when creating the list of changed files, however
    it does something very similar by comparing filelog
    nodes.
    """

    if x is not None:
        p1, p2, m1, m2 = x
    else:
        p1 = ctx.p1()
        p2 = ctx.p2()
        m1 = p1.manifest()
        m2 = p2.manifest()

    @util.cachefunc
    def mas():
        p1n = p1.node()
        p2n = p2.node()
        cahs = ctx.repo().changelog.commonancestorsheads(p1n, p2n)
        if not cahs:
            cahs = [nullrev]
        return [ctx.repo()[r].manifest() for r in cahs]

    def deletionfromparent(f):
        if f in m1:
            return f not in m2 and all(
                f in ma and ma.find(f) == m1.find(f) for ma in mas()
            )
        elif f in m2:
            return all(f in ma and ma.find(f) == m2.find(f) for ma in mas())
        else:
            return True

    return deletionfromparent


def computechangesetfilesremoved(ctx):
    """return the list of files removed in a changeset"""
    removed = []
    for f in ctx.files():
        if f not in ctx:
            removed.append(f)
    if removed:
        rf = get_removal_filter(ctx)
        removed = [r for r in removed if not rf(r)]
    return removed


def computechangesetfilesmerged(ctx):
    """return the list of files merged in a changeset"""
    merged = []
    if len(ctx.parents()) < 2:
        return merged
    for f in ctx.files():
        if f in ctx:
            fctx = ctx[f]
            parents = fctx._filelog.parents(fctx._filenode)
            if parents[1] != ctx.repo().nullid:
                merged.append(f)
    return merged


def computechangesetcopies(ctx):
    """return the copies data for a changeset

    The copies data are returned as a pair of dictionnary (p1copies, p2copies).

    Each dictionnary are in the form: `{newname: oldname}`
    """
    p1copies = {}
    p2copies = {}
    p1 = ctx.p1()
    p2 = ctx.p2()
    narrowmatch = ctx._repo.narrowmatch()
    for dst in ctx.files():
        if not narrowmatch(dst) or dst not in ctx:
            continue
        copied = ctx[dst].renamed()
        if not copied:
            continue
        src, srcnode = copied
        if src in p1 and p1[src].filenode() == srcnode:
            p1copies[dst] = src
        elif src in p2 and p2[src].filenode() == srcnode:
            p2copies[dst] = src
    return p1copies, p2copies


def encodecopies(files, copies):
    items = []
    for i, dst in enumerate(files):
        if dst in copies:
            items.append(b'%d\0%s' % (i, copies[dst]))
    if len(items) != len(copies):
        raise error.ProgrammingError(
            b'some copy targets missing from file list'
        )
    return b"\n".join(items)


def decodecopies(files, data):
    try:
        copies = {}
        if not data:
            return copies
        for l in data.split(b'\n'):
            strindex, src = l.split(b'\0')
            i = int(strindex)
            dst = files[i]
            copies[dst] = src
        return copies
    except (ValueError, IndexError):
        # Perhaps someone had chosen the same key name (e.g. "p1copies") and
        # used different syntax for the value.
        return None


def encodefileindices(files, subset):
    subset = set(subset)
    indices = []
    for i, f in enumerate(files):
        if f in subset:
            indices.append(b'%d' % i)
    return b'\n'.join(indices)


def decodefileindices(files, data):
    try:
        subset = []
        if not data:
            return subset
        for strindex in data.split(b'\n'):
            i = int(strindex)
            if i < 0 or i >= len(files):
                return None
            subset.append(files[i])
        return subset
    except (ValueError, IndexError):
        # Perhaps someone had chosen the same key name (e.g. "added") and
        # used different syntax for the value.
        return None


# see mercurial/helptext/internals/revlogs.txt for details about the format

ACTION_MASK = int("111" "00", 2)
# note: untouched file used as copy source will as `000` for this mask.
ADDED_FLAG = int("001" "00", 2)
MERGED_FLAG = int("010" "00", 2)
REMOVED_FLAG = int("011" "00", 2)
SALVAGED_FLAG = int("100" "00", 2)
TOUCHED_FLAG = int("101" "00", 2)

COPIED_MASK = int("11", 2)
COPIED_FROM_P1_FLAG = int("10", 2)
COPIED_FROM_P2_FLAG = int("11", 2)

# structure is <flag><filename-end><copy-source>
INDEX_HEADER = struct.Struct(">L")
INDEX_ENTRY = struct.Struct(">bLL")


def encode_files(files: rl_t.ChangedFilesT) -> bytes:
    if not files:
        return b""
    all_files = set(files.touched)
    all_files.update(files.copied_from_p1.values())
    all_files.update(files.copied_from_p2.values())
    all_files = sorted(all_files)
    file_idx = {f: i for (i, f) in enumerate(all_files)}
    file_idx[None] = 0

    chunks = [INDEX_HEADER.pack(len(all_files))]

    filename_length = 0
    for f in all_files:
        filename_size = len(f)
        filename_length += filename_size
        flag = 0
        if f in files.added:
            flag |= ADDED_FLAG
        elif f in files.merged:
            flag |= MERGED_FLAG
        elif f in files.removed:
            flag |= REMOVED_FLAG
        elif f in files.salvaged:
            flag |= SALVAGED_FLAG
        elif f in files.touched:
            flag |= TOUCHED_FLAG

        copy = None
        if f in files.copied_from_p1:
            flag |= COPIED_FROM_P1_FLAG
            copy = files.copied_from_p1.get(f)
        elif f in files.copied_from_p2:
            copy = files.copied_from_p2.get(f)
            flag |= COPIED_FROM_P2_FLAG
        copy_idx = file_idx[copy]
        chunks.append(INDEX_ENTRY.pack(flag, filename_length, copy_idx))
    chunks.extend(all_files)
    return b''.join(chunks)


def decode_files(raw: bytes) -> rl_t.ChangedFilesT:
    md = ChangingFiles()

    if raw is None:
        return md
    if not raw:
        return md

    copies = []
    all_files = []

    assert len(raw) >= INDEX_HEADER.size
    total_files = INDEX_HEADER.unpack_from(raw, 0)[0]

    offset = INDEX_HEADER.size
    file_offset_base = offset + (INDEX_ENTRY.size * total_files)
    file_offset_last = file_offset_base

    assert len(raw) >= file_offset_base

    for idx in range(total_files):
        flag, file_end, copy_idx = INDEX_ENTRY.unpack_from(raw, offset)
        file_end += file_offset_base
        # Convert the filename to bytes to avoid a potential memoryview object
        #
        # It would be better to properly handle memoryview objets down the line.
        # However, we should not even have filename in the serialization and
        # use file-index token instead. So by the time this code will start to
        # be used for real this conversion won't be around anymore.
        filename = bytes(raw[file_offset_last:file_end])
        filesize = file_end - file_offset_last
        assert len(filename) == filesize
        offset += INDEX_ENTRY.size
        file_offset_last = file_end
        all_files.append(filename)
        if flag & ACTION_MASK == ADDED_FLAG:
            md.mark_added(filename)
        elif flag & ACTION_MASK == MERGED_FLAG:
            md.mark_merged(filename)
        elif flag & ACTION_MASK == REMOVED_FLAG:
            md.mark_removed(filename)
        elif flag & ACTION_MASK == SALVAGED_FLAG:
            md.mark_salvaged(filename)
        elif flag & ACTION_MASK == TOUCHED_FLAG:
            md.mark_touched(filename)

        copied = None
        if flag & COPIED_MASK == COPIED_FROM_P1_FLAG:
            copied = md.mark_copied_from_p1
        elif flag & COPIED_MASK == COPIED_FROM_P2_FLAG:
            copied = md.mark_copied_from_p2

        if copied is not None:
            copies.append((copied, filename, copy_idx))

    for copied, filename, copy_idx in copies:
        copied(all_files[copy_idx], filename)

    return md
