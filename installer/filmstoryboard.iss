#define MyAppName "filmstoryboard"
#define MyAppVersion "1.0.0.157"
#define MyAppPublisher "Jiang"
#define MyAppExeName "filmstoryboard.exe"

[Setup]
AppId={{EAD11C88-C57C-4E8E-A5AB-A5F75D05B9CE}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName=D:\Program Files\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=filmstoryboard-Setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\data\app.so"; DestDir: "{app}\data"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\data\icudtl.dat"; DestDir: "{app}\data"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\data\flutter_assets\*"; DestDir: "{app}\data\flutter_assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\build\windows\x64\runner\Release\ffmpeg\bin\*.exe"; DestDir: "{app}\ffmpeg\bin"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\.storyboard"; ValueType: string; ValueName: ""; ValueData: "filmstoryboard.Project"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\filmstoryboard.Project"; ValueType: string; ValueName: ""; ValueData: "故事板工程"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\filmstoryboard.Project\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\filmstoryboard.Project\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
