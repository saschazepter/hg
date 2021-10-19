from __future__ import absolute_import, print_function

import sys
import unittest

if sys.version_info[0] < 3:
    base_class = unittest._TextTestResult
else:
    base_class = unittest.TextTestResult


class TestResult(base_class):
    def __init__(self, options, *args, **kwargs):
        super(TestResult, self).__init__(*args, **kwargs)
        self._options = options

        # unittest.TestResult didn't have skipped until 2.7. We need to
        # polyfill it.
        self.skipped = []

        # We have a custom "ignored" result that isn't present in any Python
        # unittest implementation. It is very similar to skipped. It may make
        # sense to map it into skip some day.
        self.ignored = []

        self.times = []
        self._firststarttime = None
        # Data stored for the benefit of generating xunit reports.
        self.successes = []
        self.faildata = {}

    def addFailure(self, test, reason):
        print("FAILURE!", test, reason)

    def addSuccess(self, test):
        print("SUCCESS!", test)

    def addError(self, test, err):
        print("ERR!", test, err)

    # Polyfill.
    def addSkip(self, test, reason):
        print("SKIP!", test, reason)

    def addIgnore(self, test, reason):
        print("IGNORE!", test, reason)

    def onStart(self, test):
        print("ON_START!", test)

    def onEnd(self):
        print("ON_END!")

    def addOutputMismatch(self, test, ret, got, expected):
        return False

    def stopTest(self, test, interrupted=False):
        super(TestResult, self).stopTest(test)
