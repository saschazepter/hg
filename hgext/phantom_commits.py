"""track AI changes separately from human changes

This extension provides "phantom commits" that can be used to distinguish AI
changes from human changes. There are two parts to how it works.

First, it provides `hg create-phantom-commit`. The AI should call this before
and after every change it makes, attributing the first commit to the human and
the second to the AI. These commits are made without touching the working copy,
so they are invisible to the user apart from showing up in hg log. They are
always based on ".", the working directory parent. The latest one is tracked in
a bookmark, and the previous ones are linked via commit extras. The bookmark
name is determined by the required config `phantom_commits.bookmark`.

Second, it changes the behavior of `hg commit`. If the phantom commit bookmark
is present, then instead of just creating a regular commit, it will also create
an intermediate AI commit. It computes the AI commit using the phantom commits,
such that `hg annotate` will correctly attribute AI changes to the intermediate
AI commit. It will only create one commit if changes are purely AI or purely
human. It will not create a commit at all if there are no net changes. If the
phantom commits included any changes to untracked files, it will not include
them in either commit, but it will create a new phantom commit to retain them.

TODOs for integrating this better with core:
- integration with phases (use internal phase)
- use obsmarkers for linking the phantom commits?
- leverage the links for better deltas
- more in-depth review of the code that creates commits
- better support for merge, rebase, graft
- generalize so it's less AI specific
"""

from __future__ import annotations

import binascii
import collections
import contextlib
import enum
import json
import stat
import typing
from mercurial.i18n import _
from mercurial import (
    bookmarks,
    cmd_impls,
    cmdutil,
    commands,
    context,
    error,
    extensions,
    logcmdutil,
    merge as mergemod,
    node as nodemod,
    patch,
    policy,
    pycompat,
    registrar,
    scmutil,
    testing,
    util,
)
from mercurial.cmd_impls import bundle as bundle_impl
from mercurial.utils import dateutil, stringutil

if typing.TYPE_CHECKING:
    from mercurial.localrepo import localrepository
    from mercurial.interfaces.types import (
        HgPathT,
        MatcherT,
        NodeIdT,
        RepoT,
        StatusT,
        UiT,
        VfsT,
    )

    # A file's (flags, contents, copysource), or an existing filectx to reuse,
    # or None if the file is absent. The copysource is None if it is not a copy.
    ChangeValueT = tuple[bytes, bytes, HgPathT | None] | context.filectx | None


# Note for extension authors: ONLY specify testedwith = 'ships-with-hg-core' for
# extensions which SHIP WITH MERCURIAL. Non-mainline extensions should
# be specifying the version(s) of Mercurial they are tested with, or
# leave the attribute unspecified.
testedwith = b'ships-with-hg-core'

rustmod: typing.Any = policy.importrust("phantom_commits")

cmdtable = {}
command = registrar.command(cmdtable)


class UserKind(enum.Enum):
    """Enum representing if a user is human or AI."""

    HUMAN = b"human"
    AI = b"ai"


class PhantomError(error.Error):
    """Error for invalid state in phantom commits.

    These errors are only expected to happen if there are bugs in the extension
    or if someone tampers with the phantom bookmark.
    """


class PhantomConfig:
    """Configuration for phantom commits."""

    def __init__(self, ui: UiT, repo: RepoT):
        """Load configuration from the ui and repo.

        Raises an error.Error subclass on failure.
        """

        def bookmark_replacement() -> bytes:
            active_bookmark: bytes | None = repo._activebookmark  # type: ignore
            if active_bookmark is None:
                raise ValueError(_(b"there is no active bookmark"))
            return active_bookmark

        def ai_user_replacement() -> bytes:
            user = ui.username(acceptempty=True)
            if user is None:
                raise ValueError(
                    b"username cannot be determined "
                    b"(no HGUSER, no EMAIL, no ui.username)"
                )
            short = stringutil.shortuser(user)
            if not short:
                msg = _(b"shortuser (derived from username '%s') is empty")
                raise ValueError(msg % user)
            return short

        self.bookmark = self._resolve_template(
            b"phantom_commits.bookmark",
            ui.config(b"phantom_commits", b"bookmark"),
            b"{bookmark}",
            bookmark_replacement,
        )
        self.ai_user = self._resolve_template(
            b"phantom_commits.ai-user",
            ui.config(b"phantom_commits", b"ai-user"),
            b"{user}",
            ai_user_replacement,
        )

        if (
            value := ui.config(b"phantom_commits", b"last-ai-bookmark")
        ) is not None:
            self.last_ai_bookmark = self._resolve_template(
                b"phantom_commits.last-ai-bookmark",
                value,
                b"{bookmark}",
                bookmark_replacement,
            )
        else:
            self.last_ai_bookmark = None

    @staticmethod
    def _resolve_template(
        name: bytes,
        value: bytes | None,
        placeholder: bytes,
        get_replacement: typing.Callable[[], bytes],
    ) -> bytes:
        """Substitute a placeholder in a required config value if present."""
        if not value:
            raise error.InputError(_(b"missing config %s") % name)
        if placeholder in value:
            try:
                replacement = get_replacement()
            except ValueError as err:
                msg = _(b"%s contains '%s', but %s")
                raise error.InputError(msg % (name, placeholder, err.args[0]))
            value = value.replace(placeholder, replacement)
        if b"{" in value or b"}" in value:
            raise error.InputError(_(b"%s has unexpected '{' or '}'") % name)
        return value


class PhantomChain:
    """The chain of phantom commits.

    This class validates phantom commits and provides an iterator over them that
    follows the "phantom_prev" links in commit extras.
    """

    class Item(typing.NamedTuple):
        """An item in the chain of phantom commits."""

        ctx: context.changectx
        """The phantom changeset itself."""

        prev_ctx: context.changectx | None
        """The changeset pointed to by the "phantom_prev" in commit extras."""

        metadata: PhantomMetadata | None
        """Metadata from "phantom_metadata" in commit extras."""

    def __init__(self, repo: RepoT, node: NodeIdT):
        """Create a new phantom chain starting from the given node."""
        self.repo = repo
        self.seen = set()
        self.tip = self.read(repo[node])

    def is_stale(self) -> bool:
        """Return true if the phantom chain is stale (not based on ".").

        This is expected to happen if the user manually hg updates to a
        different revision without committing their changes.
        """
        return self.tip.ctx.p1() != self.repo[b"."]

    def read(self, ctx: context.changectx) -> "Item":
        """Read a changeset as an item in the phantom chain."""
        if ctx.p2().rev() != nodemod.nullrev:
            msg = _(b"%s has a p2 (%s)") % (ctx.hex(), ctx.p2().hex())
            raise PhantomError(msg)
        extra = ctx.extra()
        prev = extra.get(b"phantom_prev")
        if prev is None:
            msg = _(b"%s has no phantom_prev in commit extras") % ctx.hex()
            raise PhantomError(msg)
        try:
            prev = nodemod.bin(prev)
        except binascii.Error:
            msg = _(b"%s has invalid phantom_prev '%s'") % (ctx.hex(), prev)
            raise PhantomError(msg)
        metadata = extra.get(b"phantom_metadata")
        if metadata is not None:
            try:
                metadata = PhantomMetadata.parse(metadata)
            except ValueError as err:
                msg = _(b"%s has invalid phantom_metadata '%s': %s")
                raise PhantomError(msg % (ctx.hex(), metadata, err.args[0]))
        if prev == self.repo.nullid:
            return PhantomChain.Item(ctx=ctx, prev_ctx=None, metadata=metadata)
        if prev in self.seen:
            raise PhantomError(_(b"cycle in phantom_prev"))
        self.seen.add(prev)
        try:
            prev_ctx = self.repo[prev]
        except error.LookupError:
            msg = _(b"%s: phantom_prev %s not in repo") % (ctx.hex(), prev)
            raise PhantomError(msg)
        if ctx.p1() != prev_ctx.p1():
            msg = _(b"phantom %s and %s have different p1") % (ctx.hex(), prev)
            raise PhantomError(msg)
        return PhantomChain.Item(ctx=ctx, prev_ctx=prev_ctx, metadata=metadata)

    def __iter__(self) -> typing.Iterator[Item]:
        """Iterate the phantom commit chain from newest to oldest."""
        item = self.tip
        while True:
            yield item
            if item.prev_ctx is None:
                break
            item = self.read(item.prev_ctx)


# Type variables for the Validator class.
T = typing.TypeVar("T")
U = typing.TypeVar("U")


class Validator(typing.Generic[T]):
    """Helper for validating a parsed JSON object against a schema."""

    def __init__(self, value: typing.Any, typ: type[T], path=b"$"):
        if not isinstance(value, typ):
            raise ValueError(
                b"%s: expected %s, got %s"
                % (path, typ.__name__.encode(), type(value).__name__.encode())
            )
        self.value = value
        self.path = path

    def required(self: Validator[dict], key: str, typ: type[U]) -> Validator[U]:
        if v := self.optional(key, typ):
            return v
        raise ValueError(b"%s: missing %s" % (self.path, key.encode()))

    def optional(
        self: Validator[dict], key: str, typ: type[U]
    ) -> Validator[U] | None:
        value = self.value.get(key)
        if value is None:
            return None
        return Validator(value, typ, b"%s.%s" % (self.path, key.encode()))

    def each(
        self: Validator[list], typ: type[U]
    ) -> typing.Iterator[Validator[U]]:
        for i, item in enumerate(self.value):
            yield Validator(item, typ, b"%s[%d]" % (self.path, i))


class PhantomMetadata:
    """Metadata associated with a phantom commit."""

    class Version(enum.Enum):
        V1 = "v1"

    def __init__(self, value: dict):
        self.version = PhantomMetadata._validate(value)
        self.value = value

    @staticmethod
    def parse(json_value: bytes) -> PhantomMetadata:
        """Parse phantom metadata from JSON, raising ValueError on error."""
        try:
            value = json.loads(json_value)
        except UnicodeDecodeError:
            raise ValueError(b"invalid UTF-8")
        except json.JSONDecodeError:
            raise ValueError(b"invalid JSON")
        if type(value) is not dict:
            raise ValueError(b"expected JSON object")
        return PhantomMetadata(value)

    def serialize(self) -> bytes:
        """Serialize the phantom metadata in a compact JSON format."""
        str = json.dumps(self.value, separators=(",", ":"))
        return str.encode()

    @staticmethod
    def _validate(value: dict) -> PhantomMetadata.Version:
        root = Validator(value, dict)
        version_str = root.required("version", str).value
        try:
            version = PhantomMetadata.Version(version_str)
        except ValueError:
            raise ValueError(b"unknown version '%s'" % version_str.encode())
        if version == PhantomMetadata.Version.V1:
            for session in root.required("sessions", list).each(dict):
                session.required("source", str)
                session.optional("session_id", str)
                session.optional("first_message_id", str)
                session.optional("last_message_id", str)
        else:
            raise error.ProgrammingError(b"unhandled metadata version")
        return version

    class Aggregator:
        """Aggregates multiple phantom metadata together.

        This supports reading all known versions, but it always produces the
        latest version. The metadata must be passed to add_prev in reverse
        order: starting with the newest and ending with the oldest.
        """

        def __init__(self):
            self.sessions = collections.defaultdict(dict)

        def add_prev(self, meta: PhantomMetadata):
            """Add the previous metadata value."""
            if meta.version == PhantomMetadata.Version.V1:
                for s in meta.value["sessions"]:
                    agg = self.sessions[s["source"], s.get("session_id")]
                    if (id := s.get("first_message_id")) is not None:
                        agg["first_message_id"] = id
                    if (id := s.get("last_message_id")) is not None:
                        if "last_message_id" not in agg:
                            agg["last_message_id"] = id
            else:
                raise error.ProgrammingError(b"unhandled metadata version")

        def finish(self) -> PhantomMetadata | None:
            """Return aggregated metadata, or None if it's empty."""
            if not self.sessions:
                return None
            sessions = []
            for (source, session_id), value in self.sessions.items():
                result = {"source": source}
                if session_id is not None:
                    result["session_id"] = session_id
                result.update(value)
                sessions.append(result)
            return PhantomMetadata({"version": "v1", "sessions": sessions})


@command(b"debug::list-phantom-commits")
def debug_list_phantom_commits(ui: UiT, repo: RepoT):
    """list phantom commits (DEPRECATED)

    Use `hg debug::phantom-commits` instead.
    """
    debug_phantom_commits(ui, repo)


@command(
    b"debug::phantom-commits",
    [
        (
            b"r",
            b"rev",
            b"",
            _(b"use REV instead of the phantom bookmark"),
            b"REV",
        ),
        (
            b"",
            b"for",
            b"",
            _(b"show phantom commits for squashed AI changeset REV"),
            b"REV",
        ),
        (
            b"",
            b"bundle",
            b"",
            _(b"write a bundle with phantom commits to FILE"),
            b"FILE",
        ),
    ],
)
def debug_phantom_commits(ui: UiT, repo: RepoT, **opts):
    """inspect phantom commits

    By default, lists the current phantom commits. Prints a warning if they are
    stale (not based on the working directory parent).
    """
    cmdutil.check_at_most_one_arg(opts, "rev", "for")
    config = PhantomConfig(ui, repo)
    using_bookmark = False
    if revspec := opts.get("rev"):
        ctx = logcmdutil.revsingle(repo, revspec)
        node = ctx.node()
    elif revspec := opts.get("for"):
        ctx = logcmdutil.revsingle(repo, revspec)
        node = ctx.extra().get(b"phantom_tip")
        if node is None:
            msg = _(b"%s is not an AI change (no phantom_tip)")
            raise error.Abort(msg % ctx.hex())
    else:
        using_bookmark = True
        node = repo._bookmarks.get(config.bookmark, None)
        if node is None:
            ui.debug(b"phantom bookmark %s is not set\n" % config.bookmark)
            return
    phantom = PhantomChain(repo, node)
    if using_bookmark and phantom.is_stale():
        msg = _(b"stale phantom bookmark %s (%s)\n")
        ui.warn(msg % (config.bookmark, nodemod.hex(node)))
    phantom_list = list(phantom)
    phantom_list.reverse()
    if filename := opts.get("bundle"):
        bundle_impl.bundle(
            ui,
            repo,
            filename,
            rev=[item.ctx.hex() for item in phantom_list],
            base=[phantom_list[0].ctx.p1().hex()],
            type=b"none-v3;tagsfnodescache=False;revbranchcache=False;phases=False",
        )
    else:
        for i, item in enumerate(phantom_list):
            ctx = item.ctx
            node = nodemod.short(ctx.node())
            date = dateutil.datestr(ctx.date(), format=b'%Y-%m-%dT%H:%M:%S%1%2')
            ui.write(_(b"#%d %s %s %s\n") % (i + 1, node, date, ctx.user()))


@command(
    b"phantom-commits::status",
    [
        (b"", b"from", b"", _(b"revision to diff from"), _(b"REV1")),
        (b"", b"to", b"", _(b"revision to diff to"), _(b"REV2")),
        (
            b"",
            b"validate-phantom",
            None,
            _(
                b"validate that --from or --to is on the current chain of "
                b"phantom commits"
            ),
        ),
        (
            b"",
            b"since-last-ai",
            None,
            _(b"compare from the last AI phantom commit"),
        ),
    ]
    + cmd_impls.walk_opts,
    _(b"[OPTION]... [FILE]..."),
)
def phantom_commits_status(ui: UiT, repo: RepoT, *pats, **opts):
    """show changes since the last phantom commit

    This is like `hg status`, except --from defaults to the last phantom commit
    (or the working directory parent if the phantom bookmark is unset or stale),
    and all files are considered tracked like in `hg create-phantom-commit`.
    The output only contains status codes "M", "A", and "R".

    If file patterns are given, only files that match are shown.

    Passing both --from and --to is not allowed. Use `hg status` for that.

    With --validate-phantom, it validates that the --from or --to rev is either
    the working directory parent or a phantom commit based on it.

    With --since-last-ai, the status is relative to the AI last phantom commit
    (even if it's stale). This is useful for informing the AI agent what changes
    the human has made since the last AI edit. This requires setting the config
    phantom_commits.last-ai-bookmark. If there is no last AI edit, it prints
    nothing to stdout, logs a warning to stderr, and exits successfully.
    """
    ref_ctx, reverse = process_status_opts(ui, repo, **opts)
    if ref_ctx is None:
        return
    matcher = scmutil.match(repo[None], pats, pycompat.byteskwargs(opts))
    _wdir_status, status = compute_status(ui, repo, ref_ctx, matcher)
    if reverse:
        status.added, status.removed = status.removed, status.added
    for char, files in [
        (b"M", status.modified),
        (b"A", status.added),
        (b"R", status.removed),
    ]:
        for f in files:
            ui.write(b"%s %s\n" % (char, f))


@command(
    b"phantom-commits::diff",
    [
        (b"", b"from", b"", _(b"revision to diff from"), _(b"REV1")),
        (b"", b"to", b"", _(b"revision to diff to"), _(b"REV2")),
        (
            b"",
            b"validate-phantom",
            None,
            _(
                b"validate that --from or --to is on the current chain of "
                b"phantom commits"
            ),
        ),
        (
            b"",
            b"since-last-ai",
            None,
            _(b"compare from the last AI phantom commit"),
        ),
    ]
    + cmd_impls.diff_opts
    + cmd_impls.diff_opts2
    + cmd_impls.walk_opts,
)
def phantom_commits_diff(ui: UiT, repo: RepoT, *pats, **opts):
    """show diff since the last phantom commit

    This is like `hg diff`, except --from defaults to the last phantom commit
    (or the working directory parent if the phantom bookmark is unset or stale),
    and all files are considered tracked like in `hg create-phantom-commit`.

    If file patterns are given, only files that match are shown.

    Passing both --from and --to is not allowed. Use `hg diff` for that.

    With --validate-phantom, it validates that the --from or --to rev is either
    the working directory parent or a phantom commit based on it.

    With --since-last-ai, the diff is relative to the AI last phantom commit
    (even if it's stale). This is useful for informing the AI agent what changes
    the human has made since the last AI edit. This requires setting the config
    phantom_commits.last-ai-bookmark. If there is no last AI edit, it prints
    nothing to stdout, logs a warning to stderr, and exits successfully.
    """
    ref_ctx, reverse = process_status_opts(ui, repo, **opts)
    if ref_ctx is None:
        return
    matcher = scmutil.match(repo[None], pats, pycompat.byteskwargs(opts))
    _status, filtered_unknown, deleted = compute_wdir_status(
        ui, repo, ref_ctx, matcher
    )
    with scratch_dirstate(repo) as dirstate:
        for path in filtered_unknown:
            dirstate.set_tracked(path)
        for path in deleted:
            dirstate.set_untracked(path)

        ctx1 = ref_ctx
        ctx2 = repo[None]

        # This code is copied from the diff command in mercurial/commands.py.
        if reverse:
            ctxleft = ctx2
            ctxright = ctx1
        else:
            ctxleft = ctx1
            ctxright = ctx2
        opts = pycompat.byteskwargs(opts)
        diffopts = patch.diffallopts(ui, opts)
        m = scmutil.match(ctx2, pats, opts)
        m = repo.narrowmatch(m)
        ui.pager(b"diff")
        logcmdutil.diffordiffstat(
            ui,
            repo,
            diffopts,
            ctxleft,
            ctxright,
            m,
            stat=opts.get(b"stat"),
            listsubrepos=opts.get(b"subrepos"),
            root=opts.get(b"root"),
        )


def process_status_opts(
    ui: UiT, repo: RepoT, **opts
) -> tuple[context.changectx | None, bool]:
    """Helper for phantom-commits::status and related commands.

    Returns the context that status should be relative to, and a bool indicating
    if it should be reversed. Returns None if the command should exit because
    --since-last-ai was given and there is no last AI phantom commit.
    """
    cmdutil.check_at_most_one_arg(opts, "from", "to", "since_last_ai")
    from_rev = opts.get("from")
    to_rev = opts.get("to")
    since_last_ai = opts.get("since_last_ai")
    validate_phantom = opts.get("validate_phantom")
    if validate_phantom and not (from_rev or to_rev):
        raise error.InputError(b"--validate-phantom requires --from or --to")

    config = PhantomConfig(ui, repo)
    reverse = False
    if since_last_ai:
        if config.last_ai_bookmark is None:
            msg = _(
                b"the --since-last-ai flag requires setting the config "
                b"phantom_commits.last-ai-bookmark"
            )
            raise error.Abort(msg)
        bookmark_node = repo._bookmarks.get(config.last_ai_bookmark, None)
        if bookmark_node is None:
            ui.warn(_(b"there is no last AI phantom commit\n"))
            ref_ctx = None
        else:
            ref_ctx = repo[bookmark_node]
    elif from_rev or to_rev:
        ref_ctx = logcmdutil.revsingle(repo, from_rev or to_rev)
        reverse = bool(to_rev)
        if validate_phantom and not is_valid_phantom_ctx(repo, config, ref_ctx):
            msg = _(b"%s is invalid according to --validate-phantom")
            raise error.InputError(msg % ref_ctx.hex())
    else:
        ref_ctx = repo[b"."]
        bookmark_node = repo._bookmarks.get(config.bookmark, None)
        if bookmark_node is not None:
            phantom = PhantomChain(repo, bookmark_node)
            if phantom.is_stale():
                msg = _(b"ignoring stale phantom bookmark %s (%s)\n")
                ui.warn(msg % (config.bookmark, nodemod.hex(bookmark_node)))
            else:
                ref_ctx = phantom.tip.ctx
    return ref_ctx, reverse


@command(
    b"create-phantom-commit",
    [
        (b"", b"user", b"", _(b"committer"), _(b"USER")),
        (b"", b"ai", None, _(b"use the ai username")),
        (b"", b"message", b"", _(b"commit message"), _(b"TEXT")),
        (b"", b"metadata", b"", _(b"phantom metadata"), _(b"JSON")),
        (b"", b"allow-empty", None, _(b"commit even if there are no changes")),
        (b"", b"show-previous", None, _(b"show previous node")),
        (
            b"",
            b"set-bookmark",
            b"",
            _(b"set bookmark to the new commit"),
            _(b"BOOKMARK"),
        ),
    ]
    + cmd_impls.walk_opts,
    _(b"[OPTION]... [FILE]..."),
)
@util.rust_tracing_span("create-phantom-commit")
def create_phantom_commit(ui: UiT, repo: RepoT, *pats, **opts):
    """create a phantom commit

    Saves a snapshot of the given files as a phantom commit with the given user
    and message, and updates the phantom bookmark. If a list of files is
    omitted, all files reported by `hg status` will be included. It does not
    affect the working copy: `hg status` and `hg diff` will be the same after
    running this. The commit includes unknown (?) and missing (!) files as if
    `hg addremove` had been run, but without actually running it.

    It prints machine-readable events to stdout (unless --quiet is passed).
    You can parse an event line by stripping the newline, splitting on spaces,
    and checking the first word. If there are no changes to commit, it prints
    "no-changes" and exits. Otherwise, it reads files from disk and then prints
    "in-progress". When the commit is finished, it prints "revision REV" and
    exits, where REV is a 40-character lowercase hexadecimal changeset node.

    With --allow-empty, it always makes a commit, even if there are no changes
    since the last phantom commit. It never prints "no-changes". The new commit
    has the same contents as the last phantom commit, if there is one.

    With --show-previous, it prints "previous KIND REV" before "no-changes" or
    "in-progress", where KIND is either "none" or "phantom", and REV is a
    40-character lowercase hexadecimal changeset node. REV is the revision we
    compare against to decide if there are any changes or not. The kind "none"
    means there is no previous phantom commit, and REV is the wdir parent. The
    kind "phantom" means REV is the previous phantom commit.

    With --set-bookmark, it sets BOOKMARK to the new phantom commit. If there
    are no changes, it sets it to the revision that --show-previous prints,
    that is, the previous phantom commit or the wdir parent. BOOKMARK must not
    be the phantom bookmark.

    If phantom_commits.tracing is enabled, it also prints "trace-start NAME" and
    "trace-end NAME" pairs, where NAME is the name of a tracing span.
    """

    def print_event(*words):
        """Print a machine-readable event to stdout.

        These events are part of the stable interface of this command so they
        must not change. It is safe to add new events.
        """
        ui.status(b" ".join(words) + b"\n")
        ui.flush()

    tracing_enabled = ui.configbool(b"phantom_commits", b"tracing")

    @contextlib.contextmanager
    def trace_event(name: bytes):
        if tracing_enabled:
            print_event(b"trace-start", name)
        yield
        if tracing_enabled:
            print_event(b"trace-end", name)

    user = opts.get("user")
    infer_ai_user = opts.get("ai")
    message = opts.get("message")
    if user and infer_ai_user:
        raise error.InputError(_(b"--user and --ai are mutually exclusive"))
    if not message:
        raise error.InputError(_(b"--message is required"))

    set_bookmark = opts.get("set_bookmark")
    if set_bookmark:
        set_bookmark = bookmarks.checkformat(repo, set_bookmark)

    metadata = opts.get("metadata")
    if metadata:
        try:
            metadata = PhantomMetadata.parse(metadata)
        except ValueError as err:
            msg = _(b"invalid --metadata value: %s") % err.args[0]
            raise error.InputError(msg)

    config = PhantomConfig(ui, repo)

    if set_bookmark == config.bookmark:
        msg = _(b"--set-bookmark cannot be the phantom bookmark '%s'")
        raise error.InputError(msg % config.bookmark)

    if not user:
        if infer_ai_user:
            user = config.ai_user
        else:
            user = ui.username(acceptempty=True)
            if user is None:
                msg = _(b"must provide --user or set HGUSER or ui.username")
                raise error.InputError(msg)

    if repo._activebookmark is None:  # type: ignore
        raise error.StateError(_(b"a bookmark must be active"))

    testing.wait_on_cfg(ui, b"phantom-commits.pre-wlock-file")

    with contextlib.ExitStack() as exit_stack:
        with trace_event(b"wlock"):
            exit_stack.enter_context(repo.wlock())

        # The phantom bookmark might have changed before we got the wlock.
        # TODO: Consider if repo.wlock() should always do this.
        repo.invalidate()

        phantom = None
        with (
            trace_event(b"load"),
            util.rust_tracing_span("phantom_commits load chain"),
        ):
            bookmark_node = repo._bookmarks.get(config.bookmark, None)
            if bookmark_node is not None:
                try:
                    phantom = PhantomChain(repo, bookmark_node)
                except PhantomError as err:
                    # Log the error and proceed with making a new phantom chain.
                    ui.error(b"%s\n" % err)

                if phantom and phantom.is_stale():
                    msg = _(b"ignoring stale phantom bookmark %s (%s)\n")
                    ui.warn(msg % (config.bookmark, nodemod.hex(bookmark_node)))
                    phantom = None

        if opts.get("show_previous"):
            if phantom:
                print_event(b"previous", b"phantom", phantom.tip.ctx.hex())
            else:
                print_event(b"previous", b"none", repo[b"."].hex())

        with trace_event(b"status"):
            prev_ctx = phantom.tip.ctx if phantom else repo[b"."]
            matcher = scmutil.match(
                repo[None], pats, pycompat.byteskwargs(opts)
            )
            status, prev_status = compute_status(ui, repo, prev_ctx, matcher)

        if not opts.get("allow_empty") and not (
            prev_status.modified or prev_status.added or prev_status.removed
        ):
            if (
                set_bookmark
                # Don't bother taking the lock if there's nothing to do.
                and repo._bookmarks.get(set_bookmark, None) != prev_ctx.node()
            ):
                with trace_event(b"lock"):
                    exit_stack.enter_context(repo.lock())
                with repo.transaction(b"bookmark") as tr:
                    bookmarks.addbookmarks(
                        repo,
                        tr,
                        [set_bookmark],
                        rev=prev_ctx.hex(),
                        force=True,
                    )
            print_event(b"no-changes")
            return

        # It's ok that we read repo state before acquiring the lock because
        # repo.lock() invalidates the repo. The phantom bookmark should not have
        # changed since we always hold the wlock while reading and writing it.
        # (Even if someone manually set the bookmark at the store level, the
        # only consequence is we abandon whatever it points to and overwrite the
        # bookmark with our new phantom commit.)
        with trace_event(b"lock"):
            exit_stack.enter_context(repo.lock())

        with (
            trace_event(b"read"),
            util.rust_tracing_span("phantom_commits read files"),
        ):
            changes: dict[HgPathT, ChangeValueT] = {}
            wvfs = repo.wvfs
            for path_list in status.modified, status.added:
                for path in path_list:
                    try:
                        flags, data = read_flags_and_data(wvfs, path)
                    except FileNotFoundError:
                        # We raced with someone deleting the file.
                        changes[path] = None
                    else:
                        changes[path] = flags, data, None
            for path in status.removed:
                changes[path] = None

            # Retain changes from the last phantom commit. Remember, phantom
            # commits are siblings, so this doesn't happen automatically.
            # This is similar to what cmdutil.py does for `hg amend FILE`.
            if phantom and not matcher.always():
                prev_ctx = phantom.tip.ctx
                for path in prev_ctx.files():
                    if path in changes:
                        continue
                    if matcher(path):
                        # If the file was selected by the user but isn't in
                        # changes, then there are two possibilities:
                        # 1. clean status (prev_ctx modified, then we reverted)
                        # 2. does not exist (prev_ctx added, then we removed)
                        # In both cases, the correct behavior is to omit the
                        # file from the commit.
                        continue
                    try:
                        changes[path] = prev_ctx[path]
                    except error.ManifestLookupError:
                        changes[path] = None

        print_event(b"in-progress")

        with (
            trace_event(b"commit"),
            util.rust_tracing_span("phantom_commits commit"),
        ):
            extra = {}
            if phantom:
                extra[b"phantom_prev"] = phantom.tip.ctx.hex()
            else:
                extra[b"phantom_prev"] = nodemod.nullhex
            if metadata:
                extra[b"phantom_metadata"] = metadata.serialize()
            node = commit_changes(
                repo=repo,
                p1=repo.dirstate.p1(),
                user=user,
                date=None,
                message=message,
                changes=changes,
                extra=extra,
            )

        with repo.transaction(b"bookmark") as tr:
            bookmark_list = [config.bookmark]
            if config.last_ai_bookmark is not None and user == config.ai_user:
                bookmark_list.append(config.last_ai_bookmark)
            if set_bookmark and set_bookmark not in bookmark_list:
                bookmark_list.append(set_bookmark)
            bookmarks.addbookmarks(
                repo, tr, bookmark_list, rev=nodemod.hex(node), force=True
            )

        print_event(b"revision", nodemod.hex(node))


@command(
    b"phantom-commits::revert",
    [
        (
            b"r",
            b"rev",
            b"",
            _(b"revert to the specified phantom commit rev"),
            _(b"REV"),
        ),
        (b"", b"addremove", None, _(b"mark files as added or removed")),
        (b"", b"update-last-ai", None, _(b"update the 'last AI' bookmark")),
        (b"", b"delete-last-ai", None, _(b"delete the 'last AI' bookmark")),
    ]
    + cmdutil.dryrunopts,
)
def phantom_commits_revert(ui: UiT, repo: RepoT, **opts):
    """revert to a phantom commit

    This reverts the working copy to REV, which must be the wdir parent or a
    phantom commit based on it. This is similar to applying the diff shown by
    `hg phantom-commits::diff --to REV --validate-phantom`, except it also
    updates the phantom bookmark.

    By default, it leaves the dirstate unchanged. With --addremove, it marks
    files added or removed in the dirstate.

    With --update-last-ai, it updates phantom_commits.last-ai-bookmark to point
    to the last AI phantom commit on or before REV. With --delete-last-ai, it
    deletes the bookmark. Otherwise, it leaves it alone.
    """
    cmdutil.check_at_most_one_arg(opts, "update_last_ai", "delete_last_ai")
    update_last_ai = opts.get("update_last_ai")
    delete_last_ai = opts.get("delete_last_ai")
    dry_run = bool(opts.get("dry_run"))
    revspec = opts.get("rev")
    if not revspec:
        raise error.InputError("the -r/--rev flag is required")
    ctx = logcmdutil.revsingle(repo, revspec)
    config = PhantomConfig(ui, repo)
    if config.last_ai_bookmark is None and (update_last_ai or delete_last_ai):
        msg = _(
            b"the --update-last-ai/--delete-last-ai flags requires setting "
            b"the config phantom_commits.last-ai-bookmark"
        )
        raise error.Abort(msg)
    if not is_valid_phantom_ctx(repo, config, ctx):
        msg = _(b"%s is invalid for phantom-commits::revert") % ctx.hex()
        raise error.Abort(msg)
    with repo.wlock():
        with contextlib.ExitStack() as exit_stack:
            if not opts.get("addremove"):
                exit_stack.enter_context(scratch_dirstate(repo))
            cmdutil.revert(ui, repo, ctx, **opts, no_backup=True)
            matcher = scmutil.match(repo[None], [], {})
            purge_files(ui, repo, matcher, dry_run=dry_run)
        if dry_run:
            return
        with repo.lock(), repo.transaction(b"bookmark") as tr:
            bm = {}
            if ctx == repo[b"."]:
                bm[config.bookmark] = None
            else:
                bm[config.bookmark] = ctx
            if delete_last_ai:
                bm[config.last_ai_bookmark] = None
            elif update_last_ai:
                bm[config.last_ai_bookmark] = get_new_last_ai_ctx(
                    repo, config, ctx
                )
            for name, ctx in bm.items():
                if ctx is None:
                    if name in repo._bookmarks:
                        bookmarks.delete(repo, tr, [name])
                else:
                    bookmarks.addbookmarks(
                        repo, tr, [name], rev=ctx.hex(), force=True
                    )


def purge_files(ui: UiT, repo: RepoT, matcher: MatcherT, dry_run: bool):
    """Purge untracked files under phantom_commits.unknown-files.size-limit."""

    # Copied from mercurial/merge.py.
    def remove(removefn, path):
        try:
            removefn(path)
        except OSError:
            m = _(b"%s cannot be removed") % path
            ui.warn(_(b"warning: %s\n") % m)

    size_limit = ui.configint(b"phantom_commits", b"unknown-files.size-limit")
    paths = mergemod.purge(repo, matcher, noop=True)
    for path in paths:
        try:
            st = repo.wvfs.lstat(path)
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(st.st_mode):
            ui.status(_(b"removing directory %s\n") % path)
            if not dry_run:
                remove(repo.wvfs.rmdir, path)
        elif st.st_size <= size_limit:
            ui.status(_(b"removing file %s\n") % path)
            if not dry_run:
                remove(repo.wvfs.unlink, path)


def is_valid_phantom_ctx(
    repo: RepoT, config: PhantomConfig, ctx: context.changectx
) -> bool:
    """Return true if ctx is valid for --validate-phantom."""
    if ctx == repo[b"."]:
        return True
    try:
        phantom = PhantomChain(repo, ctx.node())
    except PhantomError:
        return False
    return not phantom.is_stale()


def get_new_last_ai_ctx(
    repo: RepoT, config: PhantomConfig, ctx: context.changectx
) -> context.changectx | None:
    """Return the new last AI context as of ctx, or None if there is none.

    Assumes ctx is valid per is_valid_phantom_ctx.
    """
    if ctx == repo[b"."]:
        return None
    for item in PhantomChain(repo, ctx.node()):
        if item.ctx.user() == config.ai_user:
            return item.ctx
    return None


def compute_wdir_status(
    ui: UiT, repo: RepoT, ref_ctx: context.changectx, matcher: MatcherT
) -> tuple[StatusT, list[HgPathT], list[HgPathT]]:
    """Compute the wdir status for a phantom commit.

    Returns the status and separate lists of unknown and deleted files.
    The status itself only contains "modified", "added", "removed".
    The unknown files are filtered to respect the configured size limit.
    """
    size_limit = ui.configint(b"phantom_commits", b"unknown-files.size-limit")
    matcher = repo[None]._matchstatus(ref_ctx, matcher)
    status = repo[b"."].status(listunknown=True, match=matcher)
    filtered_unknown = []
    for path in status.unknown:
        try:
            st = repo.wvfs.lstat(path)
        except FileNotFoundError:
            continue
        if st.st_size > size_limit:
            msg = _(
                b"phantom_commits: ignoring '%s' (%d bytes) since "
                b"it exceeds size limit (%d bytes)\n"
            )
            ui.warn(msg % (path, st.st_size, size_limit))
            continue
        filtered_unknown.append(path)
    deleted = status.deleted
    status.unknown = []
    status.deleted = []
    return status, filtered_unknown, deleted


def compute_status(
    ui: UiT,
    repo: RepoT,
    ref_ctx: context.changectx,
    matcher: MatcherT,
) -> tuple[StatusT, StatusT]:
    """Compute statuses for a phantom commit.

    Returns the wdir status relative to (1) the wdir parent, (2) ref_ctx.

    It changes "unknown" to "added", and "deleted" to "removed", roughly as if
    hg addremove had been run. It excludes unknown files that exceed
    phantom_commits.unknown-files.size-limit.
    """
    status, filtered_unknown, deleted = compute_wdir_status(
        ui, repo, ref_ctx, matcher
    )
    status.added += filtered_unknown
    status.removed += deleted

    if ref_ctx == repo[b"."]:
        ref_status = status
    else:
        ref_status = context.changectx._buildstatus(
            repo[None],
            ref_ctx,
            status,
            matcher,
            listignored=False,
            listclean=False,
            listunknown=False,
            empty_dirs_keep_files=False,
        )

    return status, ref_status


@contextlib.contextmanager
def scratch_dirstate(repo):
    """Context manager that discards changes to the dirstate."""
    with repo.wlock():
        dirstate = repo.dirstate
        with dirstate.changing_files(repo):
            dirstate.write = lambda tr: None
            try:
                yield dirstate
            finally:
                del dirstate.write
                dirstate.invalidate()


def commitctx_for_commit(
    repo: RepoT, cctx: context.workingcommitctx, status: StatusT
) -> NodeIdT:
    """Replacement for localrepository.commitctx_for_commit.

    This makes up to two commits (AI and human) instead of just one. It returns
    the final node. It also creates another phantom commit if necessary.
    """

    ui = repo.ui

    class Fallback(Exception):
        """Fall back to a normal commit, ignoring phantom commits."""

    try:
        try:
            config = PhantomConfig(ui, repo)
        except error.Error as err:
            raise Fallback(err)

        if repo._activebookmark is None:  # type: ignore
            raise Fallback(b"no bookmark is active")

        bookmark_node = repo._bookmarks.get(config.bookmark, None)
        if bookmark_node is None:
            msg = b"phantom bookmark '%s' is not set" % config.bookmark
            raise Fallback(msg)

        if len(cctx.parents()) != 1:
            raise Fallback(b"in a merge")

        with util.rust_tracing_span("phantom_commits load chain"):
            try:
                phantom = PhantomChain(repo, bookmark_node)
            except PhantomError as err:
                ui.error(b"%s\n" % err)
                raise Fallback(b"error loading phantom commits")

            if phantom.is_stale():
                msg = _(b"stale phantom bookmark %s (%s)\n")
                msg %= config.bookmark, nodemod.hex(bookmark_node)
                raise Fallback(msg)

        # Make a list of alternating human/AI commits by selecting the last one
        # from each run of commits partitioned by user. PhantomChain iterates
        # from newest to oldest, so "last one" becomes "first one".
        commits = []
        prev_kind = None
        aggregator = PhantomMetadata.Aggregator()
        for item in phantom:
            if item.metadata is not None:
                aggregator.add_prev(item.metadata)
            if item.ctx.user() == config.ai_user:
                kind = UserKind.AI
            else:
                kind = UserKind.HUMAN
            if kind != prev_kind:
                commits.append((kind, item.ctx))
            prev_kind = kind

        if not commits:
            raise error.ProgrammingError(b"must have at least one commit")
        if len(commits) == 1 and commits[0][0] == UserKind.HUMAN:
            raise Fallback(b"no phantom commits by AI")
    except Fallback as err:
        msg = _(b"phantom commits: falling back to normal commit: %s\n")
        ui.note(msg % err.args[0])
        return repo.commitctx(cctx)

    aggregated_metadata = aggregator.finish()
    if aggregated_metadata is not None:
        aggregated_metadata = aggregated_metadata.serialize()

    status = cctx._status
    parent_ctx = cctx.p1()
    dirstate = repo.dirstate
    copies = dirstate.copies()
    wvfs = repo.wvfs

    ui.status(_(b"preparing squashed ai commit\n"))
    with util.rust_tracing_span("phantom_commits squash"):
        # For the purposes of squashing, we only care about the paths affected
        # by the most recent phantom commit. (Remember, phantom commits are
        # siblings, so ctx.files() is the files changed relative to the wdir
        # parent ".", not relative to the previous phantom commit.)
        _kind, ctx = commits[0]
        all_paths = set(ctx.files())
        squasher = rustmod.Squasher()
        # Start by recording file contents on disk to capture human changes
        # after the last phantom commit. These could revert AI changes, and thus
        # affect the net AI changes we include in the squashed AI commit. This
        # is racy since the files could change between now and the main commit.
        # However, the consequences (including extra content in the AI commit
        # that gets reverted by the main commit) are not that bad.
        # TODO: Eliminate this race and avoid reading files twice by passing
        # file content when creating the main commit. Could require API change.
        for path in all_paths:
            if squasher.should_record(path):
                try:
                    _flags, data = read_flags_and_data(wvfs, path)
                except FileNotFoundError:
                    data = None
                squasher.record_prev(path, data, UserKind.HUMAN)
        # Next, record the phantom commits.
        # Note that commits are in reverse order, as expected by Squasher.
        for kind, ctx in commits:
            for path in ctx.files():
                if path in all_paths and squasher.should_record(path):
                    data = read_from_repo(ctx, path)
                    squasher.record_prev(path, data, kind)
        # Finally, record the base contents.
        for path in all_paths:
            if squasher.should_record(path):
                data = read_from_repo(parent_ctx, path)
                copysource_data = None
                if (source := copies.get(path)) is not None:
                    copysource_data = read_from_repo(parent_ctx, source)
                squasher.record_base(path, data, copysource_data)

    # Call it "remaining_paths" now because we're going to remove paths that get
    # included in the new commits. Then at the end, we'll carry over attribution
    # for whatever paths remain by making a new phantom commit.
    remaining_paths = all_paths
    del all_paths

    with (
        util.rust_tracing_span("phantom_commits prepare squashed"),
        dirstate.changing_files(repo),
    ):
        changes: dict[HgPathT, ChangeValueT] = {}
        skipped_copysources = set()
        for path_list in status.modified, status.added:
            for path in path_list:
                remaining_paths.discard(path)
                try:
                    flags = read_flags(wvfs, path)
                except FileNotFoundError:
                    # File disappeared. Exclude it from AI commit.
                    continue
                copysource = copies.get(path)
                data = squasher.get_ai_content(path)
                if data is None:
                    if copysource is not None:
                        skipped_copysources.add(copysource)
                    continue
                if copysource is not None:
                    # Remove the copy information from the dirstate,
                    # otherwise the human commit will also try to use it.
                    dirstate.copy(None, path)
                changes[path] = flags, data, copysource
        for path in status.removed:
            remaining_paths.discard(path)
            # Don't remove a copy source if the destination is going in the
            # human commit: you can't copy a file after removing it.
            if path in skipped_copysources:
                continue
            if squasher.did_ai_remove(path):
                changes[path] = None

    if not changes:
        ui.status(
            _(b"skipping squashed ai commit since ai changes are untracked\n")
        )
    else:
        with util.rust_tracing_span("phantom_commits commit squashed"):
            extra = cctx.extra().copy()
            extra[b"phantom_tip"] = phantom.tip.ctx.hex()
            if aggregated_metadata is not None:
                extra[b"phantom_metadata"] = aggregated_metadata
            ai_node = commit_changes(
                repo=repo,
                p1=parent_ctx.node(),
                user=config.ai_user,
                date=cctx.date(),
                message=convert_description_for_ai(cctx.description()),
                changes=changes,
                extra=extra,
            )

        ui.status(_(b"squashed ai commit: %s\n") % nodemod.hex(ai_node))
        cctx.setparents(ai_node)

    # After setparents, cctx.files() is still based on the cached cctx._status,
    # so it contains too much. But that's ok because commitctx explicitly allows
    # a superset (see doc comment on mercurial.commit.commitctx). When storing
    # the "files" list in the changelog entry, it determines the actual subset
    # of files touched rather than blindly using all of ctx.files().

    human_node = repo.commitctx(cctx, skip_empty=True)
    if human_node is not None:
        ui.status(_(b"human commit: %s\n") % nodemod.hex(human_node))
        main_node = human_node
    else:
        ui.status(_(b"skipping human commit since there are no changes\n"))
        main_node = ai_node

    # Make a new phantom commit with the remaining changes if there are any.
    # Note that we only need to make an AI one. There may be remaining human
    # changes both in the previous phantom chain and uncomitted in the
    # working copy, but those will get picked up by the next phantom commit.
    new_bookmark_node = None
    if remaining_paths:
        with util.rust_tracing_span("phantom_commits prepare new phantom"):
            changes: dict[HgPathT, ChangeValueT] = {}
            for path in remaining_paths:
                try:
                    flags = read_flags(wvfs, path)
                except FileNotFoundError:
                    # File disappeared. Exclude it from AI commit.
                    continue
                data = squasher.get_ai_content(path)
                if data is not None:
                    changes[path] = flags, data, None

        if changes:
            with util.rust_tracing_span("phantom_commits commit new phantom"):
                extra = {b"phantom_prev": nodemod.nullhex}
                if aggregated_metadata is not None:
                    extra[b"phantom_metadata"] = aggregated_metadata
                new_bookmark_node = commit_changes(
                    repo=repo,
                    p1=main_node,
                    user=config.ai_user,
                    date=None,
                    message=b"rebased phantom commit",
                    changes=changes,
                    extra=extra,
                )

    with repo.transaction(b"bookmark") as tr:
        if new_bookmark_node:
            rev = nodemod.hex(new_bookmark_node)
            msg = _(b"updating bookmark '%s' to %s\n")
            ui.status(msg % (config.bookmark, rev))
            bookmarks.addbookmarks(
                repo, tr, [config.bookmark], rev=rev, force=True
            )
        else:
            ui.status(_(b"deleting bookmark '%s'\n") % config.bookmark)
            bookmarks.delete(repo, tr, [config.bookmark])

    return main_node


def read_from_repo(ctx: context.changectx, path: HgPathT) -> bytes | None:
    """Read file data from the repo, or None if it is not in ctx."""
    try:
        f = ctx[path]
    except error.ManifestLookupError:
        return None
    return f.data()


def read_flags(wvfs: VfsT, path: HgPathT) -> bytes:
    """Read file flags from disk."""
    mode = wvfs.lstat(path).st_mode
    if stat.S_ISLNK(mode):
        return b"l"
    elif (mode & 0o100) != 0:
        return b"x"
    return b""


def read_flags_and_data(wvfs: VfsT, path: HgPathT) -> tuple[bytes, bytes]:
    """Read file flags and data from disk."""
    mode = wvfs.lstat(path).st_mode
    if stat.S_ISLNK(mode):
        flags = b"l"
    elif (mode & 0o100) != 0:
        flags = b"x"
    else:
        flags = b""
    data = wvfs.readlink(path) if flags == b"l" else wvfs.read(path)
    return flags, data


def convert_description_for_ai(desc: bytes) -> bytes:
    """Return a description for the squashed AI changeset.

    It is derived from the description the user gave for the main changeset.
    """
    first, sep, rest = desc.partition(b"\n")
    return first + b" (AI)" + sep + rest


def commit_changes(
    repo: RepoT,
    p1: NodeIdT,
    user: bytes,
    date: dateutil.hgdate | None,
    message: bytes,
    changes: dict[HgPathT, ChangeValueT],
    extra: dict,
) -> NodeIdT:
    """Do an in-memory commit and return the node."""

    def filectxfn(repo: RepoT, memctx: context.memctx, path: HgPathT):
        val = changes[path]
        if val is None:
            # file deleted
            return None
        if isinstance(val, context.filectx):
            # TODO: Ideally we could just reuse the filenode and skip loading
            # the content from disk. The _filecommit function in commit.py has
            # this fast path logic, but only from a parent, not a sibling.
            flags = val.flags()
            contents = val.data()
            copysource = val.copysource()
        else:
            flags, contents, copysource = val
        islink = flags == b'l'
        isexec = flags == b'x'
        return context.memfilectx(
            repo,
            memctx,
            path,
            contents,
            islink=islink,
            isexec=isexec,
            copysource=copysource,
        )

    ctx = context.memctx(
        repo=repo,
        parents=[p1, repo.nullid],
        text=message,
        files=changes.keys(),
        filectxfn=filectxfn,
        user=user,
        date=date,
        extra=extra,
    )
    # commitctx is incorrectly annotated as returning None.
    return repo.commitctx(ctx)  # type: ignore


# Only subclass the repo during `hg commit` to avoid affecting other commands
# that create commits such as `hg backout`.
def wrap_commit(orig, ui: UiT, repo: localrepository, *args, **opts):
    unfi = repo.unfiltered()
    orig_class = unfi.__class__

    class PhantomCommitsRepo(orig_class):
        # Override the special method commitctx_for_commit, not commitctx, to
        # avoid affecting `hg commit --amend`.
        def commitctx_for_commit(
            self, cctx: context.workingcommitctx, status: StatusT
        ) -> NodeIdT:
            return commitctx_for_commit(self, cctx, status)

    unfi.__class__ = PhantomCommitsRepo
    try:
        return orig(ui, repo, *args, **opts)
    finally:
        unfi.__class__ = orig_class


def uisetup(ui: UiT):
    extensions.wrapcommand(commands.table, b"commit", wrap_commit)
