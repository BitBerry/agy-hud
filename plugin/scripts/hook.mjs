#!/usr/bin/env node
/**
 * Fast passive lifecycle hook for agy-hud.
 * - Never gates tools or alters agent behavior.
 * - Never stores ANTIGRAVITY_CSRF_TOKEN on disk.
 * - Always writes valid JSON to stdout and exits 0.
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Antigravity desktop and the agy CLI load this same plugin but hand it different
// PLUGIN_DATA dirs (~/.gemini/antigravity/... vs ~/.gemini/antigravity-cli/...).
// AgyHUD.app, its socket, prefs and quota cache live in exactly one place, so
// everything that talks to the app uses HUD_HOME; only the per-host
// runtime-state.json stays in PLUGIN_DATA.
const HUD_HOME =
  process.env.AGY_HUD_HOME ||
  path.join(os.homedir(), '.gemini', 'antigravity', 'plugin_data', 'agy-hud');

function resolveDataDir() {
  return process.env.PLUGIN_DATA || HUD_HOME;
}

function detectSource(dataDir, transcriptPath) {
  const marker = `${path.sep}antigravity-cli${path.sep}`;
  return dataDir.includes(marker) || transcriptPath.includes(marker) ? 'cli' : 'desktop';
}

function parseTmuxSocket(rawTmux) {
  const value = String(rawTmux || '').trim();
  if (!value) return '';
  const parts = value.split(',');
  const socketPath = parts.length >= 3 ? parts.slice(0, -2).join(',') : parts[0];
  if (!socketPath) return '';
  try {
    return fs.realpathSync(socketPath);
  } catch {
    return socketPath;
  }
}

function readStdinSync() {
  try {
    return fs.readFileSync(0, 'utf-8');
  } catch {
    return '';
  }
}

function safeReadJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  } catch {
    return null;
  }
}

function writeAtomic0600(filePath, dataObj) {
  const tmpPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(dataObj, null, 2), { mode: 0o600 });
  try {
    fs.chmodSync(tmpPath, 0o600);
  } catch {
    // ignore
  }
  fs.renameSync(tmpPath, filePath);
}

function sendSocketIPC(sockPath, payload) {
  return new Promise((resolve) => {
    if (!fs.existsSync(sockPath)) {
      resolve(false);
      return;
    }
    let settled = false;
    const finish = (ok) => {
      if (!settled) {
        settled = true;
        resolve(ok);
      }
    };
    const timer = setTimeout(() => {
      try {
        client.destroy();
      } catch {
        // ignore
      }
      finish(false);
    }, 120);

    const client = net.createConnection({ path: sockPath }, () => {
      try {
        client.end(`${JSON.stringify(payload)}\n`, () => {
          clearTimeout(timer);
          finish(true);
        });
      } catch {
        clearTimeout(timer);
        finish(false);
      }
    });
    client.on('error', () => {
      clearTimeout(timer);
      finish(false);
    });
  });
}

function maybeLaunchApp() {
  try {
    const prefs = safeReadJson(path.join(HUD_HOME, 'prefs.json'));
    if (!prefs || prefs.autoLaunch !== true) return;

    const appPath = [
      '/Applications/AgyHUD.app',
      path.join(HUD_HOME, 'AgyHUD.app'),
    ].find((candidate) => fs.existsSync(candidate));
    if (!appPath) return;

    const stampPath = path.join(HUD_HOME, '.last-launch');
    const now = Date.now();
    try {
      const prev = Number(fs.readFileSync(stampPath, 'utf-8').trim());
      if (Number.isFinite(prev) && now - prev < 15000) return;
    } catch {
      // no previous stamp
    }

    fs.writeFileSync(stampPath, String(now), { mode: 0o600 });
    const child = spawn('open', ['-g', '-a', appPath], {
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
  } catch {
    // ignore
  }
}

function maybeSpawnQuotaRefresh(eventName, socketOk) {
  try {
    const lsAddress = process.env.ANTIGRAVITY_LS_ADDRESS || '';
    const csrfToken = process.env.ANTIGRAVITY_CSRF_TOKEN || '';
    if (!lsAddress || !csrfToken) return;

    const quotaPath = path.join(HUD_HOME, 'quota.json');
    let ageMs = Infinity;
    try {
      const st = fs.statSync(quotaPath);
      ageMs = Date.now() - st.mtimeMs;
    } catch {
      ageMs = Infinity;
    }

    const shouldRefresh =
      (!socketOk && (eventName === 'SessionStart' || eventName === 'Stop' || ageMs > 45000)) ||
      (socketOk && (eventName === 'SessionStart' || eventName === 'Stop') && ageMs > 20000);

    if (!shouldRefresh) return;

    const scriptPath = path.join(__dirname, 'quota-refresh.mjs');
    if (!fs.existsSync(scriptPath)) return;

    const child = spawn(process.execPath, [scriptPath], {
      detached: true,
      stdio: 'ignore',
      env: {
        ...process.env,
        AGY_HUD_DATA_DIR: HUD_HOME,
      },
    });
    child.unref();
  } catch {
    // ignore
  }
}

async function main() {
  let hookEventName = '';
  try {
    const rawStdin = readStdinSync();
    const input = rawStdin.trim() ? JSON.parse(rawStdin) : {};
    hookEventName = String(input?.hookEventName || '');

    const nowMs = Date.now();
    const dataDir = resolveDataDir();
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.mkdirSync(HUD_HOME, { recursive: true, mode: 0o700 });

    const conversationId = String(input?.conversationId || '');
    const transcriptPath = String(input?.transcriptPath || '');
    const modelName = String(input?.modelName || '');
    const invocationNum =
      typeof input?.invocationNum === 'number' ? input.invocationNum : null;
    const initialNumSteps =
      typeof input?.initialNumSteps === 'number' ? input.initialNumSteps : null;
    const terminationReason = input?.terminationReason
      ? String(input.terminationReason)
      : null;

    // Update sanitized runtime-state.json (NEVER persist CSRF token!)
    const autoCompactOverride = String(
      process.env.AGY_CLI_AUTO_COMPACT_OVERRIDE || ''
    ).trim();
    const tmuxSocket = parseTmuxSocket(process.env.TMUX);
    const tmuxPane = String(process.env.TMUX_PANE || '').trim();
    const statePath = path.join(dataDir, 'runtime-state.json');
    const prevState = safeReadJson(statePath) || {};
    const timings =
      prevState.timings && typeof prevState.timings === 'object'
        ? { ...prevState.timings }
        : {};
    const autoCompactOverrides =
      prevState.autoCompactOverrides &&
      typeof prevState.autoCompactOverrides === 'object'
        ? { ...prevState.autoCompactOverrides }
        : {};
    const tmuxPanes =
      prevState.tmuxPanes && typeof prevState.tmuxPanes === 'object'
        ? { ...prevState.tmuxPanes }
        : {};
    if (conversationId) {
      autoCompactOverrides[conversationId] = autoCompactOverride;
      if (tmuxSocket && tmuxPane) {
        tmuxPanes[`${tmuxSocket}|${tmuxPane}`] = conversationId;
      }
    }

    if (conversationId) {
      const list = Array.isArray(timings[conversationId])
        ? [...timings[conversationId]]
        : [];
      if (hookEventName === 'PreInvocation') {
        list.push({
          invocationNum,
          initialNumSteps,
          preInvocationMs: nowMs,
          postInvocationMs: null,
          stopMs: null,
          modelName,
        });
      } else if (hookEventName === 'PostInvocation') {
        for (let i = list.length - 1; i >= 0; i--) {
          if (
            list[i].invocationNum === invocationNum ||
            list[i].postInvocationMs === null
          ) {
            list[i] = { ...list[i], postInvocationMs: nowMs };
            break;
          }
        }
      } else if (hookEventName === 'Stop') {
        for (let i = list.length - 1; i >= 0; i--) {
          if (list[i].stopMs === null) {
            list[i] = { ...list[i], stopMs: nowMs };
            break;
          }
        }
      }
      timings[conversationId] = list.slice(-40);
    }

    // Keep at most 16 most recent conversation timing histories
    const convKeys = Object.keys(timings);
    if (convKeys.length > 16) {
      for (const k of convKeys.slice(0, convKeys.length - 16)) {
        delete timings[k];
      }
    }
    const overrideKeys = Object.keys(autoCompactOverrides);
    if (overrideKeys.length > 16) {
      for (const k of overrideKeys.slice(0, overrideKeys.length - 16)) {
        delete autoCompactOverrides[k];
      }
    }
    const tmuxPaneKeys = Object.keys(tmuxPanes);
    if (tmuxPaneKeys.length > 24) {
      for (const k of tmuxPaneKeys.slice(0, tmuxPaneKeys.length - 24)) {
        delete tmuxPanes[k];
      }
    }

    const nextState = {
      activeConversationId: conversationId || prevState.activeConversationId || '',
      activeTranscriptPath: transcriptPath || prevState.activeTranscriptPath || '',
      activeModelName: modelName || prevState.activeModelName || '',
      activeAutoCompactOverride: autoCompactOverride,
      lastEvent: hookEventName,
      lastEventMs: nowMs,
      isGenerating:
        hookEventName === 'PreInvocation'
          ? true
          : hookEventName === 'Stop' || hookEventName === 'SessionStart'
            ? false
            : Boolean(prevState.isGenerating),
      lsAddress: process.env.ANTIGRAVITY_LS_ADDRESS || prevState.lsAddress || '',
      timings,
      autoCompactOverrides,
      tmuxPanes,
    };

    writeAtomic0600(statePath, nextState);

    // Send IPC message (includes in-memory CSRF token ONLY over 0600 Unix socket)
    const sockPath = path.join(HUD_HOME, 'hud.sock');
    const ipcPayload = {
      event: hookEventName,
      tsMs: nowMs,
      source: detectSource(dataDir, transcriptPath),
      agentPid: process.ppid,
      autoCompactOverride,
      tmuxSocket,
      tmuxPane,
      conversationId,
      transcriptPath,
      modelName,
      invocationNum,
      initialNumSteps,
      terminationReason,
      lsAddress: process.env.ANTIGRAVITY_LS_ADDRESS || '',
      csrfToken: process.env.ANTIGRAVITY_CSRF_TOKEN || '',
    };

    const socketOk = await sendSocketIPC(sockPath, ipcPayload);
    if (!socketOk) {
      maybeLaunchApp();
    }
    maybeSpawnQuotaRefresh(hookEventName, socketOk);
  } catch {
    // Always stay non-blocking
  }

  if (hookEventName === 'Stop') {
    process.stdout.write('{"decision":"allow"}');
  } else {
    process.stdout.write('{}');
  }
}

main().catch(() => {
  process.stdout.write('{}');
});
