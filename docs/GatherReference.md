# GatherReference
Shows Wowhead's herb, ore and treasure node locations on the world map and minimap, read-only.

## Files
- `GatherReference.lua`: everything at runtime. It has the `types` table (Herb, Mine, Fish, Treasure, each with its data global and ring colour), `LoadData`, `DecodeLoc`, `NodeInfo` and `ShowTooltip`. The world map part is `WorldMapDataProvider` and `GatherReferenceWorldMapPinMixin`. The minimap part is `AcquireMiniPin`, `SetMiniPinCircle`, `PlaceMiniPin`, `UpdateMiniMap` (full rescan) and `UpdateIconPositions` (move only). Then come `AddFilterMenuEntries` and startup.
- `GatherReference.xml`: `GatherReferenceWorldMapPinTemplate`, 12x12.
- `Nodes.lua`: generated. `ns.nodes[type][nodeID] = { name, texture }`. It holds names and icons only, no locations.
- `Artwork/`: node icons and `track_circle.tga`, copied from GatherMate2. `Libs/`: LibStub, CallbackHandler, HereBeDragons-2.0, also copied from GatherMate2.
- `tools/update_data.py`: regenerates `Nodes.lua` and copies the artwork and libs.

## How it works
- Locations come from the separate GatherMate2_Data addon, which is not in this repo. It is LoadOnDemand, has `Dependencies: GatherMate2`, and its `Forever\*Data.lua` files define `GatherMateData2{Herb,Mine,Fish,Treasure}DB = { [uiMapID] = { [coord] = nodeID } }`. That addon is built by the user's Rust Wowhead scraper in `~/Documents/git/gathermate2_data_wowhead`, from wowhead.com/forever object pages.
- At ADDON_LOADED, `LoadData` calls `LoadAddOn("GatherMate2_Data")` and keeps its own references to those globals. GatherMate2's import clears them, so the references are what survive. Types with no data are dropped. Forever's FishData is empty, so only three types show.
- `DecodeLoc`: x = `floor(id/1e6)/1e4`, y = `floor(id%1e6/100)/1e4` (GatherMate2's coord format).
- World map: a MapCanvas data provider acquires one pin per node for the shown `uiMapID`. Pins take hover but let clicks through. The tooltip lists every pin under the cursor.
- Minimap: an OnUpdate does a full `UpdateMiniMap` every 2 s, or when `forceUpdate` is set (zone change, zoom, CVar change). That pass covers nodes within 2 minimap view radii. Otherwise `UpdateIconPositions` only moves the existing pins. Nodes within 100 yd draw as a ring tinted with the type's colour, like GatherMate2. It handles `rotateMinimap` and `GetMinimapShape`, and pins slide along the edge and fade out.
- Events: ADDON_LOADED, PLAYER_ENTERING_WORLD, MINIMAP_UPDATE_ZOOM, CVAR_UPDATE, and HereBeDragons' `PlayerZoneChanged` callback.

## Interface
- Saved variable `GatherReferenceDB[typeKey] = bool`, default true. Toggles are under "Gathering Nodes" in the world map's filter menu (`Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING")`).
- OptionalDeps GatherMate2. No slash commands.

## Decisions (keep)
- Read-only: nothing is imported into GatherMate2's database or into saved variables. The data is loaded fresh from GatherMate2_Data at every login.
- `GatherReferenceWorldMapPinMixin.SetPassThroughButtons` is a no-op on purpose. It avoids tainting the map in combat, the same workaround GatherMate2 uses.

## Gotchas
- GatherMate2 must be installed and enabled even though the toc lists it only as optional. Without it GatherMate2_Data won't load, and the addon prints the load failure.
- If GatherMate2 has already imported and cleared the globals, the addon prints a /reload hint.
- `update_data.py` hard-codes the `_classic_beta_` install paths for `GM`, `DATA` and `OUT`, from before the repo move. Point `OUT` at this repo folder, and `GM` and `DATA` at the `_forever_` installs, before running it.
- `update_data.py` crashes on a node with no texture: it prints "missing tex", then the next line raises on `None`. A node with no name becomes "Unknown N".
- After the data repo adds new node IDs, rerun `update_data.py`. Otherwise those nodes show "Unknown node N" with a question-mark icon.

## Open
- No test file.
