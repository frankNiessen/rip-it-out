; Inno Setup script for the Windows installer. Called by windows/build.sh:
;
;   ISCC /DAppVersion=0.6.0 /DSourceDir=<app folder> /DOutputDir=<dist> /DIconFile=<icon.ico> installer.iss
;
; Installs for the current user only, into %LOCALAPPDATA%\Programs\Rip It Out, so no
; administrator rights are needed. Settings and the library are never touched: an
; uninstall leaves them in place.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F3A2C1E-8B4D-4F7A-9E2C-5D1B7A0C3E84}
AppName=Rip It Out
AppVersion={#AppVersion}
AppVerName=Rip It Out {#AppVersion}
AppPublisher=Frank Niessen
AppPublisherURL=https://github.com/frankNiessen/rip-it-out
AppSupportURL=https://github.com/frankNiessen/rip-it-out/issues
AppUpdatesURL=https://github.com/frankNiessen/rip-it-out/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Rip It Out
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=RipItOut-Setup-{#AppVersion}
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\Rip It Out.exe
UninstallDisplayName=Rip It Out
WizardStyle=modern
CloseApplications=yes
Compression=lzma2/normal
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4
; The PyTorch GPU libraries make the app several GB. Slices stay under GitHub's 2 GB
; limit for release files; Setup finds them in its own folder.
DiskSpanning=yes
DiskSliceSize=2000000000

[InstallDelete]
; A new version replaces the app whole, so no files of the old engine stay behind.
Type: filesandordirs; Name: "{app}\resources"
Type: filesandordirs; Name: "{app}\locales"

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Rip It Out"; Filename: "{app}\Rip It Out.exe"
Name: "{autodesktop}\Rip It Out"; Filename: "{app}\Rip It Out.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Rip It Out.exe"; Description: "{cm:LaunchProgram,Rip It Out}"; Flags: nowait postinstall skipifsilent
