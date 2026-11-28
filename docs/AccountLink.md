# AccountLink
Pairs two accounts for dual-boxing and keeps other addons' per-character data in step between them while their characters are grouped. Extracted from SyndicatorSync 1.0.2 (2026-11-28); SyndicatorSync 1.1.0 is its first user, a profession cooldown tracker is planned as the second.

## Files
- `Util.lua`: `PREFIX` ("AcctLink"), `Print`/`Debug`, `IsHidden`, `FullUnitName`, `Norm`, `CompleteName` (first name → full, party only), `RandomString`, `Hash` (two polynomial hashes kept below 2^31, as "a.b"), `ContentHash` (independent of pairs order), `Pack`/`Unpack` (`C_EncodingUtil` CBOR + compress + Base64), `Copy`, `Equal`, `Diff`/`Apply` (path change lists).
- `Comms.lua`: transport. `queues.control` before `queues.data`, sent by the `pump` OnUpdate; `outgoing` per peer, `incoming` reassembly, transfer `handlers` S/H/C/E/A/R, `FilterNotFound`. API: `SendControl`, `SendDocument(target, doc, onDone)`, `Forget`, `IsBusy`, `QueueLength`, `OnMessage`. Calls back into `ns.Link` (`OnPeerGone`, `IsReachable`, `IsTrusted`, `OnDocument`, `OnControl`).
- `Link.lua`: `InitDB`; datasets (`datasets`, `order`, per dataset `shadows`, `dirty`, `asked`, `recheck`); sending (`Flush`, `SendSnapshot`, `QueueSnapshot`, `deferred`, `SendDeferred`, `CheckPeers`); sessions (`peers`, `peerIdByNorm`, `bootId`, `Ping`, `SendIntro`, `Proof`, `StartSession`/`EndSession`); `documents` handlers; pairing (`ShowPairConfirm`, `control`); the global `AccountLink` API; `/alink`.

## API (global `AccountLink`)
- `Register(name, spec)`, once the addon's data is ready. `spec.state` is a table in the addon's own saved variables, where AccountLink keeps `owned` (keys logged in on this account) and `mirrors` (key → `{partner, rev, updated}`). `spec.Store()` returns key → data, own and copies alike; copies are written into it. `spec.CurrentKey()`. Optional: `Valid(data)`, `OnMirrored(key)` (after a copy arrived or changed, with `mirrors[key]` already set; errors are caught), `title` (popup and status).
- `Changed(name, key)`: an own character changed (ignored for copies). `Resync(name)` (nil = every dataset), `Pair(name)`, `Unpair()`, `PrintStatus()`, `ToggleDebug()`, `Age(seconds)`, `Adopt(accountId, partners)` (takes an older addon's pairing while AccountLink has none).
- Register adds the current key to `owned` and removes it from `mirrors`. During a running session it sends its manifest at once and answers the partner's manifest if one arrived before (`peer.manifests`).

## How it works
- `ADDON_LOADED` (own) → `InitDB`, before dependents load so they can `Adopt`. `PLAYER_LOGIN` → prefix, `ready`, `Ping` at +3 s, every 60 s and 3 s after `GROUP_ROSTER_UPDATE`; `CheckPeers` every 30 s.
- `Ping` (PARTY, or INSTANCE_CHAT) runs only while a partner isn't connected. A paired account answers with a whispered `I` (5 s cooldown per name); a valid `I` → `StartSession` → a `manifest` per registered dataset. Pairing itself is whispered, sessions need a group.
- `P` with the boot ID the session already has = crossed ping (both ping at login, Tandem groups them at once): keep the session, send `I` without reply wanted. A new boot ID (partner reloaded) ends the session and starts over.
- Per dataset, `manifest`: `have` = `{h = ContentHash, r = rev}` per mirror held from that partner, `own` = sender's owned keys. Receiver, per own key: hash matches → `shadows[key]` baseline; else `snap` (full copy).
- Then `Changed` marks `dirty`; `Flush` (after 1.5 s) sends `delta` `{ds, key, b = base rev, r, c = Util.Diff}` against the shadow, one in flight per key. Receiver applies only if `mirror.rev == b`, else sends one `need` per key per session (`asked`).
- `snap`s wait in `deferred[partner][dataset]` while `IsInInstance()`, sent on `PLAYER_ENTERING_WORLD` outside; deltas still flow.
- `CheckPeers`: 10 min since session start or last check, 30 s since the peer's last document, `Comms.IsBusy` false → a `check` per dataset with fingerprints; the owner `snap`s mismatches except dirty, pending, deferred or sent in the last 30 s; `recheck[key]` stops a second copy of identical data.
- Documents for a dataset not registered here are dropped; a `manifest` is kept in `peer.manifests` for a later `Register`.
- Comms: ≤250 chars → one `S`, else `H` + 220-char `C`s + `E`. Receiver acks `A` once the checksum matches, asks `R` for gaps (1.5 s after `E`, 10 s quiet); sender polls after 6 s, ends the session after 10 polls or 10 resend rounds. Pacing 2000 B/s, burst 4000; throttled → retry 0.3 s, lockdown → 5 s; offline or "No player named" (hidden) → `Link.OnPeerGone`.

## Interface
- `/alink` (status: pairing, link, each dataset's copies), `pair <name>`, `resync`, `unpair`, `debug`.
- `AccountLinkDB` (account-wide): `accountId`, `partners[id] = {secret, characters{norm → name}, paired}`, `debug`. Per-dataset `owned`/`mirrors` live in the registering addon's saved variables.
- Prefix `AcctLink`. Transfer kinds (whisper, session peer only): `S:tid:sum:data`, `H:tid:n:sum`, `C:tid:i:n:data`, `E:tid` (end, or poll), `A:tid`, `R:tid:list` (0 = header, `*` = all). Control: `P:acct:boot` (group), `I:acct:proof:wantReply:boot`, `PQ:acct:nonce`, `PA:acct:nonce:secret`, `PD:nonce`. Document `t`: `manifest`, `check`, `snap`, `delta`, `need`, each with `ds`.
- Test: `tests/link_sync_test.lua` (asserts) runs two clients from the .toc files over a simulated network with latency, reordering and loss: crossed login pings, first copies, a change list, a lossy big change, a reload, instance deferral, a late-registered second dataset, a dataset only one side has, status commands, pairing from the popup, and the pairing taken over from SyndicatorSync. Checked to fail with resends off, with BagCacheUpdate for copies, and without the kept manifests.

## Decisions (keep)
- A plain addon others depend on, not an embedded library: the pairing is stored once per account, and all our addons ship from one folder, so versions always match.
- Each account sends only its own characters. Own keys are never overwritten (`Accepts`); the partner's `own` list turns stray local copies into mirrors (`rev = -1`).
- Full copies wait out instances, because of the dungeon throttle.
- Crossed-ping handling stops "linked with" printing twice and the comparison being redone at login; don't go back to "any ping from the peer restarts".
- Pairing needs a click on the other client's popup; afterwards intros prove the secret with `Proof`, bound to both names, never sending it.
- SyndicatorSync's pairing (accountId, partners) is adopted at its `ADDON_LOADED`, so existing pairs keep working without pairing again. Both clients must run the new version, since the prefix changed from `SynSync`.

## Gotchas
- `OnMirrored` runs after `mirrors[key]` is set: a consumer that hears its own change event for the copy (SyndicatorSync's MailCacheUpdate) calls `Changed`, which skips mirrors.
- New control kinds must not reuse `S H C E A R`: `Comms.OnMessage` routes those to transfers.
- `shadows` are memory only; each session start re-hashes every key for the manifests.
- One transfer per peer: a big `snap` holds every delta behind it, for every dataset.
- `MyName` is `FullUnitName("player")`; `Proof` breaks if that differs from the sender name the partner sees. SyndicatorSync used Syndicator's key minus `-Realm` before; both match (confirmed in game 2026-11-28).
- `IsReachable` and `CompleteName` only check `party` units; in a raid a peer always counts as reachable.

## Open
- Confirmed in game 2026-11-28: the pairing adopted from SyndicatorSync (no re-pairing), the link at login ("linked with"), `/alink` status with the Syndicator copies, and loot showing on the other account (change lists).
- Boss encounters untested; sending may lock down (Comms retries every 5 s).
- `PQ` raises the pairing popup for any whisperer; Tandem's `NQ` limits that to group members.
- `db.partners` allows several partners; only one pair of accounts tested. The secret travels in plain text once, in `PA`.
- Tandem keeps its own presence and messages (it works ungrouped, by character sets, and is meant to be shareable alone); it could move onto AccountLink later.
