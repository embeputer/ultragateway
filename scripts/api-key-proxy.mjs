#!/usr/bin/env node
/**
 * Public HTTP listener in front of Supergateway.
 * - Serves GET /share/{token}[/filename] without Bearer auth (see share-handler.mjs).
 * - Proxies all other routes to Supergateway, with optional Bearer API key auth.
 */
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { handleShareRequest, isShareRequest } from './share-handler.mjs';

function usage() {
  process.stderr.write(
    'usage: api-key-proxy.mjs --listen <port> --upstream <port> [--api-key <key>] [--support-dir <dir>]\n',
  );
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { listen: null, upstream: null, apiKey: null, supportDir: null };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--listen' && argv[i + 1]) {
      opts.listen = Number(argv[++i]);
    } else if (arg === '--upstream' && argv[i + 1]) {
      opts.upstream = Number(argv[++i]);
    } else if (arg === '--api-key' && argv[i + 1]) {
      opts.apiKey = argv[++i];
    } else if (arg === '--support-dir' && argv[i + 1]) {
      opts.supportDir = argv[++i];
    } else {
      usage();
    }
  }
  if (!opts.listen || !opts.upstream) {
    usage();
  }
  return opts;
}

function defaultSupportDir() {
  return path.join(os.homedir(), 'Library', 'Application Support', 'ultragateway');
}

function extractBearer(authHeader) {
  if (!authHeader || typeof authHeader !== 'string') {
    return null;
  }
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') {
    return false;
  }
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) {
    return false;
  }
  return timingSafeEqual(bufA, bufB);
}

function authorized(req, apiKey) {
  const token = extractBearer(req.headers.authorization);
  return token !== null && safeEqual(token, apiKey);
}

function sendUnauthorized(res) {
  res.writeHead(401, { 'Content-Type': 'text/plain', 'WWW-Authenticate': 'Bearer' });
  res.end('Unauthorized');
}

function log(message) {
  process.stderr.write(`[${new Date().toISOString()}] gateway-proxy: ${message}\n`);
}

function proxyToUpstream(clientReq, clientRes) {
  const proxyReq = http.request(
    {
      hostname: '127.0.0.1',
      port: upstream,
      path: clientReq.url,
      method: clientReq.method,
      headers: clientReq.headers,
    },
    (proxyRes) => {
      clientRes.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers);
      proxyRes.pipe(clientRes);
    },
  );

  proxyReq.on('error', (err) => {
    log(`upstream error: ${err.message}`);
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { 'Content-Type': 'text/plain' });
    }
    clientRes.end('Bad Gateway');
  });

  clientReq.pipe(proxyReq);
}

const opts = parseArgs(process.argv);
const { listen, upstream, apiKey } = opts;
const supportDir = opts.supportDir
  ?? process.env.ULTRAGATEWAY_SUPPORT_DIR
  ?? defaultSupportDir();

const server = http.createServer(async (clientReq, clientRes) => {
  if (isShareRequest(clientReq.url)) {
    try {
      await handleShareRequest(clientReq, clientRes, supportDir, log);
    } catch (err) {
      log(`share handler error: ${err.message}`);
      if (!clientRes.headersSent) {
        clientRes.writeHead(500, { 'Content-Type': 'text/plain' });
      }
      clientRes.end('Internal Server Error');
    }
    return;
  }

  if (apiKey && !authorized(clientReq, apiKey)) {
    sendUnauthorized(clientRes);
    return;
  }

  proxyToUpstream(clientReq, clientRes);
});

server.on('upgrade', (clientReq, clientSocket, head) => {
  if (isShareRequest(clientReq.url)) {
    clientSocket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    clientSocket.destroy();
    return;
  }

  if (apiKey && !authorized(clientReq, apiKey)) {
    clientSocket.write('HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\n\r\n');
    clientSocket.destroy();
    return;
  }

  const upstreamSocket = net.connect(upstream, '127.0.0.1', () => {
    const headerLines = [`${clientReq.method} ${clientReq.url} HTTP/1.1`];
    for (const [key, value] of Object.entries(clientReq.headers)) {
      if (Array.isArray(value)) {
        for (const item of value) {
          headerLines.push(`${key}: ${item}`);
        }
      } else if (value !== undefined) {
        headerLines.push(`${key}: ${value}`);
      }
    }
    upstreamSocket.write(`${headerLines.join('\r\n')}\r\n\r\n`);
    if (head.length > 0) {
      upstreamSocket.write(head);
    }
    clientSocket.pipe(upstreamSocket);
    upstreamSocket.pipe(clientSocket);
  });

  upstreamSocket.on('error', (err) => {
    log(`upgrade upstream error: ${err.message}`);
    clientSocket.destroy();
  });

  clientSocket.on('error', () => {
    upstreamSocket.destroy();
  });
});

server.listen(listen, () => {
  const authMode = apiKey ? 'Bearer auth enabled' : 'no Bearer auth';
  log(`listening on ${listen}, forwarding to 127.0.0.1:${upstream} (${authMode})`);
  log(`share files from ${path.join(supportDir, 'shares')}`);
});
