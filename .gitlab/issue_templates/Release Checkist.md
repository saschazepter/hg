# New Release Manager List

- [ ] Make sure you have access to the Mercurial project on PyPi
- [ ] Make sure you have SSH access and are in the `committers` group on
      mercurial-scm.org
- [ ] Make sure your key is uploaded to some public server
    - [ ] http://keyserver.ubuntu.com/
    - [ ] https://pgp.mit.edu/
    - [ ] https://keys.openpgp.org
- [ ] Inform mercurial-packaging@mercurial-scm.org that a new key will be used
      for signing
- [ ] Get a clone of `hg-release-tools` (ask a previous maintainer)

# Release Checklist

Followed by release managers to prepare releases.

Things to check:

- [ ] Make sure the latest [evolve](https://foss.heptapod.net/mercurial/evolve)
      is compatible
- [ ] Check for queued security patches
- [ ] Check for the **very** occasional mailing list submission
- [ ] Pull from [Heptapod](https://foss.heptapod.net/mercurial/mercurial-devel)
- [ ] Check that the **full** (including platform and py-version compat)
      Heptapod CI passed on the changeset you want to release
- [ ] Add the release notes in a public changeset
- [ ] Run `hg-release-tools/make-release` which does the following:
    - Create a tag
    - Sign it (will prompt for GPG key)
    - Build release tarballs
    - Build all linux wheels (will prompt for `sudo`)
    - Make the tag public
- [ ] Pull from `release-build-X.Y(rcZ)`, update to and publish the `stable`
      branch
- [ ] Push a merge from `stable` into `default` to the CI (hence pushing the
      release changesets)
- [ ] Create the wheels for MacOS and Windows manually (ping mharbison)
- [ ] Copy the new release notes to the appropriate page on
      [the website](https://foss.heptapod.net/mercurial/hg-website)
- [ ] For non-rc versions, write a blog entry as well
- [ ] For major releases:
    - [ ] Create ReleaseX.Y page
    - [ ] Add warning about it being an rc
    - [ ] Replace rc notes when final release is cut
- [ ] Once you have all the wheels, run `hg-release-tools/post-release`
      which does the following:
    - Upload signed release tarball to mercurial-scm.org
    - Upload release wheels to Pypi with `twine`
    - Upload release tarball to Pypi with `twine`
    - Update mercurial-scm.org's latest.dat file
    - Removes the build dir
- [ ] Deploy the website (ping Alphare until we automate it)
- [ ] Tag and push `PythonHglib` if there are new changesets (TODO define this)
- [ ] Ping mercurial-packaging@mercurial-scm.org (see template below)
- [ ] For non-rc versions, ping mercurial@mercurial-scm.org (see template below)
- [ ] Update Matrix topic and IRC topic
    - [ ] For rc releases, be sure to note code freeze if there
- [ ] Update your own Mercurial with the new version 😉

# Packaging message template

```
To: mercurial-packaging@mercurial-scm.org
Subject: Mercurial x.y tagged

Please update your package builds, thanks.
Please also make sure you have the latest evolve version packaged.

Release notes here: https://mercurial-scm.org/relnotes/X.Y

<describe changes in this release important for packagers to note, if any>
```

# User mailing list template


```
To: mercurial@mercurial-scm.org
Subject: Mercurial x.y released

Hello all,

We've just released a new Mercurial version, please try it out!

You can find the release notes here: https://mercurial-scm.org/relnotes/X.Y

<describe changes in this release important for *users* to note, if any>

Thanks,
The Mercurial team.
```
