Integration with the share extension needs improvement. Right now
we've seen some odd bugs.

Address commentary in manifest.excludedmanifestrevlog.add -
specifically we should improve the collaboration with core so that
add() never gets called on an excluded directory and we can improve
the stand-in to raise a ProgrammingError.

Reason more completely about rename-filtering logic in
narrowfilelog. There could be some surprises lurking there.

Formally document the narrowspec format. For bonus points, unify with the
server-specified narrowspec format.

narrowrepo.setnarrowpats() or narrowspec.save() need to make sure
they're holding the wlock.
