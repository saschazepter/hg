Test admin::verify

  $ hg init admin-verify
  $ cd admin-verify

Test normal output

  $ hg admin::verify -c dirstate
  running 1 checks
  running working-copy.dirstate
  checking dirstate

Quiet works

  $ hg admin::verify -c dirstate --quiet

Test no check no options

  $ hg admin::verify
  abort: `checks` required
  [255]

Test single check without options

  $ hg admin::verify -c working-copy.dirstate
  running 1 checks
  running working-copy.dirstate
  checking dirstate

Test single check (alias) without options

  $ hg admin::verify -c dirstate
  running 1 checks
  running working-copy.dirstate
  checking dirstate

Test wrong check name without options

  $ hg admin::verify -c working-copy.dir
  abort: unknown check working-copy.dir
  (did you mean working-copy.dirstate?)
  [10]

Test wrong alias without options

  $ hg admin::verify -c dir
  abort: unknown check dir
  [10]

