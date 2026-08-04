#!/usr/bin/env node
/**
 * Patch supergateway stdioToSse.js for per-session Server instances.
 *
 * supergateway <=3.4.3 reuses one MCP Server for all SSE connections; the MCP SDK
 * rejects a second connect() with "Already connected to a transport", which
 * crashes the process on reconnect or concurrent clients.
 *
 * Upstream: https://github.com/supercorp-ai/supergateway/issues/138
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const PATCH_MARKER = 'ultragateway: per-session server patch';

function die(message) {
  process.stderr.write(`patch-supergateway-sse: ${message}\n`);
  process.exit(1);
}

const target = process.argv[2];
if (!target) {
  die('usage: patch-supergateway-sse.js <path/to/stdioToSse.js>');
}

if (!fs.existsSync(target)) {
  die(`file not found: ${target}`);
}

let source = fs.readFileSync(target, 'utf8');
if (source.includes(PATCH_MARKER)) {
  process.exit(0);
}

const globalServer =
  "    const server = new Server({ name: 'supergateway', version: getVersion() }, { capabilities: {} });\n";
const perSessionServer =
  "        const server = new Server({ name: 'supergateway', version: getVersion() }, { capabilities: {} }); // ultragateway: per-session server patch\n";

if (!source.includes(globalServer)) {
  die(`unexpected stdioToSse.js format in ${path.basename(target)} — already patched or incompatible version`);
}

const connectBlock =
  '        const sseTransport = new SSEServerTransport(`${baseUrl}${messagePath}`, res);\n        await server.connect(sseTransport);';
const patchedConnectBlock =
  '        const sseTransport = new SSEServerTransport(`${baseUrl}${messagePath}`, res);\n' +
  perSessionServer +
  '        await server.connect(sseTransport);';

if (!source.includes(connectBlock)) {
  die(`unexpected connect block in ${path.basename(target)}`);
}

source = source.replace(globalServer, '');
source = source.replace(connectBlock, patchedConnectBlock);

if (!source.includes(PATCH_MARKER)) {
  die('patch application failed');
}

fs.writeFileSync(target, source);
process.stderr.write(`patch-supergateway-sse: patched ${target}\n`);
