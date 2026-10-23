; Jahid Download Manager per-user Windows x64 installer.
; Compile after flutter build windows and native-host packaging finish.
[Setup]
AppId={{8DE16018-3135-4712-9A36-7AAF5E83E410}
AppName=Jahid Download Manager
AppVersion=2.0.0
AppVerName=Jahid Download Manager 2.0.0
VersionInfoVersion=2.0.0
AppPublisher=Md Jahidul Islam
SetupIconFile=..\assets\tray_icon.ico
DefaultDirName={localappdata}\Programs\Jahid Download Manager
DefaultGroupName=Jahid Download Manager
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\jahid_download_manager.exe
OutputDir=..\build\installer
OutputBaseFilename=JDM-Setup-v2.0.0-Windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "browserintegration"; Description: "Open guided Chrome / Edge integration setup after installation"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "BROWSER_SETUP.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Jahid Download Manager"; Filename: "{app}\jahid_download_manager.exe"
Name: "{group}\Set up Chrome and Edge integration"; Filename: "{app}\jahid_download_manager.exe"; Parameters: "--browser-setup"
Name: "{autodesktop}\Jahid Download Manager"; Filename: "{app}\jahid_download_manager.exe"; Tasks: desktopicon
Name: "{group}\Browser integration setup"; Filename: "{sys}\notepad.exe"; Parameters: """{app}\BROWSER_SETUP.txt"""

[Run]
Filename: "{app}\jahid_download_manager.exe"; Parameters: "{code:BrowserSetupArgs}"; Description: "Launch Jahid Download Manager"; Flags: nowait postinstall skipifsilent
Filename: "{sys}\notepad.exe"; Parameters: """{app}\BROWSER_SETUP.txt"""; Description: "Read browser integration setup guide"; Flags: nowait postinstall skipifsilent unchecked

[Code]
function BrowserSetupArgs(Param: String): String;
begin
  if WizardIsTaskSelected('browserintegration') then
    Result := '--browser-setup'
  else
    Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Google\Chrome\NativeMessagingHosts\com.jahidul.jdm');
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Microsoft\Edge\NativeMessagingHosts\com.jahidul.jdm');
    DeleteFile(ExpandConstant('{localappdata}\JahidDownloadManager\NativeMessaging\chrome-host.json'));
    DeleteFile(ExpandConstant('{localappdata}\JahidDownloadManager\NativeMessaging\edge-host.json'));
  end;
end;
