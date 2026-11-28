#!/bin/sh
# Runs every mock test against the addon code in this repo. Lua 5.4 comes from the
# lua-language-server VS Code extension; set LUA to use another interpreter.
cd "$(dirname "$0")" || exit 1
LUA="${LUA:-$(ls -d "$HOME"/.vscode/extensions/sumneko.lua-*/server/bin/lua-language-server* 2>/dev/null | tail -1)}"
[ -n "$LUA" ] || { echo "no Lua found: set LUA"; exit 1; }
fail=0
run() {  # run <test> <addon file> [extra arg]
  out=$("$LUA" "$1.lua" "../$2" $3 2>&1)
  last=$(printf '%s\n' "$out" | tail -1)
  printf '%-34s %s\n' "$1 $3" "$last"
  [ "$last" = "ok" ] || { fail=1; printf '%s\n' "$out" | tail -15; }
}
for t in upkeep_test upkeep_food_test upkeep_bag_test upkeep_shaman_test upkeep_redgill_test \
         upkeep_rest_test upkeep_count_test upkeep_loading_test; do
  run "$t" Upkeep/Upkeep.lua
done
run upkeep_count_test Upkeep/Upkeep.lua info
run upkeep_loading_test Upkeep/Upkeep.lua nocache
run upkeep_loading_test Upkeep/Upkeep.lua nospell
run upkeep_selfbuff_test Upkeep/Upkeep.lua mage
run upkeep_selfbuff_test Upkeep/Upkeep.lua paladin
run tandem_buff_test Tandem/Tandem.lua
run threatgap_fury_test ThreatGap/ThreatGap.lua
run tq_test TrinketQueue/TrinketQueue.lua
run aqm_offmap_test AvailableQuestsMap/Map.lua
run aqm_offmap_test AvailableQuestsMap/Map.lua onshow
run link_test TalentPath/Link.lua
run link_sync_test SyndicatorSync
run bobber_test Bobber/Bobber.lua
exit $fail
