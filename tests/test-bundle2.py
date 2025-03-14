import unittest
from mercurial import bundle2, ui as uimod

bundle20 = bundle2.bundle20
unbundle20 = bundle2.unbundle20

ui = uimod.ui.load()


class Bundle2tests(unittest.TestCase):
    def test_nonempty_bundle_forwardchunks(self):
        bundler = bundle20(ui)
        bundler.newpart(
            b'cache:rev-branch-cache', data=b'some-data', mandatory=False
        )
        data = b''.join(list(bundler.getchunks()))
        unbundle = unbundle20(ui, __import__("io").BytesIO(data[4:]))
        forwarded_data = b''.join(list(unbundle._forwardchunks()))
        self.assertEqual(data, forwarded_data)

    def test_empty_bundle_forwardchunks(self):
        bundler = bundle20(ui)
        data = b''.join(list(bundler.getchunks()))
        self.assertEqual(data, b'HG20\0\0\0\0\0\0\0\0')
        unbundle = unbundle20(ui, __import__("io").BytesIO(data[4:]))
        forwarded_data = b''.join(list(unbundle._forwardchunks()))
        self.assertEqual(data, forwarded_data)


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
