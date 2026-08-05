#!/usr/bin/env node
/**
 * Ephemeral file share HTTP handler for GET /share/{token}[/filename].
 *
 * Share store convention (must match ultragateway_share_file MCP mint tool):
 *   {support}/shares/<token>/meta.json  → { token, filename, contentType?, createdAt, expiresAt }
 *   {support}/shares/<token>/<filename> → file bytes
 *
 * Also tolerates legacy/alternate layout:
 *   {support}/shares/<token>.json       → metadata (same fields)
 */
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';

const SHARE_PATH_RE = /^\/share\/([^/?#]+)(?:\/([^/?#]*))?$/;

const CONTENT_TYPES = {
  '.txt': 'text/plain; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.zip': 'application/zip',
  '.gz': 'application/gzip',
  '.csv': 'text/csv; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
};

function guessContentType(filename) {
  const ext = path.extname(filename).toLowerCase();
  return CONTENT_TYPES[ext] ?? 'application/octet-stream';
}

function isImageContentType(contentType) {
  return typeof contentType === 'string' && contentType.toLowerCase().startsWith('image/');
}

function parseExpiresAt(value) {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value < 1e12 ? value * 1000 : value;
  }
  if (typeof value === 'string') {
    const asNum = Number(value);
    if (Number.isFinite(asNum) && value.trim() !== '') {
      return asNum < 1e12 ? asNum * 1000 : asNum;
    }
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
  }
  return null;
}

function isExpired(expiresAt) {
  const ms = parseExpiresAt(expiresAt);
  if (ms === null) {
    return true;
  }
  return Date.now() >= ms;
}

export function parseShareRequestUrl(url) {
  if (!url) {
    return null;
  }
  const pathname = url.split('?')[0].split('#')[0];
  const match = pathname.match(SHARE_PATH_RE);
  if (!match) {
    return null;
  }
  const token = decodeURIComponent(match[1]);
  const filename = match[2] !== undefined && match[2] !== ''
    ? decodeURIComponent(match[2])
    : null;
  return { token, filename };
}

export function isShareRequest(url) {
  return parseShareRequestUrl(url) !== null;
}

async function readMetaFile(metaPath) {
  try {
    const raw = await fsp.readFile(metaPath, 'utf8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function loadShareMeta(sharesDir, token) {
  const dirMetaPath = path.join(sharesDir, token, 'meta.json');
  const flatMetaPath = path.join(sharesDir, `${token}.json`);

  const dirMeta = await readMetaFile(dirMetaPath);
  if (dirMeta) {
    return { meta: dirMeta, shareDir: path.join(sharesDir, token) };
  }

  const flatMeta = await readMetaFile(flatMetaPath);
  if (flatMeta) {
    return { meta: flatMeta, shareDir: path.join(sharesDir, token) };
  }

  return null;
}

async function bestEffortDeleteShare(sharesDir, token) {
  const shareDir = path.join(sharesDir, token);
  const flatMeta = path.join(sharesDir, `${token}.json`);
  await Promise.allSettled([
    fsp.rm(shareDir, { recursive: true, force: true }),
    fsp.rm(flatMeta, { force: true }),
  ]);
}

function resolveShareFilePath(shareDir, filename) {
  const filePath = path.join(shareDir, filename);
  const resolved = path.resolve(filePath);
  const resolvedDir = path.resolve(shareDir);
  if (!resolved.startsWith(`${resolvedDir}${path.sep}`) && resolved !== resolvedDir) {
    return null;
  }
  return resolved;
}

function sendNotFound(res) {
  if (!res.headersSent) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
  }
  res.end('Not Found');
}

function sendMethodNotAllowed(res) {
  if (!res.headersSent) {
    res.writeHead(405, { 'Content-Type': 'text/plain', Allow: 'GET, HEAD' });
  }
  res.end('Method Not Allowed');
}

/**
 * Handle GET/HEAD /share/{token}[/filename]. Returns true if the request was handled.
 */
export async function handleShareRequest(req, res, supportDir, log = () => {}) {
  const parsed = parseShareRequestUrl(req.url);
  if (!parsed) {
    return false;
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendMethodNotAllowed(res);
    return true;
  }

  const sharesDir = path.join(supportDir, 'shares');
  const loaded = await loadShareMeta(sharesDir, parsed.token);

  if (!loaded) {
    await bestEffortDeleteShare(sharesDir, parsed.token);
    sendNotFound(res);
    return true;
  }

  const { meta, shareDir } = loaded;

  if (isExpired(meta.expiresAt)) {
    log(`share expired: ${parsed.token}`);
    await bestEffortDeleteShare(sharesDir, parsed.token);
    sendNotFound(res);
    return true;
  }

  const filename = parsed.filename ?? meta.filename;
  if (!filename || typeof filename !== 'string') {
    sendNotFound(res);
    return true;
  }

  const filePath = resolveShareFilePath(shareDir, filename);
  if (!filePath) {
    sendNotFound(res);
    return true;
  }

  let stat;
  try {
    stat = await fsp.stat(filePath);
  } catch {
    sendNotFound(res);
    return true;
  }

  if (!stat.isFile()) {
    sendNotFound(res);
    return true;
  }

  const contentType = meta.contentType || guessContentType(filename);
  const disposition = isImageContentType(contentType) ? 'inline' : 'attachment';
  const headers = {
    'Content-Type': contentType,
    'Content-Length': stat.size,
    'Content-Disposition': `${disposition}; filename="${filename.replace(/"/g, '\\"')}"`,
    'Cache-Control': 'private, no-store',
  };

  if (req.method === 'HEAD') {
    res.writeHead(200, headers);
    res.end();
    return true;
  }

  res.writeHead(200, headers);
  try {
    await pipeline(fs.createReadStream(filePath), res);
  } catch (err) {
    log(`share stream error: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('Internal Server Error');
    } else {
      res.destroy();
    }
  }
  return true;
}
