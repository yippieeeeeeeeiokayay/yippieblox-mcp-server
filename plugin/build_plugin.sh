#!/usr/bin/env bash
# build_plugin.sh — Generates YippieBlox.rbxmx from the Lua source files.
# The .rbxmx file can be placed directly in Studio's Plugins folder.
#
# Usage: cd plugin && ./build_plugin.sh
# Output: plugin/YippieBlox.rbxmx
#
# Instance hierarchy produced:
#   YippieBlox (Script)              ← init.server.lua
#     bridge (ModuleScript)          ← bridge.lua
#     tools (ModuleScript)           ← tools/init.lua (router)
#       run_script (ModuleScript)
#       checkpoint (ModuleScript)
#       playtest (ModuleScript)
#       logs (ModuleScript)
#       virtualuser (ModuleScript)
#       npc_driver (ModuleScript)
#       capture (ModuleScript)
#     ui (Folder)
#       widget (ModuleScript)
#       command_trace (ModuleScript)
#     util (Folder)
#       ring_buffer (ModuleScript)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/YippieBlox"
OUT="$SCRIPT_DIR/YippieBlox.rbxmx"

REF_COUNTER=0
next_ref() {
    REF_COUNTER=$((REF_COUNTER + 1))
    echo "RBX${REF_COUNTER}"
}

# Read a file and wrap in CDATA for XML embedding
cdata_file() {
    local file="$1"
    # Replace any ]]> in source with ]] > to avoid breaking CDATA
    sed 's/]]>/]] >/g' "$file"
}

# ─── Build ─────────────────────────────────────────────────

{
cat <<'HEADER'
<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
HEADER

# ── Root: YippieBlox (Script) ──
echo "  <Item class=\"Script\" referent=\"$(next_ref)\">"
echo "    <Properties>"
echo "      <string name=\"Name\">YippieBlox</string>"
echo "      <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/init.server.lua"
echo "]]></ProtectedString>"
echo "      <token name=\"RunContext\">0</token>"
echo "    </Properties>"

# ── bridge (ModuleScript) ──
echo "    <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
echo "      <Properties>"
echo "        <string name=\"Name\">bridge</string>"
echo "        <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/bridge.lua"
echo "]]></ProtectedString>"
echo "      </Properties>"
echo "    </Item>"

# ── tools (ModuleScript with children) ──
echo "    <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
echo "      <Properties>"
echo "        <string name=\"Name\">tools</string>"
echo "        <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/tools/init.lua"
echo "]]></ProtectedString>"
echo "      </Properties>"

# Tool handler children
for tool_file in "$SRC/tools/"*.lua; do
    fname=$(basename "$tool_file" .lua)
    [ "$fname" = "init" ] && continue
    echo "      <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
    echo "        <Properties>"
    echo "          <string name=\"Name\">${fname}</string>"
    echo "          <ProtectedString name=\"Source\"><![CDATA["
    cdata_file "$tool_file"
    echo "]]></ProtectedString>"
    echo "        </Properties>"
    echo "      </Item>"
done

echo "    </Item>"  # close tools

# ── ui (Folder with children) ──
echo "    <Item class=\"Folder\" referent=\"$(next_ref)\">"
echo "      <Properties>"
echo "        <string name=\"Name\">ui</string>"
echo "      </Properties>"

for ui_file in "$SRC/ui/"*.lua; do
    fname=$(basename "$ui_file" .lua)
    echo "      <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
    echo "        <Properties>"
    echo "          <string name=\"Name\">${fname}</string>"
    echo "          <ProtectedString name=\"Source\"><![CDATA["
    cdata_file "$ui_file"
    echo "]]></ProtectedString>"
    echo "        </Properties>"
    echo "      </Item>"
done

echo "    </Item>"  # close ui

# ── util (Folder with children) ──
echo "    <Item class=\"Folder\" referent=\"$(next_ref)\">"
echo "      <Properties>"
echo "        <string name=\"Name\">util</string>"
echo "      </Properties>"

for util_file in "$SRC/util/"*.lua; do
    fname=$(basename "$util_file" .lua)
    echo "      <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
    echo "        <Properties>"
    echo "          <string name=\"Name\">${fname}</string>"
    echo "          <ProtectedString name=\"Source\"><![CDATA["
    cdata_file "$util_file"
    echo "]]></ProtectedString>"
    echo "        </Properties>"
    echo "      </Item>"
done

echo "    </Item>"  # close util

echo "  </Item>"    # close root Script
echo "</roblox>"

} > "$OUT"

echo "Built: $OUT"
echo "Install: copy YippieBlox.rbxmx to your Studio Plugins folder"
echo "  macOS:   ~/Documents/Roblox/Plugins/"
echo "  Windows: %LOCALAPPDATA%\\Roblox\\Plugins\\"
