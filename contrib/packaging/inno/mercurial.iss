; Script generated by the Inno Setup Script Wizard.
; SEE THE DOCUMENTATION FOR DETAILS ON CREATING INNO SETUP SCRIPT FILES!

#ifndef ARCH
#define ARCH = "x86"
#endif

[Setup]
AppCopyright=Copyright 2005-2025 Olivia Mackall and others
AppName=Mercurial
AppVersion={#VERSION}
OutputBaseFilename=Mercurial-{#VERSION}{#SUFFIX}
#if ARCH == "x64"
AppVerName=Mercurial {#VERSION} (64-bit)
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
#else
AppVerName=Mercurial {#VERSION}
#endif
InfoAfterFile=../postinstall.txt
LicenseFile=Copying.txt
ShowLanguageDialog=yes
AppPublisher=Olivia Mackall and others
AppPublisherURL=https://mercurial-scm.org/
AppSupportURL=https://mercurial-scm.org/
AppUpdatesURL=https://mercurial-scm.org/
{{ 'AppID={{4B95A5F1-EF59-4B08-BED8-C891C46121B3}' }}
AppContact=mercurial@mercurial-scm.org
DefaultDirName={pf}\Mercurial
SourceDir=stage
VersionInfoDescription=Mercurial distributed SCM (version {#VERSION})
VersionInfoCopyright=Copyright 2005-2025 Olivia Mackall and others
VersionInfoCompany=Olivia Mackall and others
VersionInfoVersion={#QUAD_VERSION}
InternalCompressLevel=max
SolidCompression=true
SetupIconFile=../mercurial.ico
AllowNoIcons=true
DefaultGroupName=Mercurial
PrivilegesRequired=none
ChangesEnvironment=true

[Files]
{% for entry in package_files -%}
Source: {{ entry.source }}; DestDir: {{ entry.dest_dir }}
{%- if entry.metadata %}; {{ entry.metadata }}{% endif %}
{% endfor %}

[INI]
Filename: {app}\Mercurial.url; Section: InternetShortcut; Key: URL; String: https://mercurial-scm.org/

[UninstallDelete]
Type: files; Name: {app}\Mercurial.url
Type: filesandordirs; Name: {app}\defaultrc

[Icons]
Name: {group}\Uninstall Mercurial; Filename: {uninstallexe}
Name: {group}\Mercurial Command Reference; Filename: {app}\Docs\hg.1.html
Name: {group}\Mercurial Configuration Files; Filename: {app}\Docs\hgrc.5.html
Name: {group}\Mercurial Ignore Files; Filename: {app}\Docs\hgignore.5.html
Name: {group}\Mercurial Web Site; Filename: {app}\Mercurial.url

[Tasks]
Name: modifypath; Description: Add the installation path to the search path; Flags: unchecked

[Code]
procedure Touch(fn: String);
begin
  SaveStringToFile(ExpandConstant(fn), '', False);
end;

const
    ModPathName = 'modifypath';
    ModPathType = 'user';

function ModPathDir(): TArrayOfString;
begin
    setArrayLength(Result, 1)
    Result[0] := ExpandConstant('{app}');
end;

{% include 'modpath.iss' %}
