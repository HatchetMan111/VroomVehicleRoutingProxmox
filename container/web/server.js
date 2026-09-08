'use strict';
/*
 * VROOM Web-Gateway.
 * - Serviert die statische Web UI (public/index.html) auf 0.0.0.0:$WEB_PORT
 * - Proxy: GET /health -> API /health, POST /solve (und POST /) -> API /
 * Nur Node-Core-Module (kein npm install noetig).
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const WEB_PORT = parseInt(process.env.WEB_PORT || '8080', 10);
const API_URL = process.env.API_URL || 'http://127.0.0.1:3000';
const api = new URL(API_URL);
const API_HOST = api.hostname;
const API_PORT = parseInt(api.port || '3000', 10);
const PUBLIC_DIR = path.join(__dirname, 'public');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
};

function send(res, code, body, type) {
  res.writeHead(code, { 'Content-Type': type || 'application/json; charset=utf-8' });
  res.end(body);
}

function proxy(req, res, apiPath) {
  let payload = '';
  req.on('data', (c) => { payload += c; });
  req.on('end', () => {
    const opts = {
      host: API_HOST, port: API_PORT, path: apiPath, method: req.method,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
      timeout: 120000,
    };
    const preq = http.request(opts, (pres) => {
      let data = '';
      pres.on('data', (c) => { data += c; });
      pres.on('end', () => {
        res.writeHead(pres.statusCode || 500, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(data);
      });
    });
    preq.on('timeout', () => { preq.destroy(); send(res, 504, JSON.stringify({ code: 4, error: 'Gateway-Timeout zur VROOM-API' })); });
    preq.on('error', (e) => {
      // Volle Fehlerkette statt nur letzter Zeile (Anforderung #4)
      send(res, 502, JSON.stringify({ code: 4, error: 'API nicht erreichbar', detail: String(e && e.stack || e), api: API_URL }));
    });
    preq.end(payload);
  });
}

function proxyGet(res, apiPath) {
  http.get({ host: API_HOST, port: API_PORT, path: apiPath, timeout: 15000 }, (pres) => {
    let data = '';
    pres.on('data', (c) => { data += c; });
    pres.on('end', () => {
      if (apiPath === '/health') {
        // vroom-express /health antwortet mit leerem Body + Statuscode -> als JSON wrappen
        send(res, pres.statusCode || 500, JSON.stringify({ status: pres.statusCode === 200 ? 'healthy' : 'unhealthy', api_status: pres.statusCode }));
      } else {
        res.writeHead(pres.statusCode || 500, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(data);
      }
    });
  }).on('timeout', () => send(res, 504, JSON.stringify({ code: 4, error: 'Gateway-Timeout zur VROOM-API' })))
    .on('error', (e) => send(res, 502, JSON.stringify({ code: 4, error: 'API nicht erreichbar', detail: String(e && e.stack || e), api: API_URL })));
}

function serveFile(reqPath, res) {
  const rel = reqPath === '/' ? '/index.html' : reqPath.split('?')[0];
  const file = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!file.startsWith(PUBLIC_DIR)) return send(res, 403, JSON.stringify({ code: 1, error: 'Forbidden' }));
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, JSON.stringify({ code: 1, error: 'Nicht gefunden: ' + rel }));
    send(res, 200, buf, MIME[path.extname(file)] || 'application/octet-stream');
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'GET' && (url.pathname === '/health' || url.pathname === '/api/health')) return proxyGet(res, '/health');
  if (req.method === 'POST' && (url.pathname === '/solve' || url.pathname === '/api/solve' || url.pathname === '/')) return proxy(req, res, '/');
  if (req.method === 'GET') return serveFile(url.pathname, res);
  return send(res, 405, JSON.stringify({ code: 1, error: 'Method not allowed' }));
});

server.listen(WEB_PORT, '0.0.0.0', () => {
  console.log(`vroom-web listening on 0.0.0.0:${WEB_PORT} (API: ${API_URL})`);
});
