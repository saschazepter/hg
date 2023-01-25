# Test admin commands

import functools
import unittest
from mercurial.i18n import _
from mercurial import error, ui as uimod
from mercurial import registrar
from mercurial.admin import verify


class TestAdminVerifyFindChecks(unittest.TestCase):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.ui = uimod.ui.load()
        self.repo = b"fake-repo"

        def cleanup_table(self):
            self.table = {}
            self.alias_table = {}
            self.pyramid = {}

        self.addCleanup(cleanup_table, self)

    def setUp(self):
        self.table = {}
        self.alias_table = {}
        self.pyramid = {}
        check = registrar.verify_check(self.table, self.alias_table)

        # mock some fake check method for tests purpose
        @check(
            b"test.dummy",
            alias=b"dummy",
            options=[],
        )
        def check_dummy(ui, repo, **options):
            return options

        @check(
            b"test.fake",
            alias=b"fake",
            options=[
                (b'a', False, _(b'a boolean value (default: False)')),
                (b'b', True, _(b'a boolean value (default: True)')),
                (b'c', [], _(b'a list')),
            ],
        )
        def check_fake(ui, repo, **options):
            return options

        # alias in the middle of a hierarchy
        check(
            b"test.noop",
            alias=b"noop",
            options=[],
        )(verify.noop_func)

        @check(
            b"test.noop.deeper",
            alias=b"deeper",
            options=[
                (b'y', True, _(b'a boolean value (default: True)')),
                (b'z', [], _(b'a list')),
            ],
        )
        def check_noop_deeper(ui, repo, **options):
            return options

    # args wrapper utilities
    def find_checks(self, name):
        return verify.find_checks(
            name=name,
            table=self.table,
            alias_table=self.alias_table,
            full_pyramid=self.pyramid,
        )

    def pass_options(self, checks, options):
        return verify.pass_options(
            self.ui,
            checks,
            options,
            table=self.table,
            alias_table=self.alias_table,
            full_pyramid=self.pyramid,
        )

    def get_checks(self, names, options):
        return verify.get_checks(
            self.repo,
            self.ui,
            names=names,
            options=options,
            table=self.table,
            alias_table=self.alias_table,
            full_pyramid=self.pyramid,
        )

    # tests find_checks
    def test_find_checks_empty_name(self):
        with self.assertRaises(error.InputError):
            self.find_checks(name=b"")

    def test_find_checks_wrong_name(self):
        with self.assertRaises(error.InputError):
            self.find_checks(name=b"unknown")

    def test_find_checks_dummy(self):
        name = b"test.dummy"
        found = self.find_checks(name=name)
        self.assertEqual(len(found), 1)
        self.assertIn(name, found)
        meth = found[name]
        self.assertTrue(callable(meth))
        self.assertEqual(len(meth.options), 0)

    def test_find_checks_fake(self):
        name = b"test.fake"
        found = self.find_checks(name=name)
        self.assertEqual(len(found), 1)
        self.assertIn(name, found)
        meth = found[name]
        self.assertTrue(callable(meth))
        self.assertEqual(len(meth.options), 3)

    def test_find_checks_noop(self):
        name = b"test.noop.deeper"
        found = self.find_checks(name=name)
        self.assertEqual(len(found), 1)
        self.assertIn(name, found)
        meth = found[name]
        self.assertTrue(callable(meth))
        self.assertEqual(len(meth.options), 2)

    def test_find_checks_from_aliases(self):
        found = self.find_checks(name=b"dummy")
        self.assertEqual(len(found), 1)
        self.assertIn(b"test.dummy", found)

        found = self.find_checks(name=b"fake")
        self.assertEqual(len(found), 1)
        self.assertIn(b"test.fake", found)

        found = self.find_checks(name=b"deeper")
        self.assertEqual(len(found), 1)
        self.assertIn(b"test.noop.deeper", found)

    def test_find_checks_from_root(self):
        found = self.find_checks(name=b"test")
        self.assertEqual(len(found), 3)
        self.assertIn(b"test.dummy", found)
        self.assertIn(b"test.fake", found)
        self.assertIn(b"test.noop.deeper", found)

    def test_find_checks_from_intermediate(self):
        found = self.find_checks(name=b"test.noop")
        self.assertEqual(len(found), 1)
        self.assertIn(b"test.noop.deeper", found)

    def test_find_checks_from_parent_dot_name(self):
        found = self.find_checks(name=b"noop.deeper")
        self.assertEqual(len(found), 1)
        self.assertIn(b"test.noop.deeper", found)

    # tests pass_options
    def test_pass_options_no_checks_no_options(self):
        checks = {}
        options = []

        with self.assertRaises(error.Error):
            self.pass_options(checks=checks, options=options)

    def test_pass_options_fake_empty_options(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = []
        # should end with default options
        expected_options = {"a": False, "b": True, "c": []}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

    def test_pass_options_fake_non_existing_options(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }

        with self.assertRaises(error.InputError):
            options = [b"test.fake:boom=yes"]
            self.pass_options(checks=funcs, options=options)

    def test_pass_options_fake_unrelated_options(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [b"test.noop.deeper:y=yes"]

        with self.assertRaises(error.InputError):
            self.pass_options(checks=funcs, options=options)

    def test_pass_options_fake_set_option(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [b"test.fake:a=yes"]
        expected_options = {"a": True, "b": True, "c": []}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

    def test_pass_options_fake_set_option_with_alias(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [b"fake:a=yes"]
        expected_options = {"a": True, "b": True, "c": []}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

    def test_pass_options_fake_set_all_option(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [b"test.fake:a=yes", b"test.fake:b=no", b"test.fake:c=0,1,2"]
        expected_options = {"a": True, "b": False, "c": [b"0", b"1", b"2"]}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

    def test_pass_options_fake_set_all_option_plus_unexisting(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [
            b"test.fake:a=yes",
            b"test.fake:b=no",
            b"test.fake:c=0,1,2",
            b"test.fake:d=0",
        ]

        with self.assertRaises(error.InputError):
            self.pass_options(checks=funcs, options=options)

    def test_pass_options_fake_duplicate_option(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [
            b"test.fake:a=yes",
            b"test.fake:a=no",
        ]

        with self.assertRaises(error.InputError):
            self.pass_options(checks=funcs, options=options)

    def test_pass_options_fake_set_malformed_option(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        options = [
            b"test.fake:ayes",
            b"test.fake:b==no",
            b"test.fake=",
            b"test.fake:",
            b"test.fa=ke:d=0",
            b"test.fa=ke:d=0",
        ]

        for opt in options:
            with self.assertRaises(error.InputError):
                self.pass_options(checks=funcs, options=[opt])

    def test_pass_options_types(self):
        checks = self.find_checks(name=b"test.fake")
        funcs = {
            n: functools.partial(f, self.ui, self.repo)
            for n, f in checks.items()
        }
        # boolean, yes/no
        options = [b"test.fake:a=yes", b"test.fake:b=no"]
        expected_options = {"a": True, "b": False, "c": []}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

        # boolean, 0/1
        options = [b"test.fake:a=1", b"test.fake:b=0"]
        expected_options = {"a": True, "b": False, "c": []}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

        # boolean, true/false
        options = [b"test.fake:a=true", b"test.fake:b=false"]
        expected_options = {"a": True, "b": False, "c": []}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

        # boolean, wrong type
        options = [b"test.fake:a=si"]
        with self.assertRaises(error.InputError):
            self.pass_options(checks=funcs, options=options)

        # lists
        options = [b"test.fake:c=0,1,2"]
        expected_options = {"a": False, "b": True, "c": [b"0", b"1", b"2"]}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

        options = [b"test.fake:c=x,y,z"]
        expected_options = {"a": False, "b": True, "c": [b"x", b"y", b"z"]}
        func = self.pass_options(checks=funcs, options=options)

        self.assertDictEqual(func[b"test.fake"].keywords, expected_options)

    # tests get_checks
    def test_get_checks_fake(self):
        funcs = self.get_checks(
            names=[b"test.fake"], options=[b"test.fake:a=yes"]
        )
        options = funcs.get(b"test.fake").keywords
        expected_options = {"a": True, "b": True, "c": []}
        self.assertDictEqual(options, expected_options)

    def test_get_checks_multiple_mixed_with_defaults(self):
        funcs = self.get_checks(
            names=[b"test.fake", b"test.noop.deeper", b"test.dummy"],
            options=[
                b"test.noop.deeper:y=no",
                b"test.noop.deeper:z=-1,0,1",
            ],
        )
        options = funcs.get(b"test.fake").keywords
        expected_options = {"a": False, "b": True, "c": []}
        self.assertDictEqual(options, expected_options)

        options = funcs.get(b"test.noop.deeper").keywords
        expected_options = {"y": False, "z": [b"-1", b"0", b"1"]}
        self.assertDictEqual(options, expected_options)

        options = funcs.get(b"test.dummy").keywords
        expected_options = {}
        self.assertDictEqual(options, expected_options)

    def test_broken_pyramid(self):
        """Check that we detect pyramids that can't resolve"""
        table = {}
        alias_table = {}
        pyramid = {}
        check = registrar.verify_check(table, alias_table)

        # Create two checks that clash
        @check(b"test.wrong.intermediate")
        def check_dummy(ui, repo, **options):
            return options

        @check(b"test.wrong.intermediate.thing")
        def check_fake(ui, repo, **options):
            return options

        with self.assertRaises(error.ProgrammingError) as e:
            verify.get_checks(
                self.repo,
                self.ui,
                names=[b"test.wrong.intermediate"],
                options=[],
                table=table,
                alias_table=alias_table,
                full_pyramid=pyramid,
            )
        assert "`verify.noop_func`" in str(e.exception), str(e.exception)


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
