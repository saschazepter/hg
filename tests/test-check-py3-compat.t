#require test-repo pure

  $ . "$TESTDIR/helpers-testrepo.sh"
  $ cd "$TESTDIR"/..

#if no-py3
  $ testrepohg files 'set:(**.py)' \
  > -X contrib/automation/ \
  > -X contrib/packaging/hgpackaging/ \
  > -X contrib/packaging/inno/ \
  > -X contrib/packaging/packaging.py \
  > -X contrib/packaging/wix/ \
  > -X hgdemandimport/demandimportpy2.py \
  > -X mercurial/thirdparty/cbor \
  > | sed 's|\\|/|g' | xargs "$PYTHON" contrib/check-py3-compat.py
  contrib/python-zstandard/setup.py not using absolute_import
  contrib/python-zstandard/setup_zstd.py not using absolute_import
  contrib/python-zstandard/tests/common.py not using absolute_import
  contrib/python-zstandard/tests/test_buffer_util.py not using absolute_import
  contrib/python-zstandard/tests/test_compressor.py not using absolute_import
  contrib/python-zstandard/tests/test_compressor_fuzzing.py not using absolute_import
  contrib/python-zstandard/tests/test_data_structures.py not using absolute_import
  contrib/python-zstandard/tests/test_data_structures_fuzzing.py not using absolute_import
  contrib/python-zstandard/tests/test_decompressor.py not using absolute_import
  contrib/python-zstandard/tests/test_decompressor_fuzzing.py not using absolute_import
  contrib/python-zstandard/tests/test_estimate_sizes.py not using absolute_import
  contrib/python-zstandard/tests/test_module_attributes.py not using absolute_import
  contrib/python-zstandard/tests/test_train_dictionary.py not using absolute_import
  setup.py not using absolute_import
#endif

#if py3
  $ testrepohg files 'set:(**.py) - grep(pygments)' \
  > -X hgdemandimport/demandimportpy2.py \
  > -X hgext/fsmonitor/pywatchman \
  > -X mercurial/cffi \
  > -X mercurial/thirdparty \
  > | sed 's|\\|/|g' | xargs "$PYTHON" contrib/check-py3-compat.py \
  > | sed 's/[0-9][0-9]*)$/*)/'
  hgext/convert/transport.py: error importing: <*Error> No module named 'svn.client' (error at transport.py:*) (glob) (?)
  hgext/infinitepush/sqlindexapi.py: error importing: <*Error> No module named 'mysql' (error at sqlindexapi.py:*) (glob) (?)
  mercurial/scmwindows.py: error importing: <ValueError> _type_ 'v' not supported (error at win32.py:*) (no-windows !)
  mercurial/win32.py: error importing: <ValueError> _type_ 'v' not supported (error at win32.py:*) (no-windows !)
  mercurial/windows.py: error importing: <*Error> No module named 'msvcrt' (error at windows.py:*) (glob) (no-windows !)
  mercurial/posix.py: error importing: <*Error> No module named 'fcntl' (error at posix.py:*) (glob) (windows !)
  mercurial/scmposix.py: error importing: <*Error> No module named 'fcntl' (error at scmposix.py:*) (glob) (windows !)
#endif

#if py3 pygments
  $ testrepohg files 'set:(**.py) and grep(pygments)' | sed 's|\\|/|g' \
  > | xargs "$PYTHON" contrib/check-py3-compat.py \
  > | sed 's/[0-9][0-9]*)$/*)/'
#endif
