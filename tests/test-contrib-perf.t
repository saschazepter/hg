#require test-repo

Set vars:

  $ . "$TESTDIR/helpers-testrepo.sh"
  $ CONTRIBDIR="$TESTDIR/../contrib"

Prepare repo:

  $ hg init

  $ echo this is file a > a
  $ hg add a
  $ hg commit -m first

  $ echo adding to file a >> a
  $ hg commit -m second

  $ echo adding more to file a >> a
  $ hg commit -m third

  $ hg up -r 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo merge-this >> a
  $ hg commit -m merge-able
  created new head

  $ hg up -r 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

perfstatus

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > perf=$CONTRIBDIR/perf.py
  > [perf]
  > presleep=0
  > stub=on
  > parentscount=1
  > EOF
  $ hg help -e perf
  perf extension - helper extension to measure performance
  
  Configurations
  ==============
  
  "perf"
  ------
  
  "all-timing"
      When set, additional statistics will be reported for each benchmark: best,
      worst, median average. If not set only the best timing is reported
      (default: off).
  
  "presleep"
    number of second to wait before any group of runs (default: 1)
  
  "pre-run"
    number of run to perform before starting measurement.
  
  "profile-benchmark"
    Enable profiling for the benchmarked section. (The first iteration is
    benchmarked)
  
  "run-limits"
    Control the number of runs each benchmark will perform. The option value
    should be a list of '<time>-<numberofrun>' pairs. After each run the
    conditions are considered in order with the following logic:
  
        If benchmark has been running for <time> seconds, and we have performed
        <numberofrun> iterations, stop the benchmark,
  
    The default value is: '3.0-100, 10.0-3'
  
  "stub"
      When set, benchmarks will only be run once, useful for testing (default:
      off)
  
  list of commands:
  
   perf::addremove
                 (no help text available)
   perf::ancestors
                 (no help text available)
   perf::ancestorset
                 (no help text available)
   perf::annotate
                 (no help text available)
   perf::bdiff   benchmark a bdiff between revisions
   perf::bookmarks
                 benchmark parsing bookmarks from disk to memory
   perf::branchmap
                 benchmark the update of a branchmap
   perf::branchmapload
                 benchmark reading the branchmap
   perf::branchmapupdate
                 benchmark branchmap update from for <base> revs to <target>
                 revs
   perf::bundleread
                 Benchmark reading of bundle files.
   perf::cca     (no help text available)
   perf::changegroupchangelog
                 Benchmark producing a changelog group for a changegroup.
   perf::changeset
                 (no help text available)
   perf::ctxfiles
                 (no help text available)
   perf::diffwd  Profile diff of working directory changes
   perf::dirfoldmap
                 benchmap a 'dirstate._map.dirfoldmap.get()' request
   perf::dirs    (no help text available)
   perf::dirstate
                 benchmap the time of various distate operations
   perf::dirstatedirs
                 benchmap a 'dirstate.hasdir' call from an empty 'dirs' cache
   perf::dirstatefoldmap
                 benchmap a 'dirstate._map.filefoldmap.get()' request
   perf::dirstatewrite
                 benchmap the time it take to write a dirstate on disk
   perf::discovery
                 benchmark discovery between local repo and the peer at given
                 path
   perf::fncacheencode
                 (no help text available)
   perf::fncacheload
                 (no help text available)
   perf::fncachewrite
                 (no help text available)
   perf::heads   benchmark the computation of a changelog heads
   perf::helper-mergecopies
                 find statistics about potential parameters for
                 'perfmergecopies'
   perf::helper-pathcopies
                 find statistic about potential parameters for the
                 'perftracecopies'
   perf::ignore  benchmark operation related to computing ignore
   perf::index   benchmark index creation time followed by a lookup
   perf::linelogedits
                 (no help text available)
   perf::loadmarkers
                 benchmark the time to parse the on-disk markers for a repo
   perf::log     (no help text available)
   perf::lookup  (no help text available)
   perf::lrucachedict
                 (no help text available)
   perf::manifest
                 benchmark the time to read a manifest from disk and return a
                 usable
   perf::mergecalculate
                 (no help text available)
   perf::mergecopies
                 measure runtime of 'copies.mergecopies'
   perf::moonwalk
                 benchmark walking the changelog backwards
   perf::nodelookup
                 (no help text available)
   perf::nodemap
                 benchmark the time necessary to look up revision from a cold
                 nodemap
   perf::parents
                 benchmark the time necessary to fetch one changeset's parents.
   perf::pathcopies
                 benchmark the copy tracing logic
   perf::phases  benchmark phasesets computation
   perf::phasesremote
                 benchmark time needed to analyse phases of the remote server
   perf::progress
                 printing of progress bars
   perf::rawfiles
                 (no help text available)
   perf::revlogchunks
                 Benchmark operations on revlog chunks.
   perf::revlogindex
                 Benchmark operations against a revlog index.
   perf::revlogrevision
                 Benchmark obtaining a revlog revision.
   perf::revlogrevisions
                 Benchmark reading a series of revisions from a revlog.
   perf::revlogwrite
                 Benchmark writing a series of revisions to a revlog.
   perf::revrange
                 (no help text available)
   perf::revset  benchmark the execution time of a revset
   perf::startup
                 (no help text available)
   perf::status  benchmark the performance of a single status call
   perf::tags    (no help text available)
   perf::templating
                 test the rendering time of a given template
   perf::unidiff
                 benchmark a unified diff between revisions
   perf::volatilesets
                 benchmark the computation of various volatile set
   perf::walk    (no help text available)
   perf::write   microbenchmark ui.write (and others)
  
  (use 'hg help -v perf' to show built-in aliases and global options)

  $ hg help perfaddremove
  hg perf::addremove
  
  aliases: perfaddremove
  
  (no help text available)
  
  options:
  
   -T --template TEMPLATE display with template
  
  (some details hidden, use --verbose to show complete help)

  $ hg perfaddremove
  $ hg perfancestors
  $ hg perfancestorset 2
  $ hg perfannotate a
  $ hg perfbdiff -c 1
  $ hg perfbdiff --alldata 1
  $ hg perfunidiff -c 1
  $ hg perfunidiff --alldata 1
  $ hg perfbookmarks
  $ hg perfbranchmap
  $ hg perfbranchmapload
  $ hg perfbranchmapupdate --base "not tip" --target "tip"
  benchmark of branchmap with 3 revisions with 1 new ones
  $ hg perfcca
  $ hg perfchangegroupchangelog
  $ hg perfchangegroupchangelog --cgversion 01
  $ hg perfchangeset 2
  $ hg perfctxfiles 2
  $ hg perfdiffwd
  $ hg perfdirfoldmap
  $ hg perfdirs
  $ hg perfdirstate
  $ hg perfdirstate --contains
  $ hg perfdirstate --iteration
  $ hg perfdirstatedirs
  $ hg perfdirstatefoldmap
  $ hg perfdirstatewrite
#if repofncache
  $ hg perffncacheencode
  $ hg perffncacheload
  $ hg debugrebuildfncache
  fncache already up to date
  $ hg perffncachewrite
  $ hg debugrebuildfncache
  fncache already up to date
#endif
  $ hg perfheads
  $ hg perfignore
  $ hg perfindex
  $ hg perflinelogedits -n 1
  $ hg perfloadmarkers
  $ hg perflog
  $ hg perflookup 2
  $ hg perflrucache
  $ hg perfmanifest 2
  $ hg perfmanifest -m 44fe2c8352bb3a478ffd7d8350bbc721920134d1
  $ hg perfmanifest -m 44fe2c8352bb
  abort: manifest revision must be integer or full node
  [255]
  $ hg perfmergecalculate -r 3
  $ hg perfmoonwalk
  $ hg perfnodelookup 2
  $ hg perfpathcopies 1 2
  $ hg perfprogress --total 1000
  $ hg perfrawfiles 2
  $ hg perfrevlogindex -c
#if reporevlogstore
  $ hg perfrevlogrevisions .hg/store/data/a.i
#endif
  $ hg perfrevlogrevision -m 0
  $ hg perfrevlogchunks -c
  $ hg perfrevrange
  $ hg perfrevset 'all()'
  $ hg perfstartup
  $ hg perfstatus
  $ hg perfstatus --dirstate
  $ hg perftags
  $ hg perftemplating
  $ hg perfvolatilesets
  $ hg perfwalk
  $ hg perfparents
  $ hg perfdiscovery -q .

Test run control
----------------

Simple single entry

  $ hg perfparents --config perf.stub=no --config perf.run-limits='0.000000001-15'
  ! wall * comb * user * sys * (best of 15) (glob)

Multiple entries

  $ hg perfparents --config perf.stub=no --config perf.run-limits='500000-1, 0.000000001-5'
  ! wall * comb * user * sys * (best of 5) (glob)

error case are ignored

  $ hg perfparents --config perf.stub=no --config perf.run-limits='500, 0.000000001-5'
  malformatted run limit entry, missing "-": 500
  ! wall * comb * user * sys * (best of 5) (glob)
  $ hg perfparents --config perf.stub=no --config perf.run-limits='aaa-12, 0.000000001-5'
  malformatted run limit entry, could not convert string to float: aaa: aaa-12 (no-py3 !)
  malformatted run limit entry, could not convert string to float: 'aaa': aaa-12 (py3 !)
  ! wall * comb * user * sys * (best of 5) (glob)
  $ hg perfparents --config perf.stub=no --config perf.run-limits='12-aaaaaa, 0.000000001-5'
  malformatted run limit entry, invalid literal for int() with base 10: 'aaaaaa': 12-aaaaaa
  ! wall * comb * user * sys * (best of 5) (glob)

test actual output
------------------

normal output:

  $ hg perfheads --config perf.stub=no
  ! wall * comb * user * sys * (best of *) (glob)

detailed output:

  $ hg perfheads --config perf.all-timing=yes --config perf.stub=no
  ! wall * comb * user * sys * (best of *) (glob)
  ! wall * comb * user * sys * (max of *) (glob)
  ! wall * comb * user * sys * (avg of *) (glob)
  ! wall * comb * user * sys * (median of *) (glob)

test json output
----------------

normal output:

  $ hg perfheads --template json --config perf.stub=no
  [
   {
    "comb": *, (glob)
    "count": *, (glob)
    "sys": *, (glob)
    "user": *, (glob)
    "wall": * (glob)
   }
  ]

detailed output:

  $ hg perfheads --template json --config perf.all-timing=yes --config perf.stub=no
  [
   {
    "avg.comb": *, (glob)
    "avg.count": *, (glob)
    "avg.sys": *, (glob)
    "avg.user": *, (glob)
    "avg.wall": *, (glob)
    "comb": *, (glob)
    "count": *, (glob)
    "max.comb": *, (glob)
    "max.count": *, (glob)
    "max.sys": *, (glob)
    "max.user": *, (glob)
    "max.wall": *, (glob)
    "median.comb": *, (glob)
    "median.count": *, (glob)
    "median.sys": *, (glob)
    "median.user": *, (glob)
    "median.wall": *, (glob)
    "sys": *, (glob)
    "user": *, (glob)
    "wall": * (glob)
   }
  ]

Test pre-run feature
--------------------

(perf discovery has some spurious output)

  $ hg perfdiscovery . --config perf.stub=no --config perf.run-limits='0.000000001-1' --config perf.pre-run=0
  ! wall * comb * user * sys * (best of 1) (glob)
  searching for changes
  $ hg perfdiscovery . --config perf.stub=no --config perf.run-limits='0.000000001-1' --config perf.pre-run=1
  ! wall * comb * user * sys * (best of 1) (glob)
  searching for changes
  searching for changes
  $ hg perfdiscovery . --config perf.stub=no --config perf.run-limits='0.000000001-1' --config perf.pre-run=3
  ! wall * comb * user * sys * (best of 1) (glob)
  searching for changes
  searching for changes
  searching for changes
  searching for changes

test  profile-benchmark option
------------------------------

Function to check that statprof ran
  $ statprofran () {
  >   egrep 'Sample count:|No samples recorded' > /dev/null
  > }
  $ hg perfdiscovery . --config perf.stub=no --config perf.run-limits='0.000000001-1' --config perf.profile-benchmark=yes 2>&1 | statprofran

Check perf.py for historical portability
----------------------------------------

  $ cd "$TESTDIR/.."

  $ (testrepohg files -r 1.2 glob:mercurial/*.c glob:mercurial/*.py;
  >  testrepohg files -r tip glob:mercurial/*.c glob:mercurial/*.py) |
  > "$TESTDIR"/check-perf-code.py contrib/perf.py
  contrib/perf.py:\d+: (re)
   >     from mercurial import (
   import newer module separately in try clause for early Mercurial
  contrib/perf.py:\d+: (re)
   >     from mercurial import (
   import newer module separately in try clause for early Mercurial
  contrib/perf.py:\d+: (re)
   >     origindexpath = orig.opener.join(indexfile)
   use getvfs()/getsvfs() for early Mercurial
  contrib/perf.py:\d+: (re)
   >     origdatapath = orig.opener.join(datafile)
   use getvfs()/getsvfs() for early Mercurial
  contrib/perf.py:\d+: (re)
   >         vfs = vfsmod.vfs(tmpdir)
   use getvfs()/getsvfs() for early Mercurial
  contrib/perf.py:\d+: (re)
   >         vfs.options = getattr(orig.opener, 'options', None)
   use getvfs()/getsvfs() for early Mercurial
  [1]
