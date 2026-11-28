# CraftTimers
Profession cooldowns for every character on both accounts, behind a minimap button that flashes while something is ready and unseen; a click lists them with time left. Built 2026-11-28 as the second AccountLink dataset.

## Files
- `CraftTimers.lua`: the whole addon.
  - Tables: `ITEMS` (item id → profession: Salt Shaker 15846), `SPELLS` (`{id, name, profession}`: Dedicated Study 1225469).
  - Recording: `OwnProfession`, `RecipeIDs`, `Label`, `ScanRecipes`, `ScanItems`, `KnownSpell`, `ScanSpells`, `Soon` (debounce per function), `EndsIn`, `ReadyEnds`, `Put`, `Unwrap`, `Remaining`.
  - Seen state: `ReadyUnseen`, `SeeAll`. UI: `button` (`CraftTimersMinimapButton`), `glow` + `pulse`, `list` (`CraftTimersList`, a GameTooltip), `Place`, `FillList`, `Refresh`, `Toggle`. `Debug`.
- Test: `tests/crafttimers_test.lua` (asserts; AccountLink stubbed).

## How it works
- Records: `CraftTimersDB.characters[key] = {name, class, cds}`, key "First Surname" (`FullName`). `cds[id] = {n, i, e, p, m}`: name, icon, server time ready (`GetServerTime`), profession, recipe ids (recipe lines only). `e = 0`: a line never seen cooling down. Ids: `r<lowest recipe id>`, `i<item id>`, `s<spell id>`.
- Recipes: `TRADE_SKILL_SHOW`/`TRADE_SKILL_LIST_UPDATE` (0.5 s debounce) and 1.5 s after `UNIT_SPELLCAST_SUCCEEDED` → `ScanRecipes`, only for your own profession (not linked, guild, guild member, NPC; not while the data source is changing). Every learned recipe from `GetAllRecipeIDs` (`GetFilteredRecipeIDs` as a fallback, then nothing is removed): `GetRecipeCooldown` ≥ `MIN_COOLDOWN` (2 h) counts, unless it has charges left. Recipes ending within `SHARED_WINDOW` (5 s) of each other share a cooldown → one line, labelled by the common name before ":" ("Transmute"). An existing line overlapping the group keeps its id (others merge in). Lines whose recipes are all unlearned go (complete list only); a line still in the future with none of its recipes cooling down becomes ready now (ended early).
- Items (`ScanItems`, 5 s after entering the world, 1 s after `BAG_UPDATE_COOLDOWN`/`BAG_UPDATE_DELAYED`) and spells (`ScanSpells`, same plus `SPELL_UPDATE_COOLDOWN`, `PLAYER_REGEN_ENABLED`; skipped in combat): whenever the character has them, cooling (≥ 2 h) or ready. `KnownSpell` tries the id, then the spell by name. Not in the bags / not known: the line is left as it was.
- `EndsIn` keeps the recorded end when a new reading is within `SAME_END` (60 s), so repeated reads don't send anything. `ReadyEnds`: unchanged once past, now if it ended early, 0 if never seen.
- `Unwrap`: seconds left above 2^31 ms are 2^32 ms too high (GetTime wraps; the start of a cooldown from before a PC restart comes back late) → subtract.
- Every change → `AccountLink.Changed("crafttimers", key)` and `Refresh`.
- Seen: `db.acks[key][id] = e` seen ready. `ReadyUnseen` = some line with `e <= now` and no matching ack → `glow` shown and `pulse` playing (alpha bounce 0.1 to 1, 0.7 s). A click (or `/ct`) → `SeeAll` rebuilds acks from every ready line, toggles the list. A new cooldown has a new `e`, so it flashes again when it ends. Acks are per account: each client's button needs its own click.
- `Refresh` every second (ticker): flash state, and the list while shown. The list: "Profession cooldowns", per character with lines (you first, then by key): class-coloured name, then lines by end time, "Ready" in green or time left ("1d 4h", "3h 12m", "45m", "<1m").
- Button: standard minimap look (tracking border, background, pocket watch icon, zoom-button highlight), dragged around the edge (`db.minimap.angle`, radius = minimap width / 2 + 5), hover tooltip while the list is hidden.

## Interface
- `/ct` or `/crafttimers`: the list (like a click). `/ct minimap` hides or shows the button, `/ct reset` clears this character's lines, `/ct debug` prints the API it found, the open profession's recipes with a cooldown (raw readings and charges), Dedicated Study and the Salt Shaker raw cooldowns, and this character's lines.
- `CraftTimersDB` (account): `characters`, `acks`, `minimap = {angle, hide}`, `link` (AccountLink's `owned`/`mirrors`).
- AccountLink (`OptionalDeps`): `Register("crafttimers", {state = db.link, Store = db.characters, CurrentKey = meKey, Valid = has cds, OnMirrored = Refresh})`. Without it, characters on the same account still show (the saved variables are account-wide).

## Decisions (keep)
- The user asked for a minimap icon that opens a list and flashes until clicked once; no Upkeep reminder, no chat alerts. Name chosen by the user.
- Generic detection (any learned recipe on a 2 h+ cooldown), not a recipe list: catches Forever-only recipes (Transmute: Legionite) without data. A recipe shows from its first cooldown on. Items and spells that aren't recipes are listed (`ITEMS`, `SPELLS`).
- 2 h minimum: Forever cut Iron to Gold and Mithril to Truesilver to 1 hour; those would flash all day.
- Dedicated Study (Forever legacy Professions talent, 23 h) was asked for by the user: tracked whenever the character has it.
- Written from scratch; Crafter's Journal (installed, Forever) only taught the mechanism: GetRecipeCooldown is reliable only with its profession open, and the GetTime wrap.

## Forever facts (from guides, 2026-11-28; not all checked in game)
- Cooldowns: Transmute: Arcanite 47 h (17187), essence transmutes 23 h (17559–17566), Iron to Gold and Mithril to Truesilver 1 h (11479, 11480), Transmute: Legionite 47 h (1317279, Forever-only), Mooncloth 95 h (18560), Salt Shaker about 71 h (item 15846; may sit on the character), Dedicated Study 23 h (1225469). Whether Arcanite and the essence transmutes share one cooldown is unconfirmed; the grouping handles either.

## Open
- Confirmed in game 2026-11-28: the Salt Shaker and Dedicated Study lines, the minimap button and the list. Not yet checked: recipe cooldowns (the user has no cooldown recipes yet); when one comes, check `/ct debug` with the profession open (`GetRecipeCooldown`, `GetAllRecipeIDs`, the shared-transmute grouping).
- No way to remove a single line besides `/ct reset`.
