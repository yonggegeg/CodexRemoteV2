const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || process.env.RELAY_PORT || 8081);
const HOST = process.env.HOST || '0.0.0.0';
const APP_TOKEN = process.env.APP_TOKEN || 'change-me-app-token';
const AGENT_TOKEN = process.env.AGENT_TOKEN || 'change-me-agent-token';
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'state.json');
const MAX_REALTIME_ITEMS = Number(process.env.MAX_REALTIME_ITEMS || 60);
const MAX_MESSAGE_STATUSES = Number(process.env.MAX_MESSAGE_STATUSES || 40);
const MAX_UPLOADS = Number(process.env.MAX_UPLOADS || 30);
const HISTORY_RESULT_TTL_MS = Number(process.env.HISTORY_RESULT_TTL_MS || 2 * 60 * 1000);
const UPLOAD_TTL_MS = Number(process.env.UPLOAD_TTL_MS || 10 * 60 * 1000);

fs.mkdirSync(DATA_DIR, { recursive: true });

let state = {
  agent: {
    online: false,
    id: null,
    host: null,
    version: 'v2',
    updatedAt: null,
    statusText: '等待 Windows Agent 连接'
  },
  windows: [],
  slots: [
    { slot: 'A', hwnd: null, title: '窗口 A', imageBase64: null, updatedAt: null },
    { slot: 'B', hwnd: null, title: '窗口 B', imageBase64: null, updatedAt: null }
  ],
  threads: [],
  threadItems: [],
  selectedThreadId: null,
  modelCatalog: [],
  permissionProfiles: [],
  codexSettings: {
    model: null,
    reasoningEffort: null,
    permissionMode: "ask"
  },
  codexRuntime: {
    active: false,
    activeTurnId: null,
    threadId: null,
    updatedAt: null
  },
  events: [],
  uploads: [],
  pendingMessages: [],
  pendingCommands: [],
  pendingHistoryRequests: [],
  historyResults: [],
  messageStatuses: []
};

function load() {
  if (!fs.existsSync(DATA_FILE)) return;
  try {
    const saved = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    state = { ...state, ...saved };
  } catch {}
}

function save() {
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(persistentState(), null, 2));
  fs.renameSync(tmp, DATA_FILE);
}

load();
setInterval(save, 5000).unref();

function now() { return new Date().toISOString(); }

function auth(req, kind) {
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  return token === (kind === 'agent' ? AGENT_TOKEN : APP_TOKEN);
}

function send(res, status, data) {
  const body = JSON.stringify(data, null, 2);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Agent-Id',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      if (data.length > 20 * 1024 * 1024) reject(new Error('body too large'));
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function persistentState() {
  return {
    ...state,
    slots: (state.slots || []).map(s => ({ ...s, imageBase64: null })),
    threadItems: [],
    uploads: [],
    pendingHistoryRequests: [],
    historyResults: []
  };
}

function pruneTransient() {
  const cutoffUpload = Date.now() - UPLOAD_TTL_MS;
  state.uploads = (state.uploads || []).filter(u => Date.parse(u.createdAt || 0) >= cutoffUpload);
  const cutoffHistory = Date.now() - HISTORY_RESULT_TTL_MS;
  state.historyResults = (state.historyResults || []).filter(r => Date.parse(r.createdAt || 0) >= cutoffHistory);
  if ((state.pendingHistoryRequests || []).length > 30) state.pendingHistoryRequests = state.pendingHistoryRequests.slice(-30);
  if ((state.messageStatuses || []).length > MAX_MESSAGE_STATUSES) state.messageStatuses = state.messageStatuses.slice(-MAX_MESSAGE_STATUSES);
}

function knownSlotHashes(url) {
  const result = {};
  const raw = url.searchParams.get('slotHashes') || '';
  for (const part of raw.split(',')) {
    const [slot, hash] = part.split(':');
    if (slot && hash) result[slot] = hash;
  }
  return result;
}

function compactState(url) {
  pruneTransient();
  const knownHashes = knownSlotHashes(url);
  return {
    ok: true,
    agent: state.agent,
    windows: state.windows,
    slots: state.slots.map(s => {
      const unchanged = s.imageHash && knownHashes[s.slot] === s.imageHash;
      return { ...s, imageBase64: unchanged ? null : (s.imageBase64 || null), unchanged };
    }),
    threads: state.threads,
    threadItems: (state.threadItems || []).slice(-MAX_REALTIME_ITEMS),
    selectedThreadId: state.selectedThreadId,
    modelCatalog: state.modelCatalog || [],
    permissionProfiles: state.permissionProfiles || [],
    codexSettings: state.codexSettings || {},
    codexRuntime: state.codexRuntime || {},
    latestMessageStatus: (state.messageStatuses || [])[state.messageStatuses.length - 1] || null,
    historyCursor: state.codexRuntime?.historyCursor || null,
    messageStatuses: (state.messageStatuses || []).slice(-20),
    time: now()
  };
}

function makeId(prefix) { return prefix + '_' + Date.now() + '_' + Math.random().toString(16).slice(2); }

function pushEvent(type, payload) {
  state.events.push({ id: `${Date.now()}-${Math.random().toString(16).slice(2)}`, type, payload, createdAt: now() });
  if (state.events.length > 300) state.events = state.events.slice(-300);
}

function setMessageStatus(id, patch) {
  if (!id) return;
  if (!Array.isArray(state.messageStatuses)) state.messageStatuses = [];
  const existing = state.messageStatuses.find(m => m.id === id);
  if (existing) Object.assign(existing, patch, { updatedAt: now() });
  else state.messageStatuses.push({ id, ...patch, updatedAt: now() });
  if (state.messageStatuses.length > MAX_MESSAGE_STATUSES) state.messageStatuses = state.messageStatuses.slice(-MAX_MESSAGE_STATUSES);
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'OPTIONS') return send(res, 204, {});
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    if (req.method === 'GET' && url.pathname === '/api/health') {
      return send(res, 200, { ok: true, name: 'Codex Remote Relay v2', port: PORT, agent: state.agent, time: now() });
    }

    if (url.pathname.startsWith('/api/')) {
      if (!auth(req, 'app')) return send(res, 401, { ok: false, error: 'unauthorized app token' });

      if (req.method === 'GET' && url.pathname === '/api/state') return send(res, 200, compactState(url));
      if (req.method === 'GET' && url.pathname === '/api/windows') return send(res, 200, { ok: true, windows: state.windows, slots: state.slots, agent: state.agent });
      if (req.method === 'GET' && url.pathname === '/api/threads') return send(res, 200, { ok: true, threads: state.threads, selectedThreadId: state.selectedThreadId, agent: state.agent });
      if (req.method === 'POST' && url.pathname === '/api/codex/settings') {
        const body = await readBody(req);
        state.codexSettings = {
          ...state.codexSettings,
          model: body.model || state.codexSettings.model || null,
          reasoningEffort: body.reasoningEffort || state.codexSettings.reasoningEffort || null,
          permissionMode: body.permissionMode || state.codexSettings.permissionMode || "ask",
          updatedAt: now()
        };
        pushEvent('codexSettingsChanged', state.codexSettings);
        save();
        return send(res, 200, { ok: true, codexSettings: state.codexSettings });
      }
      if (req.method === 'POST' && url.pathname === '/api/uploads') {
        const body = await readBody(req);
        if (!body.dataBase64) return send(res, 400, { ok: false, error: 'dataBase64 is required' });
        const upload = {
          id: makeId('img'),
          fileName: body.fileName || 'image.jpg',
          mimeType: body.mimeType || 'image/jpeg',
          dataBase64: body.dataBase64,
          createdAt: now()
        };
        state.uploads.push(upload);
        if (state.uploads.length > MAX_UPLOADS) state.uploads = state.uploads.slice(-MAX_UPLOADS);
        save();
        return send(res, 200, { ok: true, upload: { id: upload.id, fileName: upload.fileName, mimeType: upload.mimeType, createdAt: upload.createdAt } });
      }

      if (req.method === 'POST' && url.pathname === '/api/thread/history/request') {
        const body = await readBody(req);
        const request = {
          id: makeId('hist'),
          threadId: body.threadId || state.selectedThreadId || null,
          cursor: body.cursor || state.codexRuntime?.historyCursor || null,
          limit: Math.min(Math.max(Number(body.limit || 60), 1), 120),
          createdAt: now()
        };
        if (!request.threadId) return send(res, 400, { ok: false, error: 'threadId is required' });
        state.pendingHistoryRequests.push(request);
        pushEvent('historyRequested', { id: request.id, threadId: request.threadId });
        save();
        return send(res, 200, { ok: true, requestId: request.id });
      }

      if (req.method === 'GET' && url.pathname === '/api/thread/history/result') {
        pruneTransient();
        const id = url.searchParams.get('id');
        const idx = (state.historyResults || []).findIndex(r => r.id === id);
        if (idx < 0) return send(res, 202, { ok: true, pending: true });
        const result = state.historyResults.splice(idx, 1)[0];
        save();
        return send(res, 200, result);
      }

      if (req.method === 'POST' && url.pathname === '/api/messages/send') {
        const body = await readBody(req);
        const message = {
          id: makeId('msg'),
          threadId: body.threadId || state.selectedThreadId || null,
          text: body.text || '',
          kind: body.kind || 'normal',
          turnId: body.turnId || state.codexRuntime?.activeTurnId || null,
          attachments: (body.attachments || []).map(a => ({ id: a.id, fileName: a.fileName || null, mimeType: a.mimeType || null })),
          createdAt: now(),
          source: 'ios'
        };
        state.pendingMessages.push(message);
        setMessageStatus(message.id, { status: 'queued', text: message.text, threadId: message.threadId, kind: message.kind, error: null });
        pushEvent('messageQueued', { id: message.id, threadId: message.threadId });
        save();
        return send(res, 200, { ok: true, message });
      }

      if (req.method === 'POST' && url.pathname === '/api/codex/interrupt') {
        const body = await readBody(req);
        const command = {
          id: makeId('cmd'),
          type: 'interrupt',
          threadId: body.threadId || state.selectedThreadId || state.codexRuntime?.threadId || null,
          turnId: body.turnId || state.codexRuntime?.activeTurnId || null,
          createdAt: now()
        };
        state.pendingCommands.push(command);
        pushEvent('commandQueued', command);
        save();
        return send(res, 200, { ok: true, command });
      }

      if (req.method === 'POST' && url.pathname === '/api/windows/select') {
        const body = await readBody(req);
        for (const incoming of body.slots || []) {
          const slot = state.slots.find(s => s.slot === incoming.slot);
          if (!slot) continue;
          slot.hwnd = incoming.hwnd == null ? null : String(incoming.hwnd);
          const win = state.windows.find(w => String(w.hwnd) === String(slot.hwnd));
          slot.title = win?.title || incoming.title || `窗口 ${slot.slot}`;
          slot.imageBase64 = null;
          slot.updatedAt = now();
        }
        pushEvent('windowSelectionChanged', { slots: state.slots.map(s => ({ slot: s.slot, hwnd: s.hwnd, title: s.title })) });
        save();
        return send(res, 200, { ok: true, slots: state.slots });
      }

      if (req.method === 'POST' && url.pathname === '/api/thread/select') {
        const body = await readBody(req);
        state.selectedThreadId = body.threadId || null;
        pushEvent('threadSelectionChanged', { threadId: state.selectedThreadId });
        save();
        return send(res, 200, { ok: true, selectedThreadId: state.selectedThreadId });
      }

      return send(res, 404, { ok: false, error: 'api not found' });
    }

    if (url.pathname.startsWith('/agent/')) {
      if (!auth(req, 'agent')) return send(res, 401, { ok: false, error: 'unauthorized agent token' });
      const agentId = String(req.headers['x-agent-id'] || 'windows-agent-v2');

      if (req.method === 'GET' && url.pathname === '/agent/control') {
        return send(res, 200, {
          ok: true,
          selectedSlots: state.slots.map(s => ({ slot: s.slot, hwnd: s.hwnd })),
          selectedThreadId: state.selectedThreadId,
          codexSettings: state.codexSettings || {},
          desiredCaptureIntervalMs: 1200,
          time: now()
        });
      }

      
      if (req.method === 'GET' && url.pathname === '/agent/messages/next') {
        const rawMessages = state.pendingMessages.splice(0, 10);
        const consumedUploadIds = new Set();
        for (const m of rawMessages) setMessageStatus(m.id, { status: 'deliveredToAgent', threadId: m.threadId, kind: m.kind, error: null });
        const messages = rawMessages.map(m => ({
          ...m,
          attachments: (m.attachments || []).map(a => {
            const upload = state.uploads.find(u => u.id === a.id);
            if (upload) consumedUploadIds.add(upload.id);
            return upload ? { ...a, dataBase64: upload.dataBase64, mimeType: upload.mimeType, fileName: upload.fileName } : a;
          })
        }));
        if (consumedUploadIds.size) state.uploads = state.uploads.filter(u => !consumedUploadIds.has(u.id));
        if (messages.length) save();
        return send(res, 200, { ok: true, messages });
      }
      if (req.method === 'GET' && url.pathname === '/agent/commands/next') {
        const commands = state.pendingCommands.splice(0, 10);
        if (commands.length) save();
        return send(res, 200, { ok: true, commands });
      }

      if (req.method === 'GET' && url.pathname === '/agent/history/next') {
        const requests = state.pendingHistoryRequests.splice(0, 5);
        if (requests.length) save();
        return send(res, 200, { ok: true, requests });
      }

      if (req.method === 'POST' && url.pathname === '/agent/history/result') {
        const body = await readBody(req);
        state.historyResults.push({ ...body, createdAt: now() });
        if (state.historyResults.length > 10) state.historyResults = state.historyResults.slice(-10);
        save();
        return send(res, 200, { ok: true });
      }

      if (req.method === 'POST' && url.pathname === '/agent/messages/status') {
        const body = await readBody(req);
        const updates = Array.isArray(body.statuses) ? body.statuses : (body.id ? [body] : []);
        for (const item of updates) {
          setMessageStatus(item.id, {
            status: item.status || 'unknown',
            threadId: item.threadId || null,
            kind: item.kind || null,
            error: item.error || null,
            processedAt: item.processedAt || now()
          });
          pushEvent('messageStatusChanged', { id: item.id, status: item.status || 'unknown', error: item.error || null });
        }
        save();
        return send(res, 200, { ok: true });
      }
      if (req.method === 'POST' && url.pathname === '/agent/heartbeat') {
        const body = await readBody(req);
        state.agent = {
          online: true,
          id: agentId,
          host: body.host || null,
          version: body.version || 'v2',
          updatedAt: now(),
          statusText: body.statusText || 'Windows Agent 在线'
        };
        if (Array.isArray(body.windows)) state.windows = body.windows;
        if (Array.isArray(body.threads)) {
          state.threads = body.threads;
          if (!state.selectedThreadId && state.threads.length) {
            state.selectedThreadId = state.threads[0].id;
          }
          if (state.selectedThreadId && !state.threads.some(t => t.id === state.selectedThreadId) && state.threads.length) {
            state.selectedThreadId = state.threads[0].id;
          }
        }
        if (Array.isArray(body.threadItems)) state.threadItems = body.threadItems.slice(-MAX_REALTIME_ITEMS);
        if (Array.isArray(body.modelCatalog)) state.modelCatalog = body.modelCatalog;
        if (Array.isArray(body.permissionProfiles)) state.permissionProfiles = body.permissionProfiles;
        if (body.codexSettings) state.codexSettings = { ...state.codexSettings, ...body.codexSettings };
        if (body.codexRuntime) state.codexRuntime = { ...state.codexRuntime, ...body.codexRuntime, updatedAt: now() };
        if (Array.isArray(body.slots)) {
          for (const incoming of body.slots) {
            const slot = state.slots.find(s => s.slot === incoming.slot);
            if (!slot) continue;
            slot.hwnd = incoming.hwnd == null ? slot.hwnd : String(incoming.hwnd);
            slot.title = incoming.title || slot.title;
            slot.imageBase64 = incoming.imageBase64 || slot.imageBase64;
            slot.imageHash = incoming.imageHash || slot.imageHash || null;
            slot.updatedAt = incoming.updatedAt || now();
            slot.error = incoming.error || null;
          }
        }
        save();
        return send(res, 200, { ok: true });
      }

      return send(res, 404, { ok: false, error: 'agent endpoint not found' });
    }

    return send(res, 404, { ok: false, error: 'not found' });
  } catch (err) {
    return send(res, 500, { ok: false, error: err.message });
  }
});

process.on('SIGINT', () => { save(); process.exit(0); });
process.on('SIGTERM', () => { save(); process.exit(0); });

server.listen(PORT, HOST, () => {
  console.log(`Codex Remote Relay v2 listening on http://${HOST}:${PORT}`);
});

