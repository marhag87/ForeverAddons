# Available Quests Map

Puts a yellow **!** on the world map wherever a quest giver has a quest you can pick up right
now. Hover an icon to see the giver and their quests.

Hovering a quest giver in the world lists the quests you can pick up from them, with level and
name, in their tooltip. It uses the same filters as the map icons (`/aqm tooltip` turns it off).

Quests that start from an item get a **!** with the item's icon in the corner, placed where the
item drops (one icon per area, not per mob). The tooltip shows the item, the quest it starts and
who drops it.

## Requirements

- **QuestieDB** must be enabled. Questie itself is not needed and can be disabled.
- Only QuestieDB's public API is used (`LibQuestieDB.RequireContract(4)`, the `Quest`/`Npc`/
  `Object` entities, `Enum`, and `Support.Get("ZoneDB")`). Nothing is read from Questie's files,
  so Questie updates don't affect this addon.
- The HereBeDragons map-pin libraries in `Libs/` were copied from GatherMate2.

## What counts as available

The quest is not completed and not in your log; your race and class match; you meet the level
requirement and it isn't gray (unless you turn that on); its prerequisite, exclusive, breadcrumb
and follow-up rules pass; and you meet any profession, reputation and spell requirement. The quest
giver must be an NPC or object that isn't hostile to your faction.

## Map menu

The world map's filter button (the "Show:" menu at the top right of the map) has an
**Available Quests** section with checkboxes for **Continent Maps**, **Holiday Quests** and
**PvP Quests**.

PvP quests are those QuestieDB files under the Battlegrounds category or a battleground zone
(Alterac Valley, Warsong Gulch, Arathi Basin). World PvP objectives in open zones count as normal
quests.

## Commands

| Command | Effect |
| --- | --- |
| `/aqm` | Status and help |
| `/aqm toggle` | Turn the map icons on or off |
| `/aqm trivial` | Also show low-level (gray) quests |
| `/aqm repeatable` | Show or hide repeatable quests (blue !) |
| `/aqm events` | Also show holiday and world event quests |
| `/aqm items` | Show or hide quests started by items |
| `/aqm pvp` | Show or hide battleground quests |
| `/aqm continent` | Show or hide icons on continent maps (on by default, drawn at 75% size) |
| `/aqm ids` | Show quest IDs in tooltips |
| `/aqm tooltip` | Show or hide quests in quest giver tooltips |
| `/aqm ignore <id>` / `unignore <id>` / `ignored` | Hide a quest that shows up but isn't really available |
| `/aqm size <8-40>` | Icon size |

## Known limits

- QuestieDB has no list of removed or unavailable quests (Questie keeps that list), so a few
  quests that aren't in the game may get an icon. Use `/aqm ids` and `/aqm ignore <id>` to hide them.
- Holiday quests are hidden all year; the addon doesn't check which events are running.
- Item-started quests only appear when QuestieDB knows who drops or sells the item. Items that
  come out of containers (clams, lockboxes) or that you're simply given have nowhere to go on the
  map. World drops from more than 20 kinds of mob are skipped, as they'd cover the map.
- Quests that need a profession specialization (for example Gnomish Engineering) are hidden.
