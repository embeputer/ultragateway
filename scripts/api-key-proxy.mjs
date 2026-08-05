#!/usr/bin/env node
/**
 * Reverse proxy in front of Supergateway with optional Bearer API key auth.
 * Protects the full MCP HTTP surface (SSE, POST /message, streamable HTTP, WS upgrade).
 */
import http from 'node:http';
import net from 'node:net';
import { timingSafeEqual } from 'node:crypto';

function usage() {
  process.stderr.write(
    'usage: api-key-proxy.mjs --listen <port> --upstream <port> [--api-key <key>]\n',
  );
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { listen: null, upstream: null, apiKey: null };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--listen' && argv[i + 1]) {
      opts.listen = Number(argv[++i]);
    } else if (arg === '--upstream' && argv[i + 1]) {
      opts.upstream = Number(argv[++i]);
    } else if (arg === '--api-key' && argv[i + 1]) {
      opts.apiKey = argv[++i];
    } else {
      usage();
    }
  }
  if (!opts.listen || !opts.upstream || !opts.apiKey) {
    usage();
  }
  return opts;
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
  process.stderr.write(`[${new Date().toISOString()}] api-key-proxy: ${message}\n`);
}

const { listen, upstream, apiKey } = parseArgs(process.argv);

const server = http.createServer((clientReq, clientRes) => {
  if (!authorized(clientReq, apiKey)) {
    sendUnauthorized(clientRes);
    return;
  }

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
});

server.on('upgrade', (clientReq, clientSocket, head) => {
  if (!authorized(clientReq, apiKey)) {
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
  log(`listening on ${listen}, forwarding to 127.0.0.1:${upstream} (Bearer auth enabled)`);
});
