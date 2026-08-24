#define MyAppName "filmstoryboard"
#define MyAppVersion "1.0.0.347"
#define MyAppPublisher "Jiang"
#define MyAppExeName "filmstoryboard.exe"

[Setup]
AppId={{EAD11C88-C57C-4E8E-A5AB-A5F75D05B9CE}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName=D:\Program Files\{#MyAppName}
DirExistsWarning=no
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
Source: "..\build\windows\x64\runner\Release\data\dwpose\models\*.onnx"; DestDir: "{app}\data\dwpose\models"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\ffmpeg\bin\*.exe"; DestDir: "{app}\ffmpeg\bin"; Flags: ignoreversion
Source: "..\website\app\build\web\*"; DestDir: "{app}\web"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\resolve_plugin\com.filmstoryboard.timelinebridge\*"; DestDir: "{app}\data\resolve_plugin\com.filmstoryboard.timelinebridge"; Excludes: "WorkflowIntegration.node"; Flags: ignoreversion
Source: "..\resolve_plugin\windows\Install-FilmStoryboardResolvePlugin.ps1"; DestDir: "{app}\data\resolve_plugin\windows"; Flags: ignoreversion
Source: "..\resolve_plugin\windows\Uninstall-FilmStoryboardResolvePlugin.ps1"; DestDir: "{app}\data\resolve_plugin\windows"; Flags: ignoreversion

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

[Code]
var
  ResolvePluginPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin
  ResolvePluginPage := CreateInputOptionPage(
    wpSelectTasks,
    'DaVinci Resolve 插件',
    '是否安装达芬奇插件？',
    '无论当前是否安装，插件包都会保存在软件 data 文件夹中，之后可在“设置 → 插件”随时补安装。',
    True,
    True);
  ResolvePluginPage.Add('安装达芬奇插件（推荐）');
  ResolvePluginPage.Add('暂不安装');
  ResolvePluginPage.SelectedValueIndex := 0;
end;

function RunResolvePluginScript(const ScriptFileName, ExtraParameters: String;
  var ResultCode: Integer): Boolean;
var
  PowerShellPath: String;
  ScriptPath: String;
  Parameters: String;
begin
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant(
    '{app}\data\resolve_plugin\windows\' + ScriptFileName);
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ScriptPath + '" ' + ExtraParameters;
  Log('运行 Resolve 插件部署脚本：' + ScriptPath);
  Result := Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PluginSource: String;
  InstallScriptPath: String;
  ErrorLogPath: String;
  ErrorLines: TArrayOfString;
  ErrorDetail: String;
  ErrorMessage: String;
  I: Integer;
begin
  if CurStep <> ssPostInstall then
    exit;

  if ResolvePluginPage.SelectedValueIndex <> 0 then
  begin
    Log('用户选择暂不安装 DaVinci Resolve 插件；插件包已保留在 data 文件夹。');
    exit;
  end;

  ResultCode := -1;
  PluginSource := ExpandConstant(
    '{app}\data\resolve_plugin\com.filmstoryboard.timelinebridge');
  InstallScriptPath := ExpandConstant(
    '{app}\data\resolve_plugin\windows\Install-FilmStoryboardResolvePlugin.ps1');
  ErrorLogPath := ExpandConstant('{tmp}\filmstoryboard-resolve-plugin-install-error.log');
  DeleteFile(ErrorLogPath);
  if (not RunResolvePluginScript(
      'Install-FilmStoryboardResolvePlugin.ps1',
      '-PluginSource "' + PluginSource + '" -ErrorLogPath "' + ErrorLogPath + '"', ResultCode)) or
     (ResultCode <> 0) then
  begin
    ErrorMessage := Format(
      'FilmStoryboard 主程序已安装，但 DaVinci Resolve 流程整合插件安装失败（退出码 %d）。' + #13#10 +
      '请查看下方实际错误，或手动运行：' + #13#10 +
      '%s', [ResultCode, InstallScriptPath]);
    if LoadStringsFromFile(ErrorLogPath, ErrorLines) then
    begin
      ErrorDetail := '';
      for I := 0 to GetArrayLength(ErrorLines) - 1 do
      begin
        if ErrorDetail <> '' then
          ErrorDetail := ErrorDetail + #13#10;
        ErrorDetail := ErrorDetail + ErrorLines[I];
      end;
      if ErrorDetail <> '' then
        ErrorMessage := ErrorMessage + #13#10 + #13#10 +
          '实际错误：' + #13#10 + Copy(ErrorDetail, 1, 2000);
    end;
    Log(ErrorMessage);
    if not WizardSilent then
      MsgBox(ErrorMessage, mbError, MB_OK);
  end;
  DeleteFile(ErrorLogPath);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  PluginDestination: String;
  ErrorMessage: String;
begin
  if CurUninstallStep <> usUninstall then
    exit;

  ResultCode := -1;
  PluginDestination := ExpandConstant(
    '{commonappdata}\Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins\com.filmstoryboard.timelinebridge');
  if (not RunResolvePluginScript(
      'Uninstall-FilmStoryboardResolvePlugin.ps1', '', ResultCode)) or
     (ResultCode <> 0) then
  begin
    ErrorMessage := Format(
      'DaVinci Resolve 插件自动卸载失败（退出码 %d）。请关闭 Resolve 后手动删除：' + #13#10 +
      '%s', [ResultCode, PluginDestination]);
    Log(ErrorMessage);
    if not UninstallSilent then
      MsgBox(ErrorMessage, mbError, MB_OK);
  end;
end;
