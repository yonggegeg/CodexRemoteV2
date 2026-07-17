const os = require('os');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const RELAY_URL = (process.env.RELAY_URL || 'http://115.159.221.170:8081').replace(/\/$/, '');
const AGENT_TOKEN = process.env.AGENT_TOKEN || 'change-me-agent-token';
const AGENT_ID = process.env.AGENT_ID || `${os.hostname()}-codex-agent-v2`;
const CAPTURE_INTERVAL_MS = Number(process.env.CAPTURE_INTERVAL_MS || 1200);
const LIST_INTERVAL_MS = Number(process.env.LIST_INTERVAL_MS || 3000);

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function api(path, options = {}) {
  const res = await fetch(RELAY_URL + path, {
    ...options,
    headers: {
      'Authorization': `Bearer ${AGENT_TOKEN}`,
      'X-Agent-Id': AGENT_ID,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      ...(options.headers || {})
    }
  });
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; } catch { data = { ok: false, error: text }; }
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function runPowerShell(args, timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `${__dirname}\\capture-window.ps1`, ...args], {
      windowsHide: true,
      shell: false
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('powershell timeout'));
    }, timeoutMs);
    child.stdout.on('data', d => stdout += d.toString());
    child.stderr.on('data', d => stderr += d.toString());
    child.on('error', err => { clearTimeout(timer); reject(err); });
    child.on('close', code => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(stderr || stdout || `powershell exit ${code}`));
      try { resolve(JSON.parse(stdout)); }
      catch (e) { reject(new Error(`invalid JSON from powershell: ${stdout.slice(0, 200)}`)); }
    });
  });
}

async function listWindows() {
  const result = await runPowerShell(['-Mode', 'list'], 20000);
  return Array.isArray(result) ? result : [];
}

async function capture(hwnd) {
  if (!hwnd) return null;
  return await runPowerShell(['-Mode', 'capture', '-Hwnd', String(hwnd), '-Quality', '55', '-MaxWidth', '900'], 20000);
}


async function fetchPendingMessages() {
  const data = await api('/agent/messages/next');
  return data.messages || [];
}

function saveInboundMessages(messages) {
  if (!messages.length) return;
  const dir = path.join(__dirname, 'inbound-messages');
  fs.mkdirSync(dir, { recursive: true });
  for (const msg of messages) {
    const msgDir = path.join(dir, msg.id);
    fs.mkdirSync(msgDir, { recursive: true });
    fs.writeFileSync(path.join(msgDir, 'message.json'), JSON.stringify({ ...msg, attachments: (msg.attachments || []).map(a => ({ ...a, dataBase64: undefined })) }, null, 2), 'utf8');
    for (const a of msg.attachments || []) {
      if (!a.dataBase64) continue;
      const safeName = (a.fileName || `${a.id}.jpg`).replace(/[<>:"/\\|?*]/g, '_');
      fs.writeFileSync(path.join(msgDir, safeName), Buffer.from(a.dataBase64, 'base64'));
    }
    console.log(`[message] received ${msg.id}: ${msg.text || ''} (${(msg.attachments || []).length} attachment(s))`);
  }
}

async function heartbeat(payload) {
  await api('/agent/heartbeat', {
    method: 'POST',
    body: JSON.stringify({
      host: os.hostname(),
      version: 'v2.0.0',
      ...payload
    })
  });
}

async function main() {
  console.log('Codex Remote Windows Agent v2 started');
  console.log(`Relay: ${RELAY_URL}`);
  console.log(`Agent: ${AGENT_ID}`);

  let windows = [];
  let lastList = 0;

  while (true) {
    try {
      const now = Date.now();
      if (now - lastList > LIST_INTERVAL_MS) {
        windows = await listWindows();
        lastList = now;
      }

      const control = await api('/agent/control');
      const slots = [];
      for (const s of control.selectedSlots || []) {
        if (!s.hwnd) continue;
        try {
          const shot = await capture(s.hwnd);
          const win = windows.find(w => String(w.hwnd) === String(s.hwnd));
          slots.push({
            slot: s.slot,
            hwnd: String(s.hwnd),
            title: shot.title || win?.title || `窗口 ${s.slot}`,
            imageBase64: shot.imageBase64,
            updatedAt: shot.capturedAt
          });
        } catch (err) {
          slots.push({ slot: s.slot, hwnd: String(s.hwnd), error: err.message, updatedAt: new Date().toISOString() });
        }
      }

      const messages = await fetchPendingMessages();
      saveInboundMessages(messages);

      await heartbeat({
        statusText: slots.length ? `正在监看 ${slots.length} 个窗口` : '在线，等待选择窗口',
        windows,
        slots,
        threads: []
      });
    } catch (err) {
      console.error(`[${new Date().toISOString()}] ${err.message}`);
      try { await heartbeat({ statusText: `错误：${err.message}` }); } catch {}
    }
    await sleep(CAPTURE_INTERVAL_MS);
  }
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});




