# Connecting ultragateway to Poke

[Poke](https://poke.com) is an AI agent (reachable via Apple Messages, Telegram, WhatsApp, and RCS) that can call tools exposed by MCP servers. ultragateway runs **cua-driver** locally and exposes it over HTTPS via a tunnel so Poke (cloud-hosted) can reach your laptop.

## What you need

1. ultragateway installed (`./install.sh`)
2. A tunnel provider configured in `config.env` (default: Tailscale Funnel)
3. A Poke account at [poke.com](https://poke.com)

## Step 1 — Install and start ultragateway

```bash
chmod +x install.sh uninstall.sh scripts/*.sh
./install.sh
```

Confirm the gateway is running:

```bash
launchctl print "gui/$(id -u)/com.ultragateway.em"
curl -sI "http://127.0.0.1:8000/sse" | head -1
```

## Step 2 — Get your public MCP URL

After the tunnel starts, the URL Poke needs is written to:

```text
~/Library/Application Support/ultragateway/public-mcp-url.txt
```

Example:

```text
https://your-mac.your-tailnet.ts.net/sse
```

Also logged in:

```text
~/Library/Logs/ultragateway/tunnel.log
```

Quick copy:

```bash
cat ~/Library/Application\ Support/ultragateway/public-mcp-url.txt
```

**Important:** Poke requires **HTTPS**. The URL must end with `/sse` (Supergateway’s SSE transport).

## Step 3 — Add the MCP server in Poke (recommended: web UI)

The most reliable way to register a server:

1. Open **[poke.com/integrations/new](https://poke.com/integrations/new)**
2. **Name:** `CUA Driver` (or any label)
3. **MCP Server URL:** paste the value from `public-mcp-url.txt`
   - Example: `https://your-mac.your-tailnet.ts.net/sse`
4. **API Key:** leave empty (cua-driver does not use API key auth through Supergateway)
5. Click **Create Integration**

Poke connects, discovers tools, and syncs them automatically. You can re-sync anytime from the integrations page.

### Prefilled link (optional)

Share setup with a link that pre-fills the form:

```text
https://poke.com/integrations/new?name=CUA%20Driver&url=https://your-mac.your-tailnet.ts.net/sse
```

## Alternative registration methods

### Poke CLI (`poke mcp add`)

If the CLI works for you:

```bash
npx poke@latest mcp add "https://your-mac.your-tailnet.ts.net/sse" -n "CUA Driver"
```

### Poke built-in tunnel (usually not needed here)

Poke’s own tunnel forwards a **local** port to Poke — useful when you run the MCP server manually:

```bash
npx poke@latest tunnel http://localhost:8000/sse -n "CUA Driver"
```

ultragateway already runs Supergateway + its own tunnel, so you typically **paste the public URL in the web UI** instead of using `poke tunnel`.

## Verify in Poke

After creating the integration:

1. Open Poke (Messages / Telegram / etc.)
2. Ask something that uses computer control, e.g. “What apps are running on my Mac?”
3. If tools fail, open [poke.com integrations](https://poke.com) and check the integration status or trigger a tool re-sync

## Troubleshooting

| Issue | Fix |
|-------|-----|
| No `public-mcp-url.txt` | Check `TUNNEL_PROVIDER` in `config.env`; see tunnel logs |
| Poke says “invalid server url” | Usually a broken Supergateway npm install — POST fails while GET `/sse` still works. Run `./install.sh` then restart gateway |
| Poke can’t connect | Confirm URL is HTTPS and includes `/sse` |
| URL changed after restart | Use Tailscale Funnel (stable per machine) or ngrok reserved domain |
| Tools empty | Re-sync on integrations page; restart gateway |
| cua-driver permissions | Run `cua-driver permissions grant` |

Restart services:

```bash
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em"
launchctl kickstart -k "gui/$(id -u)/com.ultragateway.em.tunnel"
```

## References

- [Poke MCP Servers docs](https://poke.com/docs/mcp-servers)
- [Managing Integrations](https://poke.com/docs/managing-integrations)
- [poke CLI (npm)](https://www.npmjs.com/package/poke)
