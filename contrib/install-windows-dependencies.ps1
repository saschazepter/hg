# install-dependencies.ps1 - Install Windows dependencies for building Mercurial
#
# Copyright 2019 Gregory Szorc <gregory.szorc@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

# This script can be used to bootstrap a Mercurial build environment on
# Windows.
#
# The script makes a lot of assumptions about how things should work.
# For example, the install location of Python is hardcoded to c:\hgdev\*.
#
# The script should be executed from a PowerShell with elevated privileges
# if you don't want to see a UAC prompt for various installers.
#
# The script is tested on Windows 10 and Windows Server 2019 (in EC2).

$VS_BUILD_TOOLS_URL = "https://download.visualstudio.microsoft.com/download/pr/a1603c02-8a66-4b83-b821-811e3610a7c4/aa2db8bb39e0cbd23e9940d8951e0bc3/vs_buildtools.exe"
$VS_BUILD_TOOLS_SHA256 = "911E292B8E6E5F46CBC17003BDCD2D27A70E616E8D5E6E69D5D489A605CAA139"

$PYTHON38_x86_URL = "https://www.python.org/ftp/python/3.8.10/python-3.8.10.exe"
$PYTHON38_x86_SHA256 = "ad07633a1f0cd795f3bf9da33729f662281df196b4567fa795829f3bb38a30ac"
$PYTHON38_x64_URL = "https://www.python.org/ftp/python/3.8.10/python-3.8.10-amd64.exe"
$PYTHON38_x64_SHA256 = "7628244cb53408b50639d2c1287c659f4e29d3dfdb9084b11aed5870c0c6a48a"

$PYTHON39_x86_URL = "https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
$PYTHON39_x86_SHA256 = "F363935897BF32ADF6822BA15ED1BFED7AE2AE96477F0262650055B6E9637C35"
$PYTHON39_X64_URL = "https://www.python.org/ftp/python/3.9.13/python-3.9.13-amd64.exe"
$PYTHON39_x64_SHA256 = "FB3D0466F3754752CA7FD839A09FFE53375FF2C981279FD4BC23A005458F7F5D"

$PYTHON310_x86_URL = "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe"
$PYTHON310_x86_SHA256 = "BD115A575E86E61CEA9136C5A2C47E090BA484DC2DEE8B51A34111BB094266D5"
$PYTHON310_X64_URL = "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe"
$PYTHON310_x64_SHA256 = "D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B"

# Final installer release for this version
$PYTHON311_x86_URL = "https://www.python.org/ftp/python/3.11.9/python-3.11.9.exe"
$PYTHON311_x86_SHA256 = "AF19E5E2F03E715A822181F2CB7D4EFEF4EDA13FA4A2DB6DA12E998E46F5CBF9"
$PYTHON311_X64_URL = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
$PYTHON311_x64_SHA256 = "5EE42C4EEE1E6B4464BB23722F90B45303F79442DF63083F05322F1785F5FDDE"

$PYTHON312_X86_URL = "https://www.python.org/ftp/python/3.12.7/python-3.12.7.exe"
$PYTHON312_x86_SHA256 = "5BF4F3F0A58E1661A26754AE2FF0C2499EFFF093F34833EE0921922887FB3851"
$PYTHON312_x64_URL = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe"
$PYTHON312_x64_SHA256 = "1206721601A62C925D4E4A0DCFC371E88F2DDBE8C0C07962EBB2BE9B5BDE4570"

$PYTHON313_x86_URL = "https://www.python.org/ftp/python/3.13.0/python-3.13.0.exe"
$PYTHON313_x86_SHA256 = "A9BE7082CCD3D0B947D14A87BCEADB1A3551382A68FCB64D245A2EBCC779B272"
$PYTHON313_X64_URL = "https://www.python.org/ftp/python/3.13.0/python-3.13.0-amd64.exe"
$PYTHON313_x64_SHA256 = "78156AD0CF0EC4123BFB5333B40F078596EBF15F2D062A10144863680AFBDEFC"

# PIP 24.2.
$PIP_URL = "https://github.com/pypa/get-pip/raw/66d8a0f637083e2c3ddffc0cb1e65ce126afb856/public/get-pip.py"
$PIP_SHA256 = "6FB7B781206356F45AD79EFBB19322CAA6C2A5AD39092D0D44D0FEC94117E118"

$INNO_SETUP_URL = "http://files.jrsoftware.org/is/5/innosetup-5.6.1-unicode.exe"
$INNO_SETUP_SHA256 = "27D49E9BC769E9D1B214C153011978DB90DC01C2ACD1DDCD9ED7B3FE3B96B538"

$MINGW_BIN_URL = "https://osdn.net/frs/redir.php?m=constant&f=mingw%2F68260%2Fmingw-get-0.6.3-mingw32-pre-20170905-1-bin.zip"
$MINGW_BIN_SHA256 = "2AB8EFD7C7D1FC8EAF8B2FA4DA4EEF8F3E47768284C021599BC7435839A046DF"

$MERCURIAL_WHEEL_FILENAME = "mercurial-6.9-cp39-cp39-win_amd64.whl"
$MERCURIAL_WHEEL_URL = "https://files.pythonhosted.org/packages/ca/60/3dd09a2c30067ed003f7ec05f704bd69e9adf19c794b0a6351e75499dda1/$MERCURIAL_WHEEL_FILENAME"
$MERCURIAL_WHEEL_SHA256 = "ec2a00f73da23123c52ec68206b6ebed1a214c569cda37aaab7b343ef539c7c3"

$RUSTUP_INIT_URL = "https://static.rust-lang.org/rustup/archive/1.21.1/x86_64-pc-windows-gnu/rustup-init.exe"
$RUSTUP_INIT_SHA256 = "d17df34ba974b9b19cf5c75883a95475aa22ddc364591d75d174090d55711c72"

$PYOXIDIZER_URL = "https://github.com/indygreg/PyOxidizer/releases/download/pyoxidizer%2F0.17/PyOxidizer-0.17.0-x64.msi"
$PYOXIDIZER_SHA256 = "85c3bc21a18eb5e2db4dad87cca29accf725c7d59dd364a853ab5099c272024b"

# Writing progress slows down downloads substantially. So disable it.
$progressPreference = 'silentlyContinue'

function Secure-Download($url, $path, $sha256) {
    if (Test-Path -Path $path) {
        Get-FileHash -Path $path -Algorithm SHA256 -OutVariable hash

        if ($hash.Hash -eq $sha256) {
            Write-Output "SHA256 of $path verified as $sha256"
            return
        }

        Write-Output "hash mismatch on $path; downloading again"
    }

    Write-Output "downloading $url to $path"
    Invoke-WebRequest -Uri $url -OutFile $path
    Get-FileHash -Path $path -Algorithm SHA256 -OutVariable hash

    if ($hash.Hash -ne $sha256) {
        Remove-Item -Path $path
        throw "hash mismatch when downloading $url; got $($hash.Hash), expected $sha256"
    }
}

function Invoke-Process($path, $arguments) {
    echo "$path $arguments"

    $p = Start-Process -FilePath $path -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

    if ($p.ExitCode -ne 0) {
        # If the MSI is already installed, ignore the error
        if ($p.ExitCode -eq 1638) {
            Write-Output "program already installed; continuing..."
        }
        else {
            throw "process exited non-0: $($p.ExitCode)"
        }
    }
}

function Install-Python3($name, $installer, $dest, $pip) {
    Write-Output "installing $name"

    # We hit this when running the script as part of Simple Systems Manager in
    # EC2. The Python 3 installer doesn't seem to like per-user installs
    # when running as the SYSTEM user. So enable global installs if executed in
    # this mode.
    if ($env:USERPROFILE -eq "C:\Windows\system32\config\systemprofile") {
        Write-Output "running with SYSTEM account; installing for all users"
        $allusers = "1"
    }
    else {
        $allusers = "0"
    }

    Invoke-Process $installer "/quiet TargetDir=${dest} InstallAllUsers=${allusers} AssociateFiles=0 CompileAll=0 PrependPath=0 Include_doc=0 Include_launcher=0 InstallLauncherAllUsers=0 Include_pip=0 Include_test=0"
    Invoke-Process ${dest}\python.exe $pip
}

function Install-Rust($prefix) {
    Write-Output "installing Rust"
    $Env:RUSTUP_HOME = "${prefix}\rustup"
    $Env:CARGO_HOME = "${prefix}\cargo"

    Invoke-Process "${prefix}\assets\rustup-init.exe" "-y --default-host x86_64-pc-windows-msvc"
    Invoke-Process "${prefix}\cargo\bin\rustup.exe" "target add i686-pc-windows-msvc"
    Invoke-Process "${prefix}\cargo\bin\rustup.exe" "install 1.52.0"
    Invoke-Process "${prefix}\cargo\bin\rustup.exe" "component add clippy"
}

function Install-Dependencies($prefix) {
    if (!(Test-Path -Path $prefix\assets)) {
        New-Item -Path $prefix\assets -ItemType Directory
    }

    $pip = "${prefix}\assets\get-pip.py"

    Secure-Download $PYTHON38_x86_URL ${prefix}\assets\python38-x86.exe $PYTHON38_x86_SHA256
    Secure-Download $PYTHON38_x64_URL ${prefix}\assets\python38-x64.exe $PYTHON38_x64_SHA256
    Secure-Download $PYTHON39_x86_URL ${prefix}\assets\python39-x86.exe $PYTHON39_x86_SHA256
    Secure-Download $PYTHON39_x64_URL ${prefix}\assets\python39-x64.exe $PYTHON39_x64_SHA256
    Secure-Download $PYTHON310_x86_URL ${prefix}\assets\python310-x86.exe $PYTHON310_x86_SHA256
    Secure-Download $PYTHON310_x64_URL ${prefix}\assets\python310-x64.exe $PYTHON310_x64_SHA256
    Secure-Download $PYTHON311_x86_URL ${prefix}\assets\python311-x86.exe $PYTHON311_x86_SHA256
    Secure-Download $PYTHON311_x64_URL ${prefix}\assets\python311-x64.exe $PYTHON311_x64_SHA256
    Secure-Download $PYTHON312_x86_URL ${prefix}\assets\python312-x86.exe $PYTHON312_x86_SHA256
    Secure-Download $PYTHON312_x64_URL ${prefix}\assets\python312-x64.exe $PYTHON312_x64_SHA256
    Secure-Download $PYTHON313_x86_URL ${prefix}\assets\python313-x86.exe $PYTHON313_x86_SHA256
    Secure-Download $PYTHON313_x64_URL ${prefix}\assets\python313-x64.exe $PYTHON313_x64_SHA256

    Secure-Download $PIP_URL ${pip} $PIP_SHA256
    Secure-Download $VS_BUILD_TOOLS_URL ${prefix}\assets\vs_buildtools.exe $VS_BUILD_TOOLS_SHA256
    Secure-Download $INNO_SETUP_URL ${prefix}\assets\InnoSetup.exe $INNO_SETUP_SHA256
    Secure-Download $MINGW_BIN_URL ${prefix}\assets\mingw-get-bin.zip $MINGW_BIN_SHA256
    Secure-Download $MERCURIAL_WHEEL_URL ${prefix}\assets\${MERCURIAL_WHEEL_FILENAME} $MERCURIAL_WHEEL_SHA256
    Secure-Download $RUSTUP_INIT_URL ${prefix}\assets\rustup-init.exe $RUSTUP_INIT_SHA256
    Secure-Download $PYOXIDIZER_URL ${prefix}\assets\PyOxidizer.msi $PYOXIDIZER_SHA256

    Install-Python3 "Python 3.8 32-bit" ${prefix}\assets\python38-x86.exe ${prefix}\python38-x86 ${pip}
    Install-Python3 "Python 3.8 64-bit" ${prefix}\assets\python38-x64.exe ${prefix}\python38-x64 ${pip}
    Install-Python3 "Python 3.9 32-bit" ${prefix}\assets\python39-x86.exe ${prefix}\python39-x86 ${pip}
    Install-Python3 "Python 3.9 64-bit" ${prefix}\assets\python39-x64.exe ${prefix}\python39-x64 ${pip}
    Install-Python3 "Python 3.10 32-bit" ${prefix}\assets\python310-x86.exe ${prefix}\python310-x86 ${pip}
    Install-Python3 "Python 3.10 64-bit" ${prefix}\assets\python310-x64.exe ${prefix}\python310-x64 ${pip}
    Install-Python3 "Python 3.11 32-bit" ${prefix}\assets\python311-x86.exe ${prefix}\python311-x86 ${pip}
    Install-Python3 "Python 3.11 64-bit" ${prefix}\assets\python311-x64.exe ${prefix}\python311-x64 ${pip}
    Install-Python3 "Python 3.12 32-bit" ${prefix}\assets\python312-x86.exe ${prefix}\python312-x86 ${pip}
    Install-Python3 "Python 3.12 64-bit" ${prefix}\assets\python312-x64.exe ${prefix}\python312-x64 ${pip}
    Install-Python3 "Python 3.13 32-bit" ${prefix}\assets\python313-x86.exe ${prefix}\python313-x86 ${pip}
    Install-Python3 "Python 3.13 64-bit" ${prefix}\assets\python313-x64.exe ${prefix}\python313-x64 ${pip}

    Write-Output "installing Visual Studio 2017 Build Tools and SDKs"
    Invoke-Process ${prefix}\assets\vs_buildtools.exe "--quiet --wait --norestart --nocache --channelUri https://aka.ms/vs/15/release/channel --add Microsoft.VisualStudio.Workload.MSBuildTools --add Microsoft.VisualStudio.Component.Windows10SDK.17763 --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows10SDK --add Microsoft.VisualStudio.Component.VC.140 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64"

    Write-Output "installing PyOxidizer"
    Invoke-Process msiexec.exe "/i ${prefix}\assets\PyOxidizer.msi /l* ${prefix}\assets\PyOxidizer.log /quiet"

    Install-Rust ${prefix}

    Write-Output "installing Inno Setup"
    Invoke-Process ${prefix}\assets\InnoSetup.exe "/SP- /VERYSILENT /SUPPRESSMSGBOXES"

    Write-Output "extracting MinGW base archive"
    Expand-Archive -Path ${prefix}\assets\mingw-get-bin.zip -DestinationPath "${prefix}\MinGW" -Force

    Write-Output "updating MinGW package catalogs"
    Invoke-Process ${prefix}\MinGW\bin\mingw-get.exe "update"

    Write-Output "installing MinGW packages"
    Invoke-Process ${prefix}\MinGW\bin\mingw-get.exe "install msys-base msys-coreutils msys-diffutils msys-unzip"

    # Construct a virtualenv useful for bootstrapping. It conveniently contains a
    # Mercurial install.
    Write-Output "creating bootstrap virtualenv with Mercurial"
    Invoke-Process "$prefix\python39-x64\python.exe" "-m venv ${prefix}\venv-bootstrap"
    Invoke-Process "${prefix}\venv-bootstrap\Scripts\pip.exe" "install ${prefix}\assets\${MERCURIAL_WHEEL_FILENAME}"
}

function Clone-Mercurial-Repo($prefix, $repo_url, $dest) {
    Write-Output "cloning $repo_url to $dest"
    # TODO Figure out why CA verification isn't working in EC2 and remove
    # --insecure.
    Invoke-Process "${prefix}\venv-bootstrap\Scripts\python.exe" "${prefix}\venv-bootstrap\Scripts\hg clone --insecure $repo_url $dest"

    # Mark repo as non-publishing by default for convenience.
    Add-Content -Path "$dest\.hg\hgrc" -Value "`n[phases]`npublish = false"
}

$prefix = "c:\hgdev"
Install-Dependencies $prefix
Clone-Mercurial-Repo $prefix "https://www.mercurial-scm.org/repo/hg" $prefix\src
