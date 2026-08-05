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

## Native MCP tools

The gateway runs a **composite MCP server** (`native-mcp/composite-server.mjs`) that proxies **cua-driver** tools and adds ultragateway-native tools:

| Tool | Description |
|------|-------------|
| `ultragateway_run_zsh` | Run a command in **zsh** on your Mac (stdout/stderr/exit code) |
| `ultragateway_notify` | Show a **macOS notification** branded as ultragateway |
| `ultragateway_share_file` | Copy a local file into an ephemeral share and return a public URL (default **10 min** expiry, **50MB** max) |
| `ultragateway_close_shares` | Immediately revoke **all** minted share links |

Notifications are delivered through the **menu bar app** (Notification Center with the ultragateway icon). If the menu bar app is not running, a system notification fallback is used.

**Ephemeral shares:** `ultragateway_share_file` takes a `path` argument, copies the file under `~/Library/Application Support/ultragateway/shares/<token>/`, and returns a URL like `{publicBase}/share/{token}/{filename}`. Links are only minted via this MCP tool (opaque tokens — not raw filesystem paths). Public base comes from `public-base-url.txt` / `public-mcp-url.txt`, else `http://127.0.0.1:$SUPERGATEWAY_PORT`. Re-sharing the same path returns the existing URL when more than **5 minutes** remain; otherwise the old share is revoked and a new one is minted. Call `ultragateway_close_shares` to revoke every active share immediately (existing URLs start returning 404).

Configure in `config.env`:

```bash
NATIVE_SHELL_ENABLED=1          # set 0 to disable shell tool
NATIVE_SHELL_TIMEOUT=30         # default timeout (seconds)
NATIVE_SHELL_TIMEOUT_MAX=300    # hard cap
NATIVE_NOTIFY_ENABLED=1         # set 0 to disable notify tool
SHARE_TTL_SECONDS=600           # share link lifetime (default 10 minutes)
SHARE_MAX_BYTES=52428800        # max share size (default 50MB)
```

**Security:** `ultragateway_run_zsh` executes arbitrary shell commands on your machine. Only connect trusted remote agents (Poke, etc.) to your tunnel URL. Share links are unguessable but publicly fetchable once minted — treat them like temporary secrets.

### API key protection (optional)

When your MCP URL is exposed via Tailscale Funnel or another public tunnel, you can require `Authorization: Bearer <api_key>` on every HTTP request to the MCP surface (SSE, POST `/message`, streamable HTTP, WebSocket upgrade).

Default is **off**. Enable and manage the key in the menu bar app **Settings → Security**, or edit `config.env`:

```bash
API_KEY_PROTECTION_ENABLED=true
API_KEY=your-generated-key
```

When protection is off, `API_KEY` should be empty and no Bearer header is required.

Test locally:

```bash
# protection off (default)
curl -sI "http://127.0.0.1:8000/sse" | head -1

# protection on
curl -sI -H "Authorization: Bearer YOUR_KEY" "http://127.0.0.1:8000/sse" | head -1
curl -sI "http://127.0.0.1:8000/sse" | head -1   # HTTP/1.1 401 Unauthorized
```

In Poke, paste the same key into the **API Key** field when creating the integration.

After changing protection settings, restart the gateway:

```bash
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em"
```

## Auto-updates

When enabled, LaunchAgent `com.ultragateway.em.update` checks GitHub every **6 hours** (configurable) and runs `install.sh` if `main` has new commits.

```bash
AUTO_UPDATE_ENABLED=1
AUTO_UPDATE_INTERVAL=21600    # seconds (6h)
AUTO_UPDATE_BRANCH=main
GITHUB_REPO_URL=https://github.com/embeputer/ultragateway.git
```

`install.sh` records your clone path in `repo.env`. If you only have the app bundle, auto-update clones into `~/Library/Application Support/ultragateway/source`.

Manual check: menu bar → **Check for Updates**, or:

```bash
~/Library/Application\ Support/ultragateway/auto-update.sh
tail -f ~/Library/Logs/ultragateway/update.log
```

Set `AUTO_UPDATE_ENABLED=0` and re-run `install.sh` to disable.

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
