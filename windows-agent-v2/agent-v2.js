const os = require('os');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const RELAY_URL = (process.env.RELAY_URL || 'http://115.159.221.170:8080').replace(/\/$/, '');
const AGENT_TOKEN = process.env.AGENT_TOKEN || 'change-me-agent-token';
const AGENT_ID = process.env.AGENT_ID || `${os.hostname()}-codex-agent-v2`;
const CAPTURE_INTERVAL_MS = Number(process.env.CAPTURE_INTERVAL_MS || 1200);
const LIST_INTERVAL_MS = Number(process.env.LIST_INTERVAL_MS || 3000);
const CODEX_INTERVAL_MS = Number(process.env.CODEX_INTERVAL_MS || 2500);

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

class CodexAppServer {
  constructor() {
    this.child = null;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = '';
    this.initialized = false;
    this.lastError = null;
    this.notifications = [];
    this.activeTurns = new Map();
  }

  ensureStarted() {
    if (this.child && !this.child.killed) return;
    this.child = spawn('cmd.exe', ['/c', 'codex', 'app-server', '--stdio'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      shell: false
    });
    this.initialized = false;
    this.buffer = '';
    this.child.stdout.on('data', d => this.onStdout(d));
    this.child.stderr.on('data', d => {
      const text = d.toString('utf8').trim();
      if (text) console.log(`[codex stderr] ${text}`);
    });
    this.child.on('exit', code => {
      this.lastError = `codex app-server exited: ${code}`;
      for (const { reject } of this.pending.values()) reject(new Error(this.lastError));
      this.pending.clear();
      this.child = null;
      this.initialized = false;
    });
  }

  onStdout(data) {
    this.buffer += data.toString('utf8');
    let idx;
    while ((idx = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id != null) {
        const pending = this.pending.get(msg.id);
        if (!pending) continue;
        this.pending.delete(msg.id);
        if (msg.error) pending.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else pending.resolve(msg.result);
      } else if (msg.method) {
        this.notifications.push({ ...msg, receivedAt: new Date().toISOString() });
        if (this.notifications.length > 200) this.notifications = this.notifications.slice(-200);
        this.trackNotification(msg);
      }
    }
  }

  trackNotification(msg) {
    const p = msg.params || {};
    const threadId = p.threadId || p.thread_id;
    const turnId = p.turnId || p.turn_id || p.turn?.id;
    if (!threadId || !turnId) return;
    if (msg.method === 'turn/started' || msg.method === 'turn/startedNotification' || msg.method === 'turn/started/notification') {
      this.activeTurns.set(threadId, turnId);
    }
    if (msg.method === 'turn/completed' || msg.method === 'turn/completedNotification' || msg.method === 'turn/completed/notification') {
      this.activeTurns.delete(threadId);
    }
  }

  request(method, params = {}, timeoutMs = 20000) {
    this.ensureStarted();
    const id = this.nextId++;
    const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`codex request timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: err => { clearTimeout(timer); reject(err); }
      });
      this.child.stdin.write(payload);
    });
  }

  async initialize() {
    this.ensureStarted();
    if (this.initialized) return;
    await this.request('initialize', {
      clientInfo: { name: 'codex-remote-windows-agent-v2', version: '0.3.0' },
      capabilities: { experimentalApi: true }
    }, 30000);
    this.initialized = true;
  }

  async listThreads(limit = 20) {
    await this.initialize();
    const result = await this.request('thread/list', {
      limit,
      sortDirection: 'desc',
      sortKey: 'updated_at'
    });
    return (result.data || []).map(t => ({
      id: t.id || t.sessionId,
      title: t.name || t.preview || '未命名任务',
      status: typeof t.status === 'string' ? t.status : (t.status?.type || 'unknown'),
      updatedAt: t.updatedAt ? new Date(t.updatedAt * 1000).toISOString() : null,
      cwd: t.cwd || null,
      preview: t.preview || null
    })).filter(t => t.id);
  }

  async listThreadItems(threadId, limit = 80) {
    await this.initialize();
    try {
      const result = await this.request('thread/items/list', {
        threadId,
        limit,
        sortDirection: 'asc'
      });
      return result.data || [];
    } catch (err) {
      const result = await this.request('thread/read', { threadId, includeTurns: true });
      const turns = result.thread?.turns || [];
      const items = [];
      for (const turn of turns) {
        for (const item of turn.items || []) {
          items.push({ ...item, turnId: turn.id });
        }
      }
      return items.slice(-limit);
    }
  }

  simplifyThreadItems(items) {
    return (items || []).slice(-80).map((item, index) => {
      const raw = item.item || item;
      const role = raw.role || raw.type || item.type || 'item';
      const images = [];
      let text = '';

      if (raw.type === 'fileChange') {
        text = summarizeFileChange(raw);
      } else if (typeof raw.text === 'string') {
        text = raw.text;
      }

      if (!text && typeof raw.message === 'string') text = raw.message;

      if (!text && Array.isArray(raw.content)) {
        text = raw.content.map(c => {
          if (typeof c === 'string') return c;
          if ((c.type === 'localImage' || c.type === 'image') && c.path) {
            const image = imageAttachmentFromPath(c.path);
            if (image) images.push(image);
            return '';
          }
          if ((c.type === 'image' || c.type === 'image_url') && c.url) {
            images.push({ id: c.url, fileName: path.basename(c.url), mimeType: 'image/jpeg', url: c.url, dataBase64: null, error: null });
            return '';
          }
          return c.text || c.content || c.summary || '';
        }).filter(Boolean).join('\n');
        if (raw.type === 'userMessage') text = cleanUserText(text);
      }

      if (!text && Array.isArray(raw.summary)) text = raw.summary.join('\n');
      if (!text && raw.name) text = raw.name;
      if (!text && raw.type === 'reasoning') text = '正在思考 / 处理中';
      if (!text) text = '';

      return {
        id: raw.id || item.id || `${Date.now()}-${index}`,
        role,
        text,
        createdAt: raw.createdAt || item.createdAt || null,
        type: raw.type || item.type || null,
        images
      };
    }).filter(x => x.text || (x.images && x.images.length));
  }

  async listModels() {
    await this.initialize();
    const result = await this.request('model/list', {});
    return (result.data || []).filter(m => !m.hidden).map(m => ({
      id: m.id || m.model,
      model: m.model || m.id,
      displayName: m.displayName || m.model || m.id,
      description: m.description || null,
      isDefault: m.isDefault || false,
      defaultReasoningEffort: m.defaultReasoningEffort || null,
      supportedReasoningEfforts: (m.supportedReasoningEfforts || []).map(e => ({
        id: e.reasoningEffort,
        description: e.description || null
      }))
    }));
  }

  async readConfig() {
    await this.initialize();
    const result = await this.request('config/read', {});
    const c = result.config || {};
    return {
      model: c.model || null,
      reasoningEffort: c.model_reasoning_effort || null,
      permissionMode: 'ask'
    };
  }

  mapPermission(permissionMode) {
    if (permissionMode === 'full') return { approvalPolicy: 'never', permissions: ':danger-full-access' };
    if (permissionMode === 'auto') return { approvalPolicy: 'on-request', approvalsReviewer: 'auto_review', permissions: null };
    return { approvalPolicy: 'on-request', approvalsReviewer: 'user', permissions: null };
  }

  async updateThreadSettings(threadId, settings) {
    await this.initialize();
    if (!threadId) return null;
    const permission = this.mapPermission(settings.permissionMode || 'ask');
    return await this.request('thread/settings/update', {
      threadId,
      model: settings.model || null,
      effort: settings.reasoningEffort || null,
      approvalPolicy: permission.approvalPolicy,
      approvalsReviewer: permission.approvalsReviewer || null,
      permissions: permission.permissions || null
    }, 30000);
  }

  async sendMessage(message, attachmentPaths = [], settings = {}) {
    await this.initialize();
    const threadId = message.threadId;
    if (!threadId) throw new Error('没有选择 Codex 任务');
    const input = [];
    const text = (message.text || '').trim();
    if (text) input.push({ type: 'text', text });
    for (const p of attachmentPaths) {
      input.push({ type: 'image', path: p, detail: 'high' });
    }
    if (!input.length) throw new Error('消息内容为空');

    if (message.kind === 'steer') {
      const expectedTurnId = this.activeTurns.get(threadId);
      if (expectedTurnId) {
        return await this.request('turn/steer', { threadId, expectedTurnId, input }, 30000);
      }
      return await this.request('turn/start', { threadId, input, model: settings.model || null, effort: settings.reasoningEffort || null, approvalPolicy: this.mapPermission(settings.permissionMode || 'ask').approvalPolicy, permissions: this.mapPermission(settings.permissionMode || 'ask').permissions || null }, 30000);
    }
    return await this.request('turn/start', { threadId, input, model: settings.model || null, effort: settings.reasoningEffort || null, approvalPolicy: this.mapPermission(settings.permissionMode || 'ask').approvalPolicy, permissions: this.mapPermission(settings.permissionMode || 'ask').permissions || null }, 30000);
  }
}

const codex = new CodexAppServer();
let latestCodexSettings = { model: null, reasoningEffort: null, permissionMode: 'ask' };

function mergeDefinedSettings(base, incoming) {
  const next = { ...base };
  if (!incoming) return next;
  if (incoming.model) next.model = incoming.model;
  if (incoming.reasoningEffort) next.reasoningEffort = incoming.reasoningEffort;
  if (incoming.permissionMode) next.permissionMode = incoming.permissionMode;
  return next;
}

function mimeFromPath(filePath) {
  const ext = path.extname(filePath || '').toLowerCase();
  if (ext === '.png') return 'image/png';
  if (ext === '.webp') return 'image/webp';
  if (ext === '.gif') return 'image/gif';
  return 'image/jpeg';
}

function imageAttachmentFromPath(filePath) {
  try {
    if (!filePath || !fs.existsSync(filePath)) return null;
    const stat = fs.statSync(filePath);
    return {
      id: filePath,
      fileName: path.basename(filePath),
      mimeType: mimeFromPath(filePath),
      localPath: filePath,
      dataBase64: stat.size <= 8 * 1024 * 1024 ? fs.readFileSync(filePath).toString('base64') : null,
      error: stat.size > 8 * 1024 * 1024 ? '图片过大，暂不预览' : null
    };
  } catch (err) {
    return {
      id: filePath || `image-${Date.now()}`,
      fileName: path.basename(filePath || 'image'),
      mimeType: mimeFromPath(filePath),
      localPath: filePath,
      dataBase64: null,
      error: err.message
    };
  }
}

function cleanUserText(text) {
  if (!text) return '';
  const marker = '## My request for Codex:';
  const idx = text.indexOf(marker);
  if (idx >= 0) return text.slice(idx + marker.length).trim();
  return text.replace(/# Files mentioned by the user:[\s\S]*?(?=## My request for Codex:|$)/, '').trim();
}

function summarizeFileChange(raw) {
  const changes = Array.isArray(raw.changes) ? raw.changes : [];
  const lines = changes.slice(0, 8).map(change => {
    const file = path.basename(change.path || 'unknown');
    const kind = change.kind?.type || change.kind || 'update';
    return `• ${kind}: ${file}`;
  });
  const extra = changes.length > 8 ? `\n…另外 ${changes.length - 8} 个文件` : '';
  return `文件变更 ${changes.length} 个\n${lines.join('\n')}${extra}`;
}

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
  const saved = [];
  if (!messages.length) return;
  const dir = path.join(__dirname, 'inbound-messages');
  fs.mkdirSync(dir, { recursive: true });
  for (const msg of messages) {
    const msgDir = path.join(dir, msg.id);
    fs.mkdirSync(msgDir, { recursive: true });
    fs.writeFileSync(path.join(msgDir, 'message.json'), JSON.stringify({ ...msg, attachments: (msg.attachments || []).map(a => ({ ...a, dataBase64: undefined })) }, null, 2), 'utf8');
    const attachmentPaths = [];
    for (const a of msg.attachments || []) {
      if (!a.dataBase64) continue;
      const safeName = (a.fileName || `${a.id}.jpg`).replace(/[<>:"/\\|?*]/g, '_');
      const filePath = path.join(msgDir, safeName);
      fs.writeFileSync(filePath, Buffer.from(a.dataBase64, 'base64'));
      attachmentPaths.push(filePath);
    }
    console.log(`[message] received ${msg.id}: ${msg.text || ''} (${(msg.attachments || []).length} attachment(s))`);
    saved.push({ message: msg, attachmentPaths });
  }
  return saved;
}

async function handleInboundMessages(messages) {
  const saved = saveInboundMessages(messages) || [];
  for (const item of saved) {
    try {
      await codex.sendMessage(item.message, item.attachmentPaths, latestCodexSettings);
      console.log(`[codex] sent ${item.message.id} to thread ${item.message.threadId || '(selected)'}`);
    } catch (err) {
      console.error(`[codex] failed to send ${item.message.id}: ${err.message}`);
    }
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
  let threads = [];
  let lastCodex = 0;
  let codexStatus = 'Codex 未连接';
  let modelCatalog = [];
  let codexConfig = {};

  while (true) {
    try {
      const now = Date.now();
      if (now - lastList > LIST_INTERVAL_MS) {
        windows = await listWindows();
        lastList = now;
      }

      if (now - lastCodex > CODEX_INTERVAL_MS) {
        try {
          threads = await codex.listThreads(20);
          modelCatalog = await codex.listModels();
          codexConfig = await codex.readConfig();
          latestCodexSettings = mergeDefinedSettings(latestCodexSettings, codexConfig);
          codexStatus = `Codex 已连接，发现 ${threads.length} 个任务`;
        } catch (err) {
          codexStatus = `Codex 连接失败：${err.message}`;
        }
        lastCodex = now;
      }

      const control = await api('/agent/control');
      if (control.codexSettings) {
        latestCodexSettings = mergeDefinedSettings(latestCodexSettings, control.codexSettings);
        try { await codex.updateThreadSettings(control.selectedThreadId, latestCodexSettings); } catch (err) { console.error(`[codex] settings update failed: ${err.message}`); }
      }
      let threadItems = [];
      if (control.selectedThreadId) {
        try {
          const rawItems = await codex.listThreadItems(control.selectedThreadId, 80);
          threadItems = codex.simplifyThreadItems(rawItems);
        } catch (err) {
          console.error(`[codex] thread items failed: ${err.message}`);
        }
      }
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
      await handleInboundMessages(messages);

      await heartbeat({
        statusText: `${slots.length ? `正在监看 ${slots.length} 个窗口` : '在线，等待选择窗口'}；${codexStatus}`,
        windows,
        slots,
        threads,
        threadItems,
        modelCatalog,
        codexSettings: latestCodexSettings
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



