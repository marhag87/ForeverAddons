# SyndicatorSync
Mirrors Syndicator's characters between two paired accounts while their characters are grouped, so each account's tooltips, search and bank view see the other's bags, bank, mail and gold live.

## Files
- `Util.lua`: `PREFIX` ("SynSync"), `Print`/`Debug`, `IsHidden`, `FullUnitName`, `Norm`, `CompleteName` (first name → full, party only), `RandomString`, `Hash` (two polynomial hashes kept below 2^31, as "a.b"), `ContentHash` (independent of pairs order), `Pack`/`Unpack` (`C_EncodingUtil` CBOR + compress + Base64), `Copy`, `Equal`, `Diff`/`Apply` (path change lists).
- `Comms.lua`: transport. `queues.control` before `queues.data`, sent by the `pump` OnUpdate; `outgoing` per peer, `incoming` reassembly, transfer `handlers` S/H/C/E/A/R, `FilterNotFound`. API: `SendControl`, `SendDocument(target, doc, onDone)`, `Forget`, `IsBusy`, `QueueLength`, `OnMessage`.
- `Sync.lua`: `InitDB`; sessions (`peers`, `peerIdByNorm`, `bootId`, `Ping`, `SendIntro`, `Proof`, `StartSession`/`EndSession`); sending (`shadows`, `dirty`, `Flush`, `SendSnapshot`, `QueueSnapshot`, `deferred`, `SendDeferred`, `CheckPeers`); `documents` handlers; pairing and pings (`ShowPairConfirm`, `control`); `NotifySyndicator`; slash command; `OnReady`.

## How it works
- `PLAYER_LOGIN` → `InitDB`, prefix, then Syndicator `Ready` → `OnReady`: current key into `db.owned` (and out of `db.mirrors`), callbacks on Syndicator's cache events, `Ping` at +3 s, every 60 s and 3 s after `GROUP_ROSTER_UPDATE`.
- `Ping` (PARTY, or INSTANCE_CHAT) runs only while a partner isn't connected. A paired account answers with a whispered `I` (5 s cooldown per name); a valid `I` → `StartSession` → `manifest`. Pairing itself is whispered, sessions need a group.
- `P` with the boot ID the session already has = crossed ping (both ping at login, Tandem groups them at once): keep the session, send `I` without reply wanted. A new boot ID (partner reloaded) ends the session and starts over.
- `manifest`: `have` = `{h = ContentHash, r = rev}` per mirror held from that partner, `own` = sender's `db.owned`. Receiver, per own character: hash matches → `shadows[key]` baseline; else `snap` (full copy).
- Then Syndicator events mark `dirty`; `Flush` (after 1.5 s) sends `delta` `{key, b = base rev, r, c = Util.Diff}` against the shadow, one in flight per character. Receiver applies only if `mirror.rev == b`, else sends one `need` per key per session (`asked`).
- `snap`s wait in `deferred` while `IsInInstance()`, sent on `PLAYER_ENTERING_WORLD` outside; deltas still flow.
- `CheckPeers` (30 s tick): 10 min since session start or last check, 30 s since the peer's last document, `Comms.IsBusy` false → holder sends `check` fingerprints; owner `snap`s mismatches except dirty, pending, deferred or sent in the last 30 s; `recheck[key]` stops a second copy of identical data.
- Comms: ≤250 chars → one `S`, else `H` + 220-char `C`s + `E`. Receiver acks `A` once the checksum matches, asks `R` for gaps (1.5 s after `E`, 10 s quiet); sender polls after 6 s, ends the session after 10 polls or 10 resend rounds. Pacing 2000 B/s, burst 4000; throttled → retry 0.3 s, lockdown → 5 s; offline or "No player named" (hidden) → `Sync.OnPeerGone`.

## Interface
- `/ssync` (status), `pair <name>`, `resync` (empty manifest → full copies of everything), `unpair` (keeps mirrors), `forget` (`Syndicator.API.DeleteCharacter` on every mirror), `debug`.
- `SyndicatorSyncDB` (account-wide): `accountId`, `partners[id] = {secret, characters{norm → name}, paired}`, `mirrors[key] = {partner, rev, updated}`, `owned[key]`, `debug`.
- Syndicator (required): `API.IsReady`, `GetCurrentCharacter`, `DeleteCharacter`, `CallbackRegistry` (`Ready`; listens to Bag/Mail/Equipped/Currency/Auctions/VoidCacheUpdate), writes `SYNDICATOR_DATA.Characters[key]`, fires `MailCacheUpdate(key)`. CombinedBagOrder's BankView refreshes on that event.
- Prefix `SynSync`. Transfer kinds (whisper, session peer only): `S:tid:sum:data`, `H:tid:n:sum`, `C:tid:i:n:data`, `E:tid` (end, or poll), `A:tid`, `R:tid:list` (0 = header, `*` = all). Control: `P:acct:boot` (group), `I:acct:proof:wantReply:boot`, `PQ:acct:nonce`, `PA:acct:nonce:secret`, `PD:nonce`. Document `t`: `manifest`, `check`, `snap`, `delta`, `need`.

## Decisions (keep)
- NEVER fire `BagCacheUpdate`/`EquippedCacheUpdate`/`CurrencyCacheUpdate` for a mirror; only `MailCacheUpdate(key)`, which Syndicator fires for non-live characters itself and treats as a full recount. Baganator takes `BagCacheUpdate` as the live character: it swapped a friend's bag window to the mirror and sorted the real bags by its layout (confirmed 2026-11-17, fixed in 1.0.1).
- Each account sends only its own characters. The current key and `db.owned` keys are never overwritten (`Accepts`); the partner's `own` list turns stray local copies into mirrors (`rev = -1`).
- Full copies wait out instances, because of the dungeon throttle.
- Crossed-ping handling (1.0.2) stops "syncing with" printing twice and the comparison being redone at login; don't go back to "any ping from the peer restarts".
- Pairing needs a click on the other client's popup; afterwards intros prove the secret with `Proof`, bound to both names, never sending it.

## Gotchas
- Set `db.mirrors[key]` before `NotifySyndicator`: `OnSyndicatorChange` also hears `MailCacheUpdate` and skips only mirror keys, so otherwise a mirror would be sent back as ours.
- New control kinds must not reuse `S H C E A R`: `Comms.OnMessage` routes those to transfers.
- `shadows` are memory only; each session start re-hashes every character for the manifest.
- One transfer per peer: a big `snap` holds every delta behind it.
- `MyName` is Syndicator's key minus `-Realm`; `Proof` breaks if that differs from the sender name the partner sees.
- `IsReachable` and `CompleteName` only check `party` units; in a raid a peer always counts as reachable.

## Open
- Boss encounters untested; sending may lock down (Comms retries every 5 s).
- `PQ` raises the pairing popup for any whisperer; Tandem's `NQ` limits that to group members.
- `db.partners` allows several partners; only one pair of accounts tested. The secret travels in plain text once, in `PA`.
- Browsing mirrored banks in CombinedBagOrder looks done already: BankView lists every Syndicator character with bank data, mirrors included.
- No mock tests in `tests/`.
