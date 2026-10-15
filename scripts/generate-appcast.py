#!/usr/bin/env python3
"""Emit a Sparkle appcast.xml for the release described by env vars.

Required env:
  APP_SHORT_VERSION   marketing version, e.g. 1.1.0
  APP_BUILD_VERSION   integer build, e.g. git commit count
  RELEASE_TAG         git tag the release is published under, e.g. v1.1.0-96
  APP_ZIP             asset filename, e.g. ultragateway-1.1.0-96.zip
  ED_SIGNATURE        base64 EdDSA signature from sign_update
  ZIP_LENGTH          byte size of the app zip
  REPO                owner/name on GitHub
  APPCAST_OUT         output path (default: appcast.xml)
  RELEASE_NOTES_URL   optional URL for <sparkle:releaseNotesLink>
"""

import os
import sys
import xml.sax.saxutils as x
from datetime import datetime, timezone
from urllib.parse import quote

def need(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"error: {name} is required")
    return value

short = need("APP_SHORT_VERSION")
build = need("APP_BUILD_VERSION")
tag = need("RELEASE_TAG")
zip_name = need("APP_ZIP")
ed_sig = need("ED_SIGNATURE")
zip_len = need("ZIP_LENGTH")
repo = need("REPO")
out = os.environ.get("APPCAST_OUT", "appcast.xml")
notes_url = os.environ.get("RELEASE_NOTES_URL", "").strip()

enclosure_url = (
    f"https://github.com/{repo}/releases/download/"
    f"{quote(tag, safe='')}/{quote(zip_name, safe='')}"
)
pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")

notes = ""
if notes_url:
    notes = f"    <sparkle:releaseNotesLink>{x.escape(notes_url)}</sparkle:releaseNotesLink>\n"

doc = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ultragateway</title>
    <link>https://github.com/{x.escape(repo)}/releases</link>
    <description>ultragateway macOS app updates</description>
    <language>en</language>
    <item>
      <title>{x.escape(short)}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{x.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{x.escape(short)}</sparkle:shortVersionString>
{notes}      <enclosure
        url="{x.escape(enclosure_url)}"
        sparkle:edSignature="{x.escape(ed_sig)}"
        length="{x.escape(zip_len)}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
"""

with open(out, "w", encoding="utf-8") as f:
    f.write(doc)
print(f"wrote {out}")
