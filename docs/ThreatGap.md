# ThreatGap
Threat on enemy nameplates: a coloured strip on every mob, and your exact threat lead or headroom on your target, focus and mouseover. There are tank and non-tank views.

## Files
- `ThreatGap.lua`: everything. Role detection (`DetectTank`, `RefreshRole`). The group (`others`, `RebuildGroup`). The number (`Threat`, `Gap`, `ReadableUnit`, `PlateNumber`, `FormatNumber`). The strips (`NewBar`, `NewDangerBar`, `TankParts`/`TankSet`, `DpsParts`, `FeedBar`, `UpdateTankStrip`, `UpdateDpsStrip`). Widgets (`AcquireWidget`, `ReleaseWidget`, `Update`, `SafeUpdate`, `UpdateAll`). Then the `driver` timer, `handlers`, and `Diagnose` with the slash command. The header comment is the colour spec.

## How it works
- NAME_PLATE_UNIT_ADDED: on attackable mobs, or when `UnitCanAttack` is secret, it attaches a pooled widget to the plate. The widget is a 3 px strip inside the bottom of the health bar, plus a number left of the bar. NAME_PLATE_UNIT_REMOVED releases it.
- Strips: StatusBars stacked by frame level. Values come straight from `UnitDetailedThreatSituation(x, "nameplateN")` and go into `bar:SetValue` (pcall'd, counted in `barStats`), so they work while secret. Aggro bars have range 1–2, so status 2 or 3 shows full. The on-list bar has range 0–0.001. The orange danger bar covers the last 10% of the width with range 90–100.
- Tank view (party only; in raids only your own aggro bar shows): your aggro in green, then yellow, orange and blue bars for each party member and pet. The non-tank view uses only your own threat, so it works in raids.
- Number: `ReadableUnit` tries the plate token, then "target", "focus" and "mouseover" matched with `UnitIsUnit`. `Gap` is your threat minus the highest in `others`. A non-tank without aggro instead sees `-(mine*100/scaled - mine)`: the threat left before pulling.
- Role: "auto" checks form IDs 5, 8 and 18, form spells 71, 5487 and 9634, and the Righteous Fury aura 25780 (pcall'd). Every `UpdateAll` re-checks it.
- Timer: the `driver` OnUpdate refreshes everything every 0.25 s while in combat, for 5 s after, or while any plate shows a number. Events also trigger refreshes: UNIT_THREAT_LIST_UPDATE, target, focus and mouseover changes, GROUP_ROSTER_UPDATE, UNIT_PET, UPDATE_SHAPESHIFT_FORM, and PLAYER_REGEN_ENABLED/DISABLED.

## Interface
- `/threatgap tank|dps|auto` sets the view. Anything else runs `Diagnose`, which prints the view, plate counts, bar stats, the last error and the target's threat table.
- Per-character saved variable `ThreatGapCharDB.role`.

## Decisions (keep)
- Strips on every mob, but numbers only where threat reads plain (target, focus, mouseover). Never do arithmetic or comparisons on nameplate-token threat.
- The pull threshold comes from the client's scaled percent, which already includes the 110% melee / 130% ranged rule. Don't add it again.
- Threat values are plain threat, not hundredths. Don't divide by 100.

## Gotchas
- Confirmed in game: threat via "nameplateN" is secret even in the open world, while the same mob as "target", "focus" or "mouseover" is plain. `UnitIsUnit("nameplateN","target")` and `UnitName` stay plain. Threat via "party1target" is secret, and `UnitIsUnit("nameplateN","party1target")` returns nil, so group targets can't stand in.
- `Gap` returns false (no number) if any one group member's threat is hidden.
- The event dispatcher drops any event whose first argument is secret. Events are registered through pcall, because an unknown event raises an error.
- `GetNamePlateForUnit` returns nil for plates addons may not touch.
- Errors are caught per plate in `SafeUpdate`; only the first is printed.

## Open
- Not built: sharing each client's target threat table over party addon messages, matched by `UnitGUID` (plain in the open world), so a party member's target could show a number. The code has no comms and no GUID use.
- No test file.
