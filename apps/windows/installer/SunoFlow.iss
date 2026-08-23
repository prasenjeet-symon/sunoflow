; SunoFlow Windows installer (Inno Setup 6).
;
; Builds a single per-user setup .exe: no admin rights, no UAC prompt, nothing
; written outside the user's profile. That is not a shortcut — it is what the
; app already assumes. SidecarSupervisor looks for the sidecar under
; %LOCALAPPDATA%\SunoFlow, AutoStart writes HKCU\...\Run, and preferences, logs
; and the model all live in the same per-user tree. A machine-wide MSI would
; ask for rights the app never needs and would break the sidecar path contract.
;
; Compile (the release workflow does this for you):
;   ISCC.exe /DMyAppVersion=1.2.3 SunoFlow.iss
;
; It expects the two build outputs staged next to this file:
;   stage\app\      ← dotnet publish output (self-contained SunoFlow.exe + runtime)
;   stage\sidecar\  ← PyInstaller one-folder bundle (SunoFlowSidecar.exe + DLLs)

#define MyAppName "SunoFlow"
#define MyAppPublisher "SunoFlow"
#define MyAppURL "https://sunoflow-app.web.app"
#define MyAppExeName "SunoFlow.exe"

; Overridden by /DMyAppVersion= on the command line; the default only exists so
; a local test compile works.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif
; The file-properties version must be plain numeric, which a tag like
; v1.0.0-beta is not — the workflow passes the numeric part separately.
#ifndef MyAppVersionNumeric
  #define MyAppVersionNumeric "0.0.0"
#endif

[Setup]
; Never change AppId — it is how Windows recognises an upgrade of this app
; rather than a second copy of it.
AppId={{7C3E9A14-5B62-4D08-9F31-2A6E4C8D1B57}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
VersionInfoVersion={#MyAppVersionNumeric}
VersionInfoTextVersion={#MyAppVersion}

; Per-user install: lowest privileges, and everything under %LOCALAPPDATA%.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\SunoFlow\app
; The directory page is disabled deliberately. The sidecar path the app
; resolves is fixed (%LOCALAPPDATA%\SunoFlow\sidecar\...), so letting someone
; install the app elsewhere would only produce a half-working layout.
DisableDirPage=yes
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}

ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

; If the tray app is running, ask the user to close it rather than failing to
; replace a locked exe. This is the same mutex SingleInstance.cs creates, and
; the doubled brace is Inno's escape for a literal "{".
AppMutex=SunoFlow-{{A8F3C2E1-1B2D-4E5F-9A6C-7D8E9F0A1B2C}

OutputDir=output
OutputBaseFilename=SunoFlow-Setup-{#MyAppVersion}
SetupIconFile=..\SunoFlow\Assets\app-icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked
; Writes exactly the value AutoStart.cs reads, so the Settings toggle reflects
; this choice instead of disagreeing with it.
Name: "startatlogin"; Description: "Start {#MyAppName} when I sign in"

[Files]
Source: "stage\app\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs
; The sidecar does NOT go under {app}: SidecarSupervisor resolves it at a fixed
; path, and keeping it there means an app upgrade never disturbs it.
Source: "stage\sidecar\*"; DestDir: "{localappdata}\SunoFlow\sidecar\SunoFlowSidecar"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "SunoFlow"; ValueData: """{app}\{#MyAppExeName}"""; \
  Flags: uninsdeletevalue; Tasks: startatlogin

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Program files, not user data — these always go.
Type: filesandordirs; Name: "{localappdata}\SunoFlow\sidecar"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  // The tray app leaves the sidecar running when it quits (by design — it is an
  // independent service and restarting the tray app must not force a model
  // reload). On an upgrade that means SunoFlowSidecar.exe is holding the very
  // files we are about to replace, so stop it first. A missing process is not
  // an error worth reporting.
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM SunoFlowSidecar.exe /F',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    // Same reason as above: the sidecar outlives the tray app, so it may well
    // be running while its folder is being removed.
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM SunoFlowSidecar.exe /F',
         '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    // The auto-start entry may have been set from the app's own Settings toggle
    // rather than the installer task, in which case uninsdeletevalue would not
    // catch it and Windows would keep launching a deleted exe at every login.
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', 'SunoFlow');

    // The model is ~2.5 GB and slow to fetch, and the dictionary is the user's
    // own accumulated corrections. Keeping them by default makes a reinstall
    // cheap; deleting is opt-in.
    DataDir := ExpandConstant('{localappdata}\SunoFlow');
    if DirExists(DataDir) then
    begin
      if MsgBox('Also delete the downloaded speech model, your dictionary and settings?'
                + #13#10#13#10
                + 'The model is about 2.5 GB and would have to be downloaded again.'
                + ' Choose No to keep them for a future reinstall.',
                mbConfirmation, MB_YESNO) = IDYES then
        DelTree(DataDir, True, True, True);
    end;
  end;
end;
