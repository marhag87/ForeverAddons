# ForeverAddons

Small one-off World of Warcraft addons, mostly for WoW: Forever. Each folder is one addon.

| Addon | What it does |
| --- | --- |
| [AvailableQuestsMap](AvailableQuestsMap) | Puts a "!" on the world map wherever a quest giver has a quest you can pick up right now and lists those quests in the giver's tooltip, using QuestieDB's data. |
| [CombinedBagOrder](CombinedBagOrder) | Keeps your last bag sort at the bottom of Blizzard's combined bag so new loot fills in from the top, and adds a bank button that shows any character's saved bank from Syndicator in a copy of the bank window. |
| [GatherReference](GatherReference) | Shows Wowhead's herb, ore and treasure node locations on the world map and minimap. |
| [PartyOrder](PartyOrder) | Reorders Blizzard's raid-style party frames when you hold Ctrl+Alt and drag one party member onto another. |
| [SyndicatorSync](SyndicatorSync) | Shares Syndicator's inventory data between two paired accounts in real time, for dual-boxing. |
| [ThreatGap](ThreatGap) | Shows threat on enemy nameplates: a coloured strip on every mob and your exact threat lead or headroom on your target, with tank and non-tank views. |
| [Upkeep](Upkeep) | Shows a duration bar for a Paladin's seal and reminds you of missing blessings, weapon enchants, class self-buffs and Find Minerals or Find Herbs. Other addons can add clickable reminders to its row. |

## Installing

The game loads the addons straight from this repo through directory junctions, so there is only one copy to edit. To add one, run this in a Command Prompt with your own paths:

```bat
mklink /J "<WoW folder>\_forever_\Interface\AddOns\Upkeep" "<this repo>\Upkeep"
```

CombinedBagOrder also works on retail; link it into `_retail_\Interface\AddOns` the same way.

## License

MIT; see [LICENSE](LICENSE). The libraries bundled in `Libs` folders (LibStub, CallbackHandler, HereBeDragons) keep their own licenses.
