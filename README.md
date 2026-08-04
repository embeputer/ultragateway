# ultragateway

Background macOS service that runs [Supergateway](https://github.com/supercorp-ai/supergateway) bridged to the [cua-driver](https://github.com/trycua/cua-driver) MCP server over STDIO. Exposes the local CUA MCP server over SSE (default) so remote clients — including [Poke](https://poke.com) — can connect via a public HTTPS tunnel.

Runs invisibly — no Dock icon — and starts automatically at login. Optional menu bar UI shows status and copies the Poke MCP URL.

## What it does

```
Poke (cloud)  →  Tunnel (HTTPS)  →  Supergateway (SSE :8000)  →  cua-driver mcp (STDIO)
```

- **LaunchAgents** — `com.ultragateway.em` (gateway) and `com.ultragateway.em.tunnel` (public URL); auto-start at login, restart on crash
- **ultragateway.app** — LSUIElement bundle in `/Applications` (no Dock icon); menu bar status when built
- **Public MCP URL** — `~/Library/Application Support/ultragateway/public-mcp-url.txt`
- **Logs** — `~/Library/Logs/ultragateway/`

## Connect to Poke

See **[POKE.md](POKE.md)** for step-by-step instructions:

1. `./install.sh`
2. Copy URL from `public-mcp-url.txt`
3. Paste at [poke.com/integrations/new](https://poke.com/integrations/new)

## Prerequisites

1. **Node.js** (v18+) with `npm` on PATH  
   ```bash
   brew install node
   ```

2. **cua-driver** — the CUA MCP server  
   ```bash
   # Install (macOS)
   /bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
   # Default path: ~/.local/bin/cua-driver -> /Applications/CuaDriver.app/Contents/MacOS/cua-driver
   ```

   Upgrade to the latest release:
   ```bash
   cua-driver update --apply
   cua-driver permissions grant   # re-grant if macOS prompts after the binary swap
   launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em"
   ```

3. **Tunnel provider** (pick one in `config.env`):
   - **Tailscale** (default, recommended) — `brew install tailscale` or [tailscale.com/download](https://tailscale.com/download)
   - **Cloudflare** — `brew install cloudflared`
   - **ngrok** — `brew install ngrok` + auth token

4. **macOS permissions** — grant Accessibility and Screen Recording to CuaDriver:
   ```bash
   cua-driver permissions grant
   ```

## Install

```bash
chmod +x install.sh uninstall.sh scripts/*.sh macos-app/build.sh
./install.sh
```

This installs gateway + tunnel LaunchAgents, copies scripts to Application Support, optionally builds the menu bar app, and registers a hidden login item.

## Configuration

Edit `~/Library/Application Support/ultragateway/config.env`:

```bash
CUA_DRIVER_BIN="/Users/you/.local/bin/cua-driver"
SUPERGATEWAY_PORT=8000
SUPERGATEWAY_OUTPUT_TRANSPORT=sse
TUNNEL_PROVIDER=tailscale   # tailscale | cloudflare | ngrok | none
TUNNEL_MCP_PATH=/sse
```

After changes, restart:

```bash
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em"
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em.tunnel"
```

## Tunnel recommendation

**Default: Tailscale Funnel** — best fit for this use case:

| Provider | Stable URL | Setup | Notes |
|----------|------------|-------|-------|
| **Tailscale Funnel** | Yes (`https://your-mac.tailnet.ts.net`) | Tailscale account + `tailscale funnel --bg` | Free, HTTPS, URL persists per machine |
| Cloudflare quick tunnel | No (random `trycloudflare.com`) | `brew install cloudflared` | Good fallback; URL changes on restart |
| ngrok | Paid for reserved domain | Auth token required | Fastest demo; free tier URLs change |

Poke needs a **stable HTTPS URL ending in `/sse`**. Tailscale Funnel gives that without buying a domain. Use Cloudflare named tunnels or ngrok reserved domains if you need a custom hostname.

## Endpoints

| Endpoint | URL |
|----------|-----|
| Local SSE | `http://127.0.0.1:8000/sse` |
| Public MCP (Poke) | contents of `public-mcp-url.txt` |

## Menu bar app

Built automatically during `install.sh` when `swift` is available. Shows gateway/tunnel status, public URL, copy-to-clipboard, and restart controls.

Manual build:

```bash
./macos-app/build.sh
./install.sh   # copies updated app bundle
```

## Usage

### Get Poke URL

```bash
cat ~/Library/Application\ Support/ultragateway/public-mcp-url.txt
```

### Check status

```bash
launchctl print "gui/$(id -u)/com.ultragateway.em"
launchctl print "gui/$(id -u)/com.ultragateway.em.tunnel"
```

### View logs

```bash
tail -f ~/Library/Logs/ultragateway/tunnel.log
tail -f ~/Library/Logs/ultragateway/stderr.log
```

### Restart

```bash
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em"
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em.tunnel"
```

### Manual run (debugging)

```bash
~/Library/Application\ Support/ultragateway/run-gateway.sh
~/Library/Application\ Support/ultragateway/run-tunnel.sh
```

### Uninstall

```bash
./uninstall.sh          # keeps config and logs
./uninstall.sh --purge  # removes everything
```

## Architecture

| Component | Path |
|-----------|------|
| App bundle | `/Applications/ultragateway.app` |
| App bundle ID | `com.ultragateway.em` |
| Run scripts | `~/Library/Application Support/ultragateway/` |
| Config | `~/Library/Application Support/ultragateway/config.env` |
| Public MCP URL | `~/Library/Application Support/ultragateway/public-mcp-url.txt` |
| Gateway LaunchAgent | `~/Library/LaunchAgents/com.ultragateway.em.plist` |
| Tunnel LaunchAgent | `~/Library/LaunchAgents/com.ultragateway.em.tunnel.plist` |
| Logs | `~/Library/Logs/ultragateway/` |

## Troubleshooting

**No public URL** — check tunnel provider installed, `TUNNEL_PROVIDER` in config, and `tunnel.log`.

**Tailscale Funnel fails on macOS** — App Store Tailscale supports port funneling; `--bg` may require the open-source variant. Run `tailscale funnel 8000` manually once to approve Funnel in the admin console.

**Service not starting** — check logs and PATH:

```bash
tail -50 ~/Library/Logs/ultragateway/stderr.log
which node npm cua-driver tailscale
```

Add missing bin dirs to `LAUNCHD_PATH_EXTRA` in `config.env`, then restart.

**Port in use** — change `SUPERGATEWAY_PORT` in config.env.

**Poke can't connect** — URL must be HTTPS with `/sse` path. Re-sync tools on poke.com integrations page.

**Upgrade cua-driver** — check and apply the latest release, then restart ultragateway:

```bash
cua-driver check-update          # read-only check
cua-driver update --apply        # download + install via canonical installer
cua-driver permissions grant     # only if permissions status shows missing grants
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em"
```
