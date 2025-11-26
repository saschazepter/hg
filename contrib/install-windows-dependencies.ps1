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
#
# This script can be tested with Docker by installing Docker Desktop, and
# creating a Dockerfile that looks like this:
#
#    $ cat contrib/docker/windows/install-windows-deps-test.Dockerfile
#    escape=`
#
#    FROM "mcr.microsoft.com/windows/servercore:ltsc2025"
#    SHELL [ `
#        "powershell.exe", "-Command", `
#        "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';" `
#    ]
#
#    COPY install-windows-dependencies.ps1 "C:/"
#    COPY vs2022-settings.json "C:/"
#
#    RUN powershell.exe -executionpolicy bypass "C:/install-windows-dependencies.ps1"
#
# ... and then running this from the repository root:
#
#    $ docker build -t install-test -f contrib\docker\windows\install-windows-deps-test.Dockerfile contrib
#
# Note that while the script runs quickly, the finalization of the image and the
# returning of control back to the command prompt takes 2 hours or more.  So, be
# patient- if hasn't errored out, it's working (silently).


$VS_BUILD_TOOLS_URL = "https://download.visualstudio.microsoft.com/download/pr/f2819554-a618-400d-bced-774bb5379965/cc7231dc668ec1fb92f694c66b5d67cba1a9e21127a6e0b31c190f772bd442f2/vs_BuildTools.exe"
$VS_BUILD_TOOLS_SHA256 = "CC7231DC668EC1FB92F694C66B5D67CBA1A9E21127A6E0B31C190F772BD442F2"

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

$PYTHON312_X86_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10.exe"
$PYTHON312_x86_SHA256 = "FDFE385B94F5B8785A0226A886979527FD26EB65DEFDBF29992FD22CC4B0E31E"
$PYTHON312_x64_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe"
$PYTHON312_x64_SHA256 = "67B5635E80EA51072B87941312D00EC8927C4DB9BA18938F7AD2D27B328B95FB"

$PYTHON313_x86_URL = "https://www.python.org/ftp/python/3.13.9/python-3.13.9.exe"
$PYTHON313_x86_SHA256 = "2EA6D14D994602C83306E39D792E74637612240CFA77096DA1AC5BA9BACF613C"
$PYTHON313_X64_URL = "https://www.python.org/ftp/python/3.13.9/python-3.13.9-amd64.exe"
$PYTHON313_x64_SHA256 = "200DDFF856BBFF949D2CC1BE42E8807C07538ABD6B6966D5113A094CF628C5C5"

$PYTHON314_x86_URL = "https://www.python.org/ftp/python/3.14.0/python-3.14.0.exe"
$PYTHON314_x86_SHA256 = "0320E7643FA81ED889D72756BC3B41143EA84C3F1F7F95F3AC541153FFF210FC"
$PYTHON314_X64_URL = "https://www.python.org/ftp/python/3.14.0/python-3.14.0-amd64.exe"
$PYTHON314_x64_SHA256 = "52CEB249F65009D936E6504F97CCE42870C11358CB6E48825E893F54E11620AA"

# PIP 25.3.
$PIP_URL = "https://raw.githubusercontent.com/pypa/get-pip/2b8ba34a7db06e95db117b5fd872ea7941d0777b/public/get-pip.py"
$PIP_SHA256 = "DFFC3658BAADA4EF383F31C3C672D4E5E306A6E376CEE8BEE5DBDF1385525104"

$UV_INSTALLER_URL = "https://github.com/astral-sh/uv/releases/download/0.9.10/uv-installer.ps1"
$UV_INSTALLER_SHA256 = "5886C05017496FCB7ACE9964E0278D1643D2B1F4EB04D1DEC8389DCF321330C0"

$GETTEXT_SETUP_URL = "https://github.com/mlocati/gettext-iconv-windows/releases/download/v0.26-v1.17/gettext0.26-iconv1.17-shared-64.exe"
$GETTEXT_SETUP_SHA256 = "C6BB3EB85ED660E2366EDEBD83EED03074FC277F7C91527C511E52D9235711A7" 

$INNO_SETUP_URL = "http://files.jrsoftware.org/is/5/innosetup-5.6.1-unicode.exe"
$INNO_SETUP_SHA256 = "27D49E9BC769E9D1B214C153011978DB90DC01C2ACD1DDCD9ED7B3FE3B96B538"

$MINGW_BIN_URL = "https://www.mercurial-scm.org/release/windows/artifacts/MinGW.zip"
$MINGW_BIN_SHA256 = "31E98CF5B8C1C58902317F4F592A1C4E0DAF0096008F10FD260CFBA9B3240540"

$MERCURIAL_SETUP_URL = "https://mercurial-scm.org/release/windows/mercurial-7.1.2-x64.msi"
$MERCURIAL_SETUP_SHA256 = "8D702D0ACAD169D52FD64924B36A0D2D5F9908ED44E005DDC0D6F893FFE334DA"

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

    Invoke-Process $installer "/quiet TargetDir=${dest} InstallAllUsers=${allusers} AssociateFiles=0 CompileAll=0 PrependPath=0 Include_doc=0 Include_launcher=1 InstallLauncherAllUsers=1 Include_pip=0 Include_test=0"
    Invoke-Process ${dest}\python.exe $pip
    Invoke-Process ${dest}\python.exe "-m pip install -U --user setuptools==80.9.0 packaging==25.0"
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
    Secure-Download $PYTHON314_x86_URL ${prefix}\assets\python314-x86.exe $PYTHON314_x86_SHA256
    Secure-Download $PYTHON314_x64_URL ${prefix}\assets\python314-x64.exe $PYTHON314_x64_SHA256

    Secure-Download $PIP_URL ${pip} $PIP_SHA256
    Secure-Download $UV_INSTALLER_URL "${prefix}\assets\uv-installer.ps1" $UV_INSTALLER_SHA256

    Secure-Download $VS_BUILD_TOOLS_URL ${prefix}\assets\vs_buildtools.exe $VS_BUILD_TOOLS_SHA256
    Secure-Download $GETTEXT_SETUP_URL ${prefix}\assets\gettext.exe $GETTEXT_SETUP_SHA256
    Secure-Download $INNO_SETUP_URL ${prefix}\assets\InnoSetup.exe $INNO_SETUP_SHA256
    Secure-Download $MINGW_BIN_URL ${prefix}\assets\MinGW.zip $MINGW_BIN_SHA256
    Secure-Download $MERCURIAL_SETUP_URL ${prefix}\assets\Mercurial.msi $MERCURIAL_SETUP_SHA256
    Secure-Download $RUSTUP_INIT_URL ${prefix}\assets\rustup-init.exe $RUSTUP_INIT_SHA256
    Secure-Download $PYOXIDIZER_URL ${prefix}\assets\PyOxidizer.msi $PYOXIDIZER_SHA256

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
    Install-Python3 "Python 3.14 32-bit" ${prefix}\assets\python314-x86.exe ${prefix}\python314-x86 ${pip}
    Install-Python3 "Python 3.14 64-bit" ${prefix}\assets\python314-x64.exe ${prefix}\python314-x64 ${pip}

    Invoke-Process ${prefix}\python313-x64\python.exe "-m pip install --user pipx"
    Invoke-Process ${prefix}\python313-x64\python.exe "-m pipx ensurepath"
    Invoke-Process ${prefix}\python313-x64\python.exe "-m pipx install cibuildwheel==3.3.0"
    Invoke-Process ${prefix}\python313-x64\python.exe "-m pipx install black<24"

    Write-Output "installing uv"
    powershell -ExecutionPolicy Bypass "${prefix}\assets\uv-installer.ps1"

    Write-Output "installing Visual Studio 2022 Build Tools and SDKs"
    Invoke-Process ${prefix}\assets\vs_buildtools.exe "--quiet --wait --norestart --nocache --channelUri https://aka.ms/vs/17/release/channel --config $PSScriptRoot\vs2022-settings.json"

    Write-Output "installing PyOxidizer"
    Invoke-Process msiexec.exe "/i ${prefix}\assets\PyOxidizer.msi /l* ${prefix}\assets\PyOxidizer.log /quiet"

    Install-Rust ${prefix}

    Write-Output "installing GetText Setup"
    Invoke-Process ${prefix}\assets\gettext.exe "/SP- /VERYSILENT /SUPPRESSMSGBOXES"

    Write-Output "installing Inno Setup"
    Invoke-Process ${prefix}\assets\InnoSetup.exe "/SP- /VERYSILENT /SUPPRESSMSGBOXES"

    Write-Output "extracting MinGW archive"
    Expand-Archive -Path ${prefix}\assets\MinGW.zip -DestinationPath "${prefix}" -Force

    # Construct a virtualenv useful for bootstrapping. It conveniently contains a
    # Mercurial install.
    Write-Output "creating bootstrap virtualenv with Mercurial"
    Invoke-Process "$prefix\python39-x64\python.exe" "-m venv ${prefix}\venv-bootstrap"

    Invoke-Process msiexec.exe "/i ${prefix}\assets\Mercurial.msi /l* ${prefix}\assets\Mercurial.log /quiet"
}

function Clone-Mercurial-Repo($prefix, $repo_url, $dest) {
    Write-Output "cloning $repo_url to $dest"
    # TODO Figure out why CA verification isn't working in EC2 and remove
    # --insecure.
    Invoke-Process "$Env:PROGRAMFILES\Mercurial\hg.exe" "clone --insecure $repo_url $dest"

    # Mark repo as non-publishing by default for convenience.
    Add-Content -Path "$dest\.hg\hgrc" -Value "`n[phases]`npublish = false"
}

$prefix = "c:\hgdev"
Install-Dependencies $prefix
Clone-Mercurial-Repo $prefix "https://foss.heptapod.net/mercurial/mercurial-devel" $prefix\src

Write-Output "Setup is complete.  If a Docker image is building, it may take awhile longer."
