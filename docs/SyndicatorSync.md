# SyndicatorSync
Mirrors Syndicator's characters between two paired accounts while their characters are grouped, so each account's tooltips, search and bank view see the other's bags, bank, mail and gold live. Since 1.1.0 (2026-11-28) the pairing, sessions and messages live in AccountLink (see `docs/AccountLink.md`); this addon is the Syndicator side.

## Files
- `SyndicatorSync.lua`: the whole addon. `LooksLikeCharacter`, `NotifySyndicator`, `OnSyndicatorChange`, `OnReady` (registers the dataset), slash command.

## How it works
- `ADDON_LOADED` (own): `SyndicatorSyncDB` init; a pre-1.1.0 pairing (`accountId`, `partners`) goes to `AccountLink.Adopt` and is removed here, with the old `debug`.
- `PLAYER_LOGIN` → Syndicator `Ready` → `OnReady`: `AccountLink.Register("syndicator", { state = SyndicatorSyncDB, Store = SYNDICATOR_DATA.Characters, CurrentKey = Syndicator.API.GetCurrentCharacter, Valid = LooksLikeCharacter, OnMirrored = NotifySyndicator })`, then Syndicator's Bag/Mail/Equipped/Currency/Auctions/VoidCacheUpdate callbacks call `AccountLink.Changed`.
- Copies are written straight into `SYNDICATOR_DATA.Characters[key]` by AccountLink; `SyndicatorSyncDB.owned`/`mirrors` are kept by it.

## Interface
- `/ssync` (status: AccountLink's, then the copies held with their age), `pair <name>` and `unpair` (forwarded to AccountLink), `resync` (Syndicator data only), `forget` (`Syndicator.API.DeleteCharacter` on every mirror), `debug` (AccountLink's).
- `SyndicatorSyncDB` (account-wide): `owned[key]`, `mirrors[key] = {partner, rev, updated}`.
- Dependencies: Syndicator, AccountLink. Syndicator: `API.IsReady`, `GetCurrentCharacter`, `DeleteCharacter`, `CallbackRegistry` (`Ready` and the cache events), `SYNDICATOR_DATA.Characters`, fires `MailCacheUpdate(key)`. CombinedBagOrder's BankView refreshes on that event.
- Test: `tests/link_sync_test.lua` (see `docs/AccountLink.md`); `run link_sync_test SyndicatorSync` loads AccountLink through the .toc dependency.

## Decisions (keep)
- NEVER fire `BagCacheUpdate`/`EquippedCacheUpdate`/`CurrencyCacheUpdate` for a mirror; only `MailCacheUpdate(key)`, which Syndicator fires for non-live characters itself and treats as a full recount. Baganator takes `BagCacheUpdate` as the live character: it swapped a friend's bag window to the mirror and sorted the real bags by its layout (confirmed 2026-11-17, fixed in 1.0.1).
- 1.1.0 moved pairing, sessions and messages to AccountLink so other addons (a profession cooldown tracker next) can share data between the accounts without Syndicator. The slash commands stayed.

## Gotchas
- `NotifySyndicator`'s MailCacheUpdate comes back through `OnSyndicatorChange`; `AccountLink.Changed` skips it because the key is a mirror by then.

## Open
- 1.1.0 on AccountLink confirmed in game (2026-11-28): it links, keeps the copies, and loot shows on the other account. Both clients need the same version at once (the message prefix changed).
- Browsing mirrored banks in CombinedBagOrder looks done already: BankView lists every Syndicator character with bank data, mirrors included.
