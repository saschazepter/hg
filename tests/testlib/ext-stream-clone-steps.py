# A utility extension that help taking a break during streamclone operation
#
# This extension is used through two environment variable
#
# HG_TEST_STREAM_WALKED_FILE_3
#
#   path of a file created by the process generating the streaming clone when
#   it is done gathering data and is ready to unlock the repository and move
#   to the streaming of content.
#
# HG_TEST_STREAM_WALKED_FILE_4
#
#   path of a file to be manually created to let the process generating the
#   streaming clone proceed to streaming file content.

from mercurial import (
    encoding,
    extensions,
    streamclone,
    testing,
)


WALKED_FILE_1 = encoding.environ[b'HG_TEST_STREAM_WALKED_FILE_1']
WALKED_FILE_2 = encoding.environ[b'HG_TEST_STREAM_WALKED_FILE_2']
WALKED_FILE_3 = encoding.environ[b'HG_TEST_STREAM_WALKED_FILE_3']
WALKED_FILE_4 = encoding.environ[b'HG_TEST_STREAM_WALKED_FILE_4']


def _test_sync_point_walk_1_2(orig, repo):
    testing.write_file(WALKED_FILE_1)
    testing.wait_file(WALKED_FILE_2)


def _test_sync_point_walk_3(orig, repo):
    testing.write_file(WALKED_FILE_3)


def _test_sync_point_walk_4(orig, repo):
    assert repo._currentlock(repo._lockref) is None
    testing.wait_file(WALKED_FILE_4)


def uisetup(ui):
    extensions.wrapfunction(
        streamclone, '_test_sync_point_walk_1_2', _test_sync_point_walk_1_2
    )

    extensions.wrapfunction(
        streamclone, '_test_sync_point_walk_3', _test_sync_point_walk_3
    )

    extensions.wrapfunction(
        streamclone, '_test_sync_point_walk_4', _test_sync_point_walk_4
    )
