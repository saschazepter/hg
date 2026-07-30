from __future__ import annotations


def run():
    import os
    import sys

    # Make `pip install --user ...` packages available to the official Windows
    # build.  Most py2 packaging installs directly into the system python
    # environment, so no changes are necessary for other platforms.  The
    # Windows py2 package uses py2exe, which lacks a `site` module.  Hardcode
    # it according to the documentation.
    if getattr(sys, 'frozen', None) == 'console_exe':
        vi = sys.version_info
        environ = getattr(os, "environ")  # trick check-code
        appdata = environ.get('APPDATA')
        if appdata:
            sys.path.append(
                os.path.join(
                    appdata,
                    'Python',
                    'Python%d%d' % (vi[0], vi[1]),
                    'site-packages',
                )
            )

    from . import demandimport

    with demandimport.tracing.log('hg script'):
        demandimport.enable()
        from . import dispatch

        dispatch.run()


if __name__ == '__main__':
    run()
