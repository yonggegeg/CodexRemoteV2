const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || process.env.RELAY_PORT || 8081);
const HOST = process.env.HOST || '0.0.0.0';
const APP_TOKEN = process.env.APP_TOKEN || 'change-me-app-token';
const AGENT_TOKEN = process.env.AGENT_TOKEN || 'change-me-agent-token';
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'state.json');

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
  codexSettings: {
    model: null,
    reasoningEffort: null,
    permissionMode: "ask"
  },
  events: [],
  uploads: [],
  pendingMessages: []
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
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
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

function compactState() {
  return {
    ok: true,
    agent: state.agent,
    windows: state.windows,
    slots: state.slots.map(s => ({ ...s, imageBase64: s.imageBase64 ? s.imageBase64 : null })),
    threads: state.threads,
    threadItems: state.threadItems || [],
    selectedThreadId: state.selectedThreadId,
    modelCatalog: state.modelCatalog || [],
    codexSettings: state.codexSettings || {},
    time: now()
  };
}

function makeId(prefix) { return prefix + '_' + Date.now() + '_' + Math.random().toString(16).slice(2); }

function pushEvent(type, payload) {
  state.events.push({ id: `${Date.now()}-${Math.random().toString(16).slice(2)}`, type, payload, createdAt: now() });
  if (state.events.length > 300) state.events = state.events.slice(-300);
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

      if (req.method === 'GET' && url.pathname === '/api/state') return send(res, 200, compactState());
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
        if (state.uploads.length > 100) state.uploads = state.uploads.slice(-100);
        save();
        return send(res, 200, { ok: true, upload: { id: upload.id, fileName: upload.fileName, mimeType: upload.mimeType, createdAt: upload.createdAt } });
      }

      if (req.method === 'POST' && url.pathname === '/api/messages/send') {
        const body = await readBody(req);
        const message = {
          id: makeId('msg'),
          threadId: body.threadId || state.selectedThreadId || null,
          text: body.text || '',
          kind: body.kind || 'normal',
          attachments: (body.attachments || []).map(a => ({ id: a.id, fileName: a.fileName || null, mimeType: a.mimeType || null })),
          createdAt: now(),
          source: 'ios'
        };
        state.pendingMessages.push(message);
        pushEvent('messageQueued', { id: message.id, threadId: message.threadId });
        save();
        return send(res, 200, { ok: true, message });
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
        const messages = state.pendingMessages.splice(0, 10).map(m => ({
          ...m,
          attachments: (m.attachments || []).map(a => {
            const upload = state.uploads.find(u => u.id === a.id);
            return upload ? { ...a, dataBase64: upload.dataBase64, mimeType: upload.mimeType, fileName: upload.fileName } : a;
          })
        }));
        if (messages.length) save();
        return send(res, 200, { ok: true, messages });
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
        if (Array.isArray(body.threadItems)) state.threadItems = body.threadItems;
        if (Array.isArray(body.modelCatalog)) state.modelCatalog = body.modelCatalog;
        if (body.codexSettings) state.codexSettings = { ...state.codexSettings, ...body.codexSettings };
        if (Array.isArray(body.slots)) {
          for (const incoming of body.slots) {
            const slot = state.slots.find(s => s.slot === incoming.slot);
            if (!slot) continue;
            slot.hwnd = incoming.hwnd == null ? slot.hwnd : String(incoming.hwnd);
            slot.title = incoming.title || slot.title;
            slot.imageBase64 = incoming.imageBase64 || slot.imageBase64;
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



