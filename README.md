# ForeverAddons

Small one-off World of Warcraft addons, mostly for WoW: Forever. Each folder is one addon, apart from `docs` (notes for working on the code, with [CLAUDE.md](CLAUDE.md)) and `tests` (mock tests run outside the game).

| Addon | What it does |
| --- | --- |
| [AvailableQuestsMap](AvailableQuestsMap) | Puts a "!" on the world map wherever a quest giver has a quest you can pick up right now and lists those quests in the giver's tooltip, using QuestieDB's data. |
| [Bobber](Bobber) | Lets you fish with the jump key: with a fishing pole in hand and standing still, it casts Fishing and then reels in the catch. Moving, swimming or in combat it jumps as usual. With Upkeep, a clickable reminder to put a lure on the pole. |
| [CombinedBagOrder](CombinedBagOrder) | Keeps your last bag sort at the bottom of Blizzard's combined bag so new loot fills in from the top, and adds a bank button that shows any character's saved bank from Syndicator in a copy of the bank window. |
| [GatherReference](GatherReference) | Shows Wowhead's herb, ore and treasure node locations on the world map and minimap. |
| [PartyOrder](PartyOrder) | Reorders Blizzard's raid-style party frames when you hold Ctrl+Alt and drag one party member onto another. |
| [SyndicatorSync](SyndicatorSync) | Shares Syndicator's inventory data between two paired accounts in real time, for dual-boxing. |
| [TalentPath](TalentPath) | Follows a Wowhead talent order: paste a talent calculator link for each spec and the talent window marks the next talents to take, going by points spent rather than level. It warns you instead if your talents leave the order. With Upkeep, the next talent also shows as a reminder. |
| [Tandem](Tandem) | Helps you dual-box: sets of your characters on different accounts find each other at login, group up, switch to free-for-all loot and turn the sound off on all but the main. With Upkeep it adds clickable reminders to focus the main and to cast a login spell such as a stance. |
| [ThreatGap](ThreatGap) | Shows threat on enemy nameplates: a coloured strip on every mob and your exact threat lead or headroom on your target, with tank and non-tank views. |
| [TrinketQueue](TrinketQueue) | Shows your two trinket slots in a small frame of their own. A click or a key binding uses a trinket, and hovering a slot shows an arrow that lists the trinkets in your bags in a column going up: the one you pick goes on as soon as you're out of combat. Shift-drag to move. |
| [Upkeep](Upkeep) | Shows a duration bar for a Paladin's seal and reminds you of missing blessings, weapon enchants, class self-buffs, Find Minerals or Find Herbs, and below the level cap of food that adds experience and a Cozy Sleeping Bag. A click on a reminder casts what's missing, and each shows its tooltip; in inns and cities, and while mounted, they stay hidden. Other addons can add reminders to its row. |

## Installing

The game loads the addons straight from this repo through directory junctions, so there is only one copy to edit. To add one, run this in a Command Prompt with your own paths:

```bat
mklink /J "<WoW folder>\_forever_\Interface\AddOns\Upkeep" "<this repo>\Upkeep"
```

CombinedBagOrder also works on retail; link it into `_retail_\Interface\AddOns` the same way.

## License

MIT; see [LICENSE](LICENSE). The libraries bundled in `Libs` folders (LibStub, CallbackHandler, HereBeDragons) keep their own licenses.
