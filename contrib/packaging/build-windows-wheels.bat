@echo off

REM - This is a convenience script to build all of the wheels outside of the CI
REM - system.  It requires the cibuildwheel package to be installed, and the
REM - executable on PATH, as well as `msgfmt.exe` from gettext and the x86,
REM - amd64, and arm64 compilers from VS BuildTools.  These can be obtained by
REM - running `contrib/install-windows-dependencies.ps1`.

REM - None of the variable set here live past this script exiting.
setlocal

REM - Disable warning about not being able to test without an arm64 runner.
set CIBW_TEST_SKIP=*-win_arm64


REM - arm64 support starts with py39, but the first arm64 installer wasn't
REM - available until py311, so skip arm64 on the older, EOL versions.
set CIBW_ARCHS=x86 AMD64
set CIBW_BUILD=cp38-* cp39-* cp310-*

cibuildwheel --output-dir dist/wheels

if %errorlevel% neq 0 exit /b %errorlevel%


set CIBW_ARCHS=x86 AMD64 ARM64
set CIBW_BUILD=cp311-* cp312-* cp313-*

cibuildwheel --output-dir dist/wheels

if %errorlevel% neq 0 exit /b %errorlevel%
