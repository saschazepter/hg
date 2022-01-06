  $ hg init a
  $ cd a
  $ echo a > a
  $ hg ci -A -d'1 0' -m a
  adding a

  $ cd ..

  $ hg init b
  $ cd b
  $ echo b > b
  $ hg ci -A -d'1 0' -m b
  adding b

  $ cd ..

  $ hg clone a c
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd c
  $ cat >> .hg/hgrc <<EOF
  > [paths]
  > relative = ../a
  > EOF
  $ hg pull -f ../b
  pulling from ../b
  searching for changes
  warning: repository is unrelated
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets b6c483daf290
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg merge
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)

  $ cd ..

Testing -R/--repository:

  $ hg -R a tip
  changeset:   0:8580ff50825a
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     a
  
  $ hg --repository b tip
  changeset:   0:b6c483daf290
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     b
  

-R with a URL:

  $ hg -R file:a identify
  8580ff50825a tip
  $ hg -R file://localhost/`pwd`/a/ identify
  8580ff50825a tip

-R with path aliases:

  $ cd c
  $ hg -R default identify
  8580ff50825a tip
  $ hg -R relative identify
  8580ff50825a tip
  $ echo '[paths]' >> $HGRCPATH
  $ echo 'relativetohome = a' >> $HGRCPATH
  $ hg path | grep relativetohome
  relativetohome = $TESTTMP/a
  $ HOME=`pwd`/../ hg path | grep relativetohome
  relativetohome = $TESTTMP/a
  $ HOME=`pwd`/../ hg -R relativetohome identify
  8580ff50825a tip
  $ cd ..

#if no-outer-repo

Implicit -R:

  $ hg ann a/a
  0: a
  $ hg ann a/a a/a
  0: a
  $ hg ann a/a b/b
  abort: no repository found in '$TESTTMP' (.hg not found)
  [10]
  $ hg -R b ann a/a
  abort: a/a not under root '$TESTTMP/b'
  (consider using '--cwd b')
  [255]
  $ hg log
  abort: no repository found in '$TESTTMP' (.hg not found)
  [10]

#endif

Abbreviation of long option:

  $ hg --repo c tip
  changeset:   1:b6c483daf290
  tag:         tip
  parent:      -1:000000000000
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     b
  

earlygetopt with duplicate options (36d23de02da1):

  $ hg --cwd a --cwd b --cwd c tip
  changeset:   1:b6c483daf290
  tag:         tip
  parent:      -1:000000000000
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     b
  
  $ hg --repo c --repository b -R a tip
  changeset:   0:8580ff50825a
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     a
  

earlygetopt short option without following space:

  $ hg -q -Rb tip
  0:b6c483daf290

earlygetopt with illegal abbreviations:

  $ hg --confi "foo.bar=baz"
  abort: option --config may not be abbreviated
  [10]
  $ hg --cw a tip
  abort: option --cwd may not be abbreviated
  [10]
  $ hg --rep a tip
  abort: option -R has to be separated from other options (e.g. not -qR) and --repository may only be abbreviated as --repo
  [10]
  $ hg --repositor a tip
  abort: option -R has to be separated from other options (e.g. not -qR) and --repository may only be abbreviated as --repo
  [10]
  $ hg -qR a tip
  abort: option -R has to be separated from other options (e.g. not -qR) and --repository may only be abbreviated as --repo
  [10]
  $ hg -qRa tip
  abort: option -R has to be separated from other options (e.g. not -qR) and --repository may only be abbreviated as --repo
  [10]

Testing --cwd:

  $ hg --cwd a parents
  changeset:   0:8580ff50825a
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     a
  

Testing -y/--noninteractive - just be sure it is parsed:

  $ hg --cwd a tip -q --noninteractive
  0:8580ff50825a
  $ hg --cwd a tip -q -y
  0:8580ff50825a

Testing -q/--quiet:

  $ hg -R a -q tip
  0:8580ff50825a
  $ hg -R b -q tip
  0:b6c483daf290
  $ hg -R c --quiet parents
  0:8580ff50825a
  1:b6c483daf290

Testing -v/--verbose:

  $ hg --cwd c head -v
  changeset:   1:b6c483daf290
  tag:         tip
  parent:      -1:000000000000
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  files:       b
  description:
  b
  
  
  changeset:   0:8580ff50825a
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  files:       a
  description:
  a
  
  
  $ hg --cwd b tip --verbose
  changeset:   0:b6c483daf290
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  files:       b
  description:
  b
  
  

Testing --config:

  $ hg --cwd c --config paths.quuxfoo=bar paths | grep quuxfoo > /dev/null && echo quuxfoo
  quuxfoo
TODO: add rhg support for detailed exit codes
  $ hg --cwd c --config '' tip -q
  abort: malformed --config option: '' (use --config section.name=value)
  [10]
  $ hg --cwd c --config a.b tip -q
  abort: malformed --config option: 'a.b' (use --config section.name=value)
  [10]
  $ hg --cwd c --config a tip -q
  abort: malformed --config option: 'a' (use --config section.name=value)
  [10]
  $ hg --cwd c --config a.= tip -q
  abort: malformed --config option: 'a.=' (use --config section.name=value)
  [10]
  $ hg --cwd c --config .b= tip -q
  abort: malformed --config option: '.b=' (use --config section.name=value)
  [10]

Testing --debug:

  $ hg --cwd c log --debug
  changeset:   1:b6c483daf2907ce5825c0bb50f5716226281cc1a
  tag:         tip
  phase:       public
  parent:      -1:0000000000000000000000000000000000000000
  parent:      -1:0000000000000000000000000000000000000000
  manifest:    1:23226e7a252cacdc2d99e4fbdc3653441056de49
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  files+:      b
  extra:       branch=default
  description:
  b
  
  
  changeset:   0:8580ff50825a50c8f716709acdf8de0deddcd6ab
  phase:       public
  parent:      -1:0000000000000000000000000000000000000000
  parent:      -1:0000000000000000000000000000000000000000
  manifest:    0:a0c8bcbbb45c63b90b70ad007bf38961f64f2af0
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  files+:      a
  extra:       branch=default
  description:
  a
  
  

Testing --traceback:

#if no-chg no-rhg
  $ hg --cwd c --config x --traceback id 2>&1 | grep -i 'traceback'
  Traceback (most recent call last):
  Traceback (most recent call last): (py3 !)
#else
Traceback for '--config' errors not supported with chg.
  $ hg --cwd c --config x --traceback id 2>&1 | grep -i 'traceback'
  [1]
#endif

Testing --time:

  $ hg --cwd a --time id
  8580ff50825a tip
  time: real * (glob)

Testing --version:

  $ hg --version -q
  Mercurial Distributed SCM * (glob)

hide outer repo
  $ hg init

Testing -h/--help:

#if no-extraextensions

  $ hg -h
  Mercurial Distributed SCM
  
  list of commands:
  
  Repository creation:
  
   clone         make a copy of an existing repository
   init          create a new repository in the given directory
  
  Remote repository management:
  
   incoming      show new changesets found in source
   outgoing      show changesets not found in the destination
   paths         show aliases for remote repositories
   pull          pull changes from the specified source
   push          push changes to the specified destination
   serve         start stand-alone webserver
  
  Change creation:
  
   commit        commit the specified files or all outstanding changes
  
  Change manipulation:
  
   backout       reverse effect of earlier changeset
   graft         copy changes from other branches onto the current branch
   merge         merge another revision into working directory
  
  Change organization:
  
   bookmarks     create a new bookmark or list existing bookmarks
   branch        set or show the current branch name
   branches      list repository named branches
   phase         set or show the current phase name
   tag           add one or more tags for the current or given revision
   tags          list repository tags
  
  File content management:
  
   annotate      show changeset information by line for each file
   cat           output the current or given revision of files
   copy          mark files as copied for the next commit
   diff          diff repository (or selected files)
   grep          search for a pattern in specified files
  
  Change navigation:
  
   bisect        subdivision search of changesets
   heads         show branch heads
   identify      identify the working directory or specified revision
   log           show revision history of entire repository or files
  
  Working directory management:
  
   add           add the specified files on the next commit
   addremove     add all new files, delete all missing files
   files         list tracked files
   forget        forget the specified files on the next commit
   purge         removes files not tracked by Mercurial
   remove        remove the specified files on the next commit
   rename        rename files; equivalent of copy + remove
   resolve       redo merges or set/view the merge status of files
   revert        restore files to their checkout state
   root          print the root (top) of the current working directory
   shelve        save and set aside changes from the working directory
   status        show changed files in the working directory
   summary       summarize working directory state
   unshelve      restore a shelved change to the working directory
   update        update working directory (or switch revisions)
  
  Change import/export:
  
   archive       create an unversioned archive of a repository revision
   bundle        create a bundle file
   export        dump the header and diffs for one or more changesets
   import        import an ordered set of patches
   unbundle      apply one or more bundle files
  
  Repository maintenance:
  
   manifest      output the current or given revision of the project manifest
   recover       roll back an interrupted transaction
   verify        verify the integrity of the repository
  
  Help:
  
   config        show combined config settings from all hgrc files
   help          show help for a given topic or a help overview
   version       output version and copyright information
  
  additional help topics:
  
  Mercurial identifiers:
  
   filesets      Specifying File Sets
   hgignore      Syntax for Mercurial Ignore Files
   patterns      File Name Patterns
   revisions     Specifying Revisions
   urls          URL Paths
  
  Mercurial output:
  
   color         Colorizing Outputs
   dates         Date Formats
   diffs         Diff Formats
   templating    Template Usage
  
  Mercurial configuration:
  
   config        Configuration Files
   environment   Environment Variables
   extensions    Using Additional Features
   flags         Command-line flags
   hgweb         Configuring hgweb
   merge-tools   Merge Tools
   pager         Pager Support
   rust          Rust in Mercurial
  
  Concepts:
  
   bundlespec    Bundle File Formats
   evolution     Safely rewriting history (EXPERIMENTAL)
   glossary      Glossary
   phases        Working with Phases
   subrepos      Subrepositories
  
  Miscellaneous:
  
   deprecated    Deprecated Features
   internals     Technical implementation topics
   scripting     Using Mercurial from scripts and automation
  
  (use 'hg help -v' to show built-in aliases and global options)

  $ hg --help
  Mercurial Distributed SCM
  
  list of commands:
  
  Repository creation:
  
   clone         make a copy of an existing repository
   init          create a new repository in the given directory
  
  Remote repository management:
  
   incoming      show new changesets found in source
   outgoing      show changesets not found in the destination
   paths         show aliases for remote repositories
   pull          pull changes from the specified source
   push          push changes to the specified destination
   serve         start stand-alone webserver
  
  Change creation:
  
   commit        commit the specified files or all outstanding changes
  
  Change manipulation:
  
   backout       reverse effect of earlier changeset
   graft         copy changes from other branches onto the current branch
   merge         merge another revision into working directory
  
  Change organization:
  
   bookmarks     create a new bookmark or list existing bookmarks
   branch        set or show the current branch name
   branches      list repository named branches
   phase         set or show the current phase name
   tag           add one or more tags for the current or given revision
   tags          list repository tags
  
  File content management:
  
   annotate      show changeset information by line for each file
   cat           output the current or given revision of files
   copy          mark files as copied for the next commit
   diff          diff repository (or selected files)
   grep          search for a pattern in specified files
  
  Change navigation:
  
   bisect        subdivision search of changesets
   heads         show branch heads
   identify      identify the working directory or specified revision
   log           show revision history of entire repository or files
  
  Working directory management:
  
   add           add the specified files on the next commit
   addremove     add all new files, delete all missing files
   files         list tracked files
   forget        forget the specified files on the next commit
   purge         removes files not tracked by Mercurial
   remove        remove the specified files on the next commit
   rename        rename files; equivalent of copy + remove
   resolve       redo merges or set/view the merge status of files
   revert        restore files to their checkout state
   root          print the root (top) of the current working directory
   shelve        save and set aside changes from the working directory
   status        show changed files in the working directory
   summary       summarize working directory state
   unshelve      restore a shelved change to the working directory
   update        update working directory (or switch revisions)
  
  Change import/export:
  
   archive       create an unversioned archive of a repository revision
   bundle        create a bundle file
   export        dump the header and diffs for one or more changesets
   import        import an ordered set of patches
   unbundle      apply one or more bundle files
  
  Repository maintenance:
  
   manifest      output the current or given revision of the project manifest
   recover       roll back an interrupted transaction
   verify        verify the integrity of the repository
  
  Help:
  
   config        show combined config settings from all hgrc files
   help          show help for a given topic or a help overview
   version       output version and copyright information
  
  additional help topics:
  
  Mercurial identifiers:
  
   filesets      Specifying File Sets
   hgignore      Syntax for Mercurial Ignore Files
   patterns      File Name Patterns
   revisions     Specifying Revisions
   urls          URL Paths
  
  Mercurial output:
  
   color         Colorizing Outputs
   dates         Date Formats
   diffs         Diff Formats
   templating    Template Usage
  
  Mercurial configuration:
  
   config        Configuration Files
   environment   Environment Variables
   extensions    Using Additional Features
   flags         Command-line flags
   hgweb         Configuring hgweb
   merge-tools   Merge Tools
   pager         Pager Support
   rust          Rust in Mercurial
  
  Concepts:
  
   bundlespec    Bundle File Formats
   evolution     Safely rewriting history (EXPERIMENTAL)
   glossary      Glossary
   phases        Working with Phases
   subrepos      Subrepositories
  
  Miscellaneous:
  
   deprecated    Deprecated Features
   internals     Technical implementation topics
   scripting     Using Mercurial from scripts and automation
  
  (use 'hg help -v' to show built-in aliases and global options)

#endif

Not tested: --debugger

