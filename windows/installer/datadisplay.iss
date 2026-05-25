; Inno Setup script for DataDisplay
; Builds DataDisplayWindows_setup.exe from a release Flutter build.
;
; Expected layout when ISCC is invoked:
;   <repo>/apps/flutter_app/build/windows/x64/runner/Release/
;       datadisplay_app.exe
;       dd_ffi.dll
;       flutter_windows.dll
;       data/
;
; Run: iscc /Qp datadisplay.iss
;   (paths are resolved relative to this .iss file)

#define MyAppName "DataDisplay"
#define MyAppPublisher "DataDisplay Project"
#define MyAppExeName "datadisplay_app.exe"
#define MyAppVersion "0.1.0"
#define SourceRoot "..\..\apps\flutter_app\build\windows\x64\runner\Release"
#define OutputRoot "..\..\dist"

[Setup]
AppId={{4E0D6F23-5C5B-4F2B-9F2E-7AE6C2A6E001}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputRoot}
OutputBaseFilename=DataDisplayWindows_setup
SetupIconFile=
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
UninstallDisplayName={#MyAppName} {#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceRoot}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
