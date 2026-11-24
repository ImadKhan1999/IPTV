; Inno Setup script for the Windows installer (built in CI).
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{DFC575B2-3DCB-443F-BD72-8B0490721549}
AppName=iPTV
AppVersion={#AppVersion}
AppPublisher=ImadLabs
AppPublisherURL=https://github.com/ImadKhan1999/IPTV
DefaultDirName={localappdata}\Programs\iPTV
DefaultGroupName=iPTV
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=iPTV-Setup-{#AppVersion}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\iptv.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\iPTV"; Filename: "{app}\iptv.exe"
Name: "{autodesktop}\iPTV"; Filename: "{app}\iptv.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\iptv.exe"; Description: "{cm:LaunchProgram,iPTV}"; Flags: nowait postinstall skipifsilent
