  > EOF
  $ hg init repo
  $ cd repo
  $ cat >> .hg/hgrc <<EOF
  > [phabricator]
  > url = https://phab.mercurial-scm.org/
  > callsign = HG
  D1190 - created - d386117f30e6: create alpha for phabricator test \xe2\x82\xac (esc)
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/a86ed7d85e86-b7a54f3b-amend.hg
  D1190 - updated - d940d39fb603: create alpha for phabricator test \xe2\x82\xac (esc)
  D1191 - created - 4b2486dfc8c7: create beta for phabricator test
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/4b2486dfc8c7-d90584fa-phabsend.hg
  D1192 - created - 24ffd6bca53a: create public change for phabricator testing
  D1193 - created - ac331633be79: create draft change for phabricator testing
  warning: not updating public commit 2:24ffd6bca53a
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/ac331633be79-719b961c-phabsend.hg
  tip                                3:a19f1434f9a5
  D1192                              2:24ffd6bca53a local
  3 {"id": "D1193", "url": "https://phab.mercurial-scm.org/D1193"}
  2 {"id": "D1192", "url": "https://phab.mercurial-scm.org/D1192"}
  1 {"id": "D1191", "url": "https://phab.mercurial-scm.org/D1191"}
  0 {"id": "D1190", "url": "https://phab.mercurial-scm.org/D1190"}
  3 https://phab.mercurial-scm.org/D1193 D1193
  2 https://phab.mercurial-scm.org/D1192 D1192
  1 https://phab.mercurial-scm.org/D1191 D1191
  0 https://phab.mercurial-scm.org/D1190 D1190
  D1253 - created - a7ee4bac036a: create comment for phabricator test
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/a7ee4bac036a-8009b5a0-phabsend.hg
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/81fce7de1b7d-05339e5b-amend.hg
  D1253 - updated - 1acd4b60af38: create comment for phabricator test
  # User test <test>
  # Date 1562019844 0
  # Branch default
  # Node ID da5c8c6bf23a36b6e3af011bc3734460692c23ce
  # Parent  1f634396406d03e565ed645370e5fecd062cf215
  test string time
  diff --git a/test b/test
  --- /dev/null
  +++ b/test
  @@ * @@ (glob)
  +test