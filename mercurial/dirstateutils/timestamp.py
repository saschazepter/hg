# Copyright Mercurial Contributors
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import absolute_import

import functools
import stat


rangemask = 0x7FFFFFFF


@functools.total_ordering
class timestamp(tuple):
    """
    A Unix timestamp with optional nanoseconds precision,
    modulo 2**31 seconds.

    A 2-tuple containing:

    `truncated_seconds`: seconds since the Unix epoch,
    truncated to its lower 31 bits

    `subsecond_nanoseconds`: number of nanoseconds since `truncated_seconds`.
    When this is zero, the sub-second precision is considered unknown.
    """

    def __new__(cls, value):
        truncated_seconds, subsec_nanos = value
        value = (truncated_seconds & rangemask, subsec_nanos)
        return super(timestamp, cls).__new__(cls, value)

    def __eq__(self, other):
        self_secs, self_subsec_nanos = self
        other_secs, other_subsec_nanos = other
        return self_secs == other_secs and (
            self_subsec_nanos == other_subsec_nanos
            or self_subsec_nanos == 0
            or other_subsec_nanos == 0
        )

    def __gt__(self, other):
        self_secs, self_subsec_nanos = self
        other_secs, other_subsec_nanos = other
        if self_secs > other_secs:
            return True
        if self_secs < other_secs:
            return False
        if self_subsec_nanos == 0 or other_subsec_nanos == 0:
            # they are considered equal, so not "greater than"
            return False
        return self_subsec_nanos > other_subsec_nanos


def zero():
    """
    Returns the `timestamp` at the Unix epoch.
    """
    return tuple.__new__(timestamp, (0, 0))


def mtime_of(stat_result):
    """
    Takes an `os.stat_result`-like object and returns a `timestamp` object
    for its modification time.
    """
    try:
        # TODO: add this attribute to `osutil.stat` objects,
        # see `mercurial/cext/osutil.c`.
        #
        # This attribute is also not available on Python 2.
        nanos = stat_result.st_mtime_ns
    except AttributeError:
        # https://docs.python.org/2/library/os.html#os.stat_float_times
        # "For compatibility with older Python versions,
        #  accessing stat_result as a tuple always returns integers."
        secs = stat_result[stat.ST_MTIME]

        subsec_nanos = 0
    else:
        billion = int(1e9)
        secs = nanos // billion
        subsec_nanos = nanos % billion

    return timestamp((secs, subsec_nanos))
