@echo off

REM - This is a convenience script to build all of the wheels outside of the CI
REM - system.  It requires the cibuildwheel package to be installed, and the
REM - executable on PATH, as well as `msgfmt.exe` from gettext and the x86,
REM - amd64, and arm64 compilers from VS BuildTools.  These can be obtained by
REM - running `contrib/install-windows-dependencies.ps1`.

REM - None of the variable set here live past this script exiting.
setlocal

cibuildwheel --output-dir dist/wheels

if %errorlevel% neq 0 exit /b %errorlevel%
