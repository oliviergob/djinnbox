[Setup]
AppName=Djinnbox Dev Environment
#define AppVersion FileRead(FileOpen("VERSION"))
AppVersion={#AppVersion}
AppPublisher=Olivier Gobilliard
DefaultDirName={tmp}\djinnbox-setup
DisableDirPage=yes
OutputBaseFilename=djinnbox-setup
PrivilegesRequired=lowest
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
Uninstallable=no
CreateUninstallRegKey=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "install-scripts\*"; DestDir: "{tmp}\djinnbox-setup"; Flags: ignoreversion recursesubdirs createallsubdirs

[Run]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{tmp}\djinnbox-setup\install-wsl-debian.ps1"""; Description: "Set up WSL Debian and Djinnbox"; Flags: waituntilterminated

[Code]
procedure InitializeWizard;
var
  InfoPage: TOutputMsgMemoWizardPage;
begin
  InfoPage := CreateOutputMsgMemoPage(
    wpWelcome,
    'What Djinnbox sets up',
    'A persistent Linux coding environment on your Windows PC.',
    '',
    'After this setup you will have:' + #13#10 + #13#10 +
    '  - Linux (Debian) running in the background (via WSL)' + #13#10 +
    '  - A dev container that starts automatically at every login' + #13#10 +
    '  - Your projects folder shared between Windows and Linux' + #13#10 +
    '  - Claude Code and Codex pre-configured to use the container' + #13#10 +
    '  - SSH access on localhost:22022' + #13#10 + #13#10 +
    'The setup takes a few minutes and is safe to re-run.'
  );
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Lines: TArrayOfString;
  InfoText, SshCmd, SshKey: String;
  I, Y: Integer;
  Parent: TWinControl;
  CmdLabel, KeyLabel: TNewStaticText;
  CmdEdit, KeyEdit: TEdit;
begin
  if CurPageID = wpFinished then begin
    InfoText := '';
    if LoadStringsFromFile(ExpandConstant('{tmp}\djinnbox-setup\summary-info.txt'), Lines) then
      for I := 0 to GetArrayLength(Lines) - 1 do
        InfoText := InfoText + Lines[I] + #13#10;
    if InfoText = '' then
      InfoText := 'Setup complete.';

    SshCmd := '';
    if LoadStringsFromFile(ExpandConstant('{tmp}\djinnbox-setup\summary-ssh-cmd.txt'), Lines) then
      if GetArrayLength(Lines) > 0 then
        SshCmd := Trim(Lines[0]);

    SshKey := '';
    if LoadStringsFromFile(ExpandConstant('{tmp}\djinnbox-setup\summary-ssh-key.txt'), Lines) then
      if GetArrayLength(Lines) > 0 then
        SshKey := Trim(Lines[0]);

    Parent := WizardForm.FinishedLabel.Parent;
    WizardForm.FinishedLabel.AutoSize := True;
    WizardForm.FinishedLabel.Caption := InfoText;
    Y := WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height + 12;

    if SshCmd <> '' then begin
      CmdLabel := TNewStaticText.Create(WizardForm);
      CmdLabel.Parent := Parent;
      CmdLabel.Left := WizardForm.FinishedLabel.Left;
      CmdLabel.Top := Y;
      CmdLabel.Caption := 'SSH:';
      CmdLabel.AutoSize := True;
      Y := Y + CmdLabel.Height + 4;

      CmdEdit := TEdit.Create(WizardForm);
      CmdEdit.Parent := Parent;
      CmdEdit.Left := WizardForm.FinishedLabel.Left;
      CmdEdit.Top := Y;
      CmdEdit.Width := WizardForm.FinishedLabel.Width;
      CmdEdit.ReadOnly := True;
      CmdEdit.Text := SshCmd;
      Y := Y + CmdEdit.Height + 12;
    end;

    if SshKey <> '' then begin
      KeyLabel := TNewStaticText.Create(WizardForm);
      KeyLabel.Parent := Parent;
      KeyLabel.Left := WizardForm.FinishedLabel.Left;
      KeyLabel.Top := Y;
      KeyLabel.Caption := 'GitHub SSH key (add to https://github.com/settings/keys):';
      KeyLabel.AutoSize := True;
      Y := Y + KeyLabel.Height + 4;

      KeyEdit := TEdit.Create(WizardForm);
      KeyEdit.Parent := Parent;
      KeyEdit.Left := WizardForm.FinishedLabel.Left;
      KeyEdit.Top := Y;
      KeyEdit.Width := WizardForm.FinishedLabel.Width;
      KeyEdit.ReadOnly := True;
      KeyEdit.Text := SshKey;
    end;
  end;
end;
