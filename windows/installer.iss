; Inno Setup script for the Windows installer. Called by windows/build.sh:
;
;   ISCC /DAppVersion=0.6.0 /DSourceDir=<app folder> /DOutputDir=<dist> /DIconFile=<icon.ico>
;        /DGpuInclude=<gpu.iss from gpu_wheels.py> installer.iss
;
; Installs for the current user only, into %LOCALAPPDATA%\Programs\Rip It Out, so no
; administrator rights are needed. Settings and the library are never touched: an
; uninstall leaves them in place.
;
; The app runs on the CPU. On a PC with an NVIDIA driver, Setup offers to download the
; CUDA build of the bundled PyTorch version from pytorch.org (checked against the
; SHA-256 found at build time) into %LOCALAPPDATA%\Rip It Out\gpu\<version>, where it
; stays across updates until PyTorch changes. The app uses it when it's there and
; works (desktop/main.js), and the CPU otherwise.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#include GpuInclude

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

[InstallDelete]
; A new version replaces the app whole, so no files of the old engine stay behind.
Type: filesandordirs; Name: "{app}\resources"
Type: filesandordirs; Name: "{app}\locales"

[Tasks]
Name: gpu; Description: "Download GPU acceleration for your NVIDIA graphics card ({#GpuMB} MB). Without it, songs are separated on the CPU, which takes longer."; Check: OfferGpu
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Rip It Out"; Filename: "{app}\Rip It Out.exe"
Name: "{autodesktop}\Rip It Out"; Filename: "{app}\Rip It Out.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Rip It Out.exe"; Description: "{cm:LaunchProgram,Rip It Out}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Rip It Out\gpu"

[Code]
var
  DownloadPage: TDownloadWizardPage;
  GpuDownloaded: Boolean;

function GpuRoot: String;
begin
  Result := ExpandConstant('{localappdata}\Rip It Out\gpu');
end;

function GpuDir: String;
begin
  Result := GpuRoot + '\{#GpuDir}';
end;

// The NVIDIA driver installs nvcuda.dll; without it CUDA can't run anyway.
function OfferGpu: Boolean;
begin
  Result := FileExists(ExpandConstant('{sys}\nvcuda.dll')) and not DirExists(GpuDir + '\torch');
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage('Downloading GPU acceleration', 'PyTorch for NVIDIA graphics cards, from pytorch.org', nil);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and WizardIsTaskSelected('gpu') then begin
    GpuDownloaded := False;
    DownloadPage.Clear;
    DownloadPage.Add('{#TorchUrl}', '{#TorchFile}', '{#TorchSha}');
    DownloadPage.Add('{#AudioUrl}', '{#AudioFile}', '{#AudioSha}');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
        GpuDownloaded := True;
      except
        if not DownloadPage.AbortedByUser then
          SuppressibleMsgBox('The GPU download failed: ' + GetExceptionMessage + #13#10#13#10 +
            'Rip It Out is installed anyway and uses the CPU. Run Setup again to retry.', mbInformation, MB_OK, IDOK);
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

// Removes GPU downloads for other PyTorch versions, which the app no longer uses.
procedure DropOldGpuDirs;
var
  Found: TFindRec;
begin
  if FindFirst(GpuRoot + '\*', Found) then begin
    try
      repeat
        if (Found.Name <> '.') and (Found.Name <> '..') and (Found.Name <> '{#GpuDir}') then
          DelTree(GpuRoot + '\' + Found.Name, True, True, True);
      until not FindNext(Found);
    finally
      FindClose(Found);
    end;
  end;
end;

procedure InstallGpu;
var
  Tmp, Args: String;
  Code: Integer;
begin
  Tmp := GpuDir + '.partial';
  DelTree(Tmp, True, True, True);
  WizardForm.StatusLabel.Caption := 'Installing GPU acceleration...';
  Args := '-I -m pip install --no-deps --no-index --disable-pip-version-check --no-input --target "' + Tmp + '" "' +
    ExpandConstant('{tmp}\{#TorchFile}') + '" "' + ExpandConstant('{tmp}\{#AudioFile}') + '"';
  if Exec(ExpandConstant('{app}\resources\python\python.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, Code)
     and (Code = 0) and RenameFile(Tmp, GpuDir) then
    Log('GPU acceleration installed in ' + GpuDir)
  else begin
    DelTree(Tmp, True, True, True);
    SuppressibleMsgBox('Installing GPU acceleration failed (code ' + IntToStr(Code) + '). ' +
      'Rip It Out uses the CPU. Run Setup again to retry.', mbInformation, MB_OK, IDOK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    DropOldGpuDirs;
    if GpuDownloaded then
      InstallGpu;
  end;
end;
