const vscode = require('vscode');
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const STYLES = [
  'BalladPiano', 'DelicateBells', 'DeluxeModern', 'ElectromagneticKeys',
  'FlyingCircusPiano', 'GuitarVsClav', 'LuminousTines', 'MoreModulationPiano',
  'NeonDreamsSynth', 'OceanAndSpaceLead', 'OpenTheBottle', 'ScarletSynthChimes',
  'ShimmeringGlass', 'Soft70sLead', 'SongthrushChime', 'SpacedOutSynth',
  'SweetBells', 'TapedMarimba', 'Vibraphone', 'WoodenKeys'
];

const STATE_FILE = path.join(os.homedir(), '.cursor', 'nerdflair-chimes.json');

let currentStyle = '';
let audioDir = '';
let statusBarItem;

function getConfig() {
  return vscode.workspace.getConfiguration('nerdflair-chimes');
}

function resolveAudioDir() {
  const configured = getConfig().get('audioDirectory');
  if (configured && fs.existsSync(configured)) return configured;

  const candidates = [];
  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (workspaceFolders) {
    for (const folder of workspaceFolders) {
      candidates.push(path.join(folder.uri.fsPath, 'assets', 'audio'));
    }
  }
  candidates.push(path.join(os.homedir(), '.claude', 'plugins', 'jcraigk-nerdflair', 'assets', 'audio'));

  for (const dir of candidates) {
    if (fs.existsSync(dir)) return dir;
  }
  return '';
}

function writeState() {
  if (!audioDir) return;
  // Clamp: a hand-edited setting above 1 or below 0 must not reach afplay/paplay.
  const volume = Math.min(1, Math.max(0, Number(getConfig().get('volume', 1.0)) || 0));
  const state = { style: currentStyle, volume, audioDir };
  try {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n');
  } catch (e) {
    // Non-fatal
  }
}

function playChime(event) {
  const volume = getConfig().get('volume', 1.0);
  if (volume <= 0 || !audioDir) return;

  const audioFile = path.join(audioDir, currentStyle, `${currentStyle}-${event}.mp3`);
  if (!fs.existsSync(audioFile)) return;

  if (process.platform === 'darwin') {
    execFile('afplay', ['--volume', String(volume), audioFile], () => {});
  } else {
    const paVolume = Math.round(volume * 65536);
    execFile('paplay', [`--volume=${paVolume}`, audioFile], () => {});
  }
}

function updateStatusBar() {
  if (!statusBarItem) return;
  if (audioDir) {
    statusBarItem.text = `$(unmute) ${currentStyle}`;
    statusBarItem.tooltip = 'NerdFlair Chimes — click to cycle style';
  } else {
    statusBarItem.text = `$(mute) NerdFlair`;
    statusBarItem.tooltip = 'NerdFlair Chimes — audio directory not configured';
  }
}

function cycleStyle() {
  if (!audioDir) return;
  const idx = STYLES.indexOf(currentStyle);
  currentStyle = STYLES[(idx + 1) % STYLES.length];
  writeState();
  updateStatusBar();
  playChime('SessionStart');
}

function activate(context) {
  currentStyle = STYLES[Math.floor(Math.random() * STYLES.length)];
  audioDir = resolveAudioDir();

  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 0);
  statusBarItem.command = 'nerdflair-chimes.cycleStyle';
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  if (audioDir) {
    writeState();
  }
  updateStatusBar();

  context.subscriptions.push(
    vscode.commands.registerCommand('nerdflair-chimes.playStop', () => playChime('Stop')),
    vscode.commands.registerCommand('nerdflair-chimes.cycleStyle', cycleStyle),
    vscode.commands.registerCommand('nerdflair-chimes.showStyle', () => {
      vscode.window.showInformationMessage(`NerdFlair Chimes: ${audioDir ? currentStyle : 'not configured'}`);
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(e => {
      if (e.affectsConfiguration('nerdflair-chimes')) {
        const newAudioDir = resolveAudioDir();
        audioDir = newAudioDir;  // also clears a stale dir when the setting is unset
        writeState();
        updateStatusBar();
      }
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
