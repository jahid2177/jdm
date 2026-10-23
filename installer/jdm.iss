; Jahid Download Manager per-user Windows x64 installer.
; Compile after flutter build windows and native-host packaging finish.
[Setup]
AppId={{8DE16018-3135-4712-9A36-7AAF5E83E410}
AppName=Jahid Download Manager
AppVersion=1.2.0
AppVerName=Jahid Download Manager 1.2.0
VersionInfoVersion=1.2.0
AppPublisher=Md Jahidul Islam
SetupIconFile=..\assets\tray_icon.ico
DefaultDirName={localappdata}\Programs\Jahid Download Manager
DefaultGroupName=Jahid Download Manager
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\jahid_download_manager.exe
OutputDir=..\build\installer
OutputBaseFilename=JDM-Setup-v1.2.0-Windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "BROWSER_SETUP.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Jahid Download Manager"; Filename: "{app}\jahid_download_manager.exe"
Name: "{autodesktop}\Jahid Download Manager"; Filename: "{app}\jahid_download_manager.exe"; Tasks: desktopicon
Name: "{group}\Browser integration setup"; Filename: "{sys}\notepad.exe"; Parameters: """{app}\BROWSER_SETUP.txt"""

[Run]
Filename: "{app}\jahid_download_manager.exe"; Description: "Launch Jahid Download Manager"; Flags: nowait postinstall skipifsilent
Filename: "{sys}\notepad.exe"; Parameters: """{app}\BROWSER_SETUP.txt"""; Description: "Read browser integration setup guide"; Flags: nowait postinstall skipifsilent unchecked
