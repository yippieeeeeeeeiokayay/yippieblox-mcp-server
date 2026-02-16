#!/usr/bin/env bash
# build_plugin.sh — Generates YippieBlox.rbxmx from the Lua source files.
# The .rbxmx file can be placed directly in Studio's Plugins folder.
#
# Usage: cd plugin && ./build_plugin.sh
# Output: plugin/YippieBlox.rbxmx
#
# Instance hierarchy produced:
#   YippieBlox (Folder)
#     main (Script)                  ← init.server.lua
#       bridge (ModuleScript)        ← bridge.lua
#       playtest_bridge_source (ModuleScript) ← returns Luau source for server-side bridge
#       tools (ModuleScript)         ← tools/init.lua (router)
#         run_script (ModuleScript)
#         checkpoint (ModuleScript)
#         playtest (ModuleScript)
#         logs (ModuleScript)
#         virtualuser (ModuleScript)
#         npc_driver (ModuleScript)
#         capture (ModuleScript)
#       ui (Folder)
#         widget (ModuleScript)
#         command_trace (ModuleScript)
#       util (Folder)
#         ring_buffer (ModuleScript)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/YippieBlox"
OUT="$SCRIPT_DIR/YippieBlox.rbxmx"

REF_FILE=$(mktemp)
echo 0 > "$REF_FILE"
trap 'rm -f "$REF_FILE"' EXIT

next_ref() {
    local n
    n=$(cat "$REF_FILE")
    n=$((n + 1))
    echo "$n" > "$REF_FILE"
    echo "RBX${n}"
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
  <External>null</External>
  <External>nil</External>
HEADER

# ── Root: YippieBlox (Folder) ──
echo "  <Item class=\"Folder\" referent=\"$(next_ref)\">"
echo "    <Properties>"
echo "      <string name=\"Name\">YippieBlox</string>"
echo "    </Properties>"

# ── main (Script — plugin entry point) ──
echo "    <Item class=\"Script\" referent=\"$(next_ref)\">"
echo "      <Properties>"
echo "        <string name=\"Name\">main</string>"
echo "        <bool name=\"Disabled\">false</bool>"
echo "        <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/init.server.lua"
echo "]]></ProtectedString>"
echo "      </Properties>"

# ── bridge (ModuleScript) ──
echo "      <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
echo "        <Properties>"
echo "          <string name=\"Name\">bridge</string>"
echo "          <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/bridge.lua"
echo "]]></ProtectedString>"
echo "        </Properties>"
echo "      </Item>"

# ── playtest_bridge_source (ModuleScript — returns source string for injection) ──
echo "      <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
echo "        <Properties>"
echo "          <string name=\"Name\">playtest_bridge_source</string>"
echo "          <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/playtest_bridge_source.lua"
echo "]]></ProtectedString>"
echo "        </Properties>"
echo "      </Item>"

# ── tools (ModuleScript with children) ──
echo "      <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
echo "        <Properties>"
echo "          <string name=\"Name\">tools</string>"
echo "          <ProtectedString name=\"Source\"><![CDATA["
cdata_file "$SRC/tools/init.lua"
echo "]]></ProtectedString>"
echo "        </Properties>"

# Tool handler children
for tool_file in "$SRC/tools/"*.lua; do
    fname=$(basename "$tool_file" .lua)
    [ "$fname" = "init" ] && continue
    echo "        <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
    echo "          <Properties>"
    echo "            <string name=\"Name\">${fname}</string>"
    echo "            <ProtectedString name=\"Source\"><![CDATA["
    cdata_file "$tool_file"
    echo "]]></ProtectedString>"
    echo "          </Properties>"
    echo "        </Item>"
done

echo "      </Item>"  # close tools

# ── ui (Folder with children) ──
echo "      <Item class=\"Folder\" referent=\"$(next_ref)\">"
echo "        <Properties>"
echo "          <string name=\"Name\">ui</string>"
echo "        </Properties>"

for ui_file in "$SRC/ui/"*.lua; do
    fname=$(basename "$ui_file" .lua)
    echo "        <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
    echo "          <Properties>"
    echo "            <string name=\"Name\">${fname}</string>"
    echo "            <ProtectedString name=\"Source\"><![CDATA["
    cdata_file "$ui_file"
    echo "]]></ProtectedString>"
    echo "          </Properties>"
    echo "        </Item>"
done

echo "      </Item>"  # close ui

# ── util (Folder with children) ──
echo "      <Item class=\"Folder\" referent=\"$(next_ref)\">"
echo "        <Properties>"
echo "          <string name=\"Name\">util</string>"
echo "        </Properties>"

for util_file in "$SRC/util/"*.lua; do
    fname=$(basename "$util_file" .lua)
    echo "        <Item class=\"ModuleScript\" referent=\"$(next_ref)\">"
    echo "          <Properties>"
    echo "            <string name=\"Name\">${fname}</string>"
    echo "            <ProtectedString name=\"Source\"><![CDATA["
    cdata_file "$util_file"
    echo "]]></ProtectedString>"
    echo "          </Properties>"
    echo "        </Item>"
done

echo "      </Item>"  # close util

echo "    </Item>"  # close main Script
echo "  </Item>"    # close root Folder
echo "</roblox>"

} > "$OUT"

echo "Built: $OUT"
echo "Install: copy YippieBlox.rbxmx to your Studio Plugins folder"
echo "  macOS:   ~/Documents/Roblox/Plugins/"
echo "  Windows: %LOCALAPPDATA%\\Roblox\\Plugins\\"
