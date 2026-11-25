# Tandem
Dual-box startup helper: sets of your characters on different accounts find each other at login, the main invites the rest, the leader switches to free-for-all loot and every client but the main's mutes. With Upkeep, clickable reminders to focus the main, to cast a login spell (e.g. a stance), and to keep a set buff up while the set is active (e.g. Righteous Fury).

## Files
- `Util.lua`: `Util.PREFIX`, `Print`/`Debug`, `IsHidden`, `FullUnitName`, `Norm` (lower case, no `-Realm`), `MyName`, `RandomString`, `GroupMembers` (others as `{unit, name, norm}` plus `complete`), `UnitOf`, `Send`/`Whisper` (retries throttle and lockdown; `TargetOffline` → `Sets.OnGone`), `FilterNotFound` chat filter, `Confirm` (own yes/no frame `TandemConfirm`).
- `Sets.lua`: set storage, presence, messages. `Init`, `Mine`, `Active`, `Others`, `IsMain`, `AllShareASet`, `IsMainWith`, `AnnounceAll`, `Start`, `Create`/`FinishCreate`/`CancelCreate`, `MakeMain`, `Remove`, `OnGone`, `handlers`, `OnMessage`. Locals `online`, `pending` (set we proposed), `proposed` (sets we're deciding on).
- `Tandem.lua`: behaviour, slash command, events. `ns.Changed` → `UpdateSound` (`Mute`/`Unmute`), `UpdateFocus`, `UpdateLoginSpell`, `UpdateSetBuff`, `UpdateLoot`; invites `ns.Arrived`, `TryInvite`, `CanInvite`, `InviteNow`, `OnInvite`, `CloseInvitePopup`; `ShowReminder`/`HideReminder`; `OnFirstWorld`.

## How it works
- `PLAYER_LOGIN`: `Sets.Init`, register prefix. First `PLAYER_ENTERING_WORLD` → `OnFirstWorld`: sets `loaded`, `Sets.Start` (hello to every member after 2 s, keepalive ticker 60 s). Nothing acts before `loaded`.
- Presence: `online[norm] = {name, set, paused, grouped, seen}` from `H`. Keepalive asks (`H` with `r`) after 50 s quiet, drops after 150 s. `TargetOffline`, a "No player named" within 10 s of a whisper (hidden), or `UNIT_CONNECTION` false → `Sets.OnGone`.
- `Sets.Active`: the set whose other members are all online and unpaused, self unpaused; biggest wins. Follower = active set's main isn't me.
- `ns.Changed` recomputes everything from scratch on each change (messages, roster debounced 1 s, focus, shapeshift, regen, timers). `sentReminders` sends Upkeep only real changes.
- Sound: follower sets CVar `Sound_EnableAllSound` to 0, old value in `TandemDB.muted.restore`; restored when the set stops being active and at `PLAYER_LOGOUT`.
- Invites: 1.5 s after a member arrives the main invites if its `H` lacks `g`, everyone in the main's group shares a set with it, and `CanInvite` (ungrouped, leader or raid assistant). `PARTY_INVITE_REQUEST` from anyone sharing a set → `AcceptGroup`; popup hidden once `IsInGroup` (`StaticPopup_Hide("PARTY_INVITE")`, `LFGInvitePopup`).
- Loot: a leader whose group is only set members sets `Enum.LootMethod.Freeforall` once per group make-up (`lootDoneFor`); in combat it waits for `PLAYER_REGEN_ENABLED`.
- Login spell: armed (`loginPending`) only when `isInitialLogin`; cleared by a `UNIT_SPELLCAST_SUCCEEDED` whose castGUID was seen in `UNIT_SPELLCAST_SENT`, or by already being in that form after `LOGIN_SETTLE` (10 s).
- Set buff: `UpdateSetBuff` asks `Upkeep.KeepBuff(id, true)` while there's an active set and you aren't paused, and `false` otherwise. It sends only changes (`keptBuff`, not saved, so a reload asks again). Upkeep reads the buff and shows the reminder; Tandem only says when.
- Set copies sync by `rev`: a hello with a higher rev gets `Q`, a lower one gets `S`; offline members catch up at their next hello.

## Interface
- `/tandem` (status), `set`, `main`, `unset`, `invite` (now, skips the not-in-another-group rule), `invite|sound|loot|focus on|off`, `login <spell>|off`, `buff <spell>|off`, `pause`, `resume`, `debug`.
- `TandemDB` (account): `sets[id] = {main, members{norm → full name}, rev}`, `features{sound, loot, invite, focus}`, `muted{restore}`, `heldMute`, `debug`. `TandemCharDB`: `paused`, `loginSpell{id, name}`, `loginPending`, `setBuff{id, name}`.
- Calls `Upkeep.AddReminder`/`RemoveReminder` (OptionalDeps) with ids `Tandem.focus` (`click={type="focus", unit}`) and `Tandem.login` (`click={type="spell"}`, `spell` for the tooltip), always `resting=true`. Also `Upkeep.KeepBuff(setBuff.id, wanted)`, whose reminder follows Upkeep's own rules (hidden in rested areas and while mounted). Tandem makes no secure buttons; Upkeep does.
- Whispered addon messages, prefix `Tandem`, `kind:body`, fields split by `:`, set ids 8 random chars:
  - `H:set:rev:flags` hello/keepalive; flags `p` paused, `g` in a group, `r` please answer.
  - `S:set:rev:main:a,b` sender's copy of the set (taken only if rev is higher). `Q:set` send me yours.
  - `U:set` sender removed the set or doesn't know it: the receiver deletes it.
  - `NQ:set:main:a,b` invitation to a new set; `NA:set` joined, `ND:set` declined.

## Decisions (keep)
- Shareable: no hardcoded names, settings only by slash command, no Syndicator/SyndicatorSync dependency; without Upkeep only the reminders are missing.
- Every member confirms a new set by popup. `NQ` counts only from a group member who is the set's main, so strangers can't raise popups. Own popup frame; Blizzard's StaticPopup table stays untouched.
- Sound back on at logout: Config.wtf is shared by clients run from one folder and saved on exit. `/reload` fires `PLAYER_LOGOUT` too, so `heldMute` re-mutes for `RELOAD_HOLD` (20 s). `Unmute` leaves the CVar alone if you turned sound on yourself.
- Free-for-all once per group make-up so a manual loot change sticks; new groups start as Group Loot, hence switching after forming.
- Auto-invite never pulls anyone into a group with outsiders; `/tandem invite` is the override.
- `pause` is per character and survives relogs; sent as the `H` `p` flag so the others stop treating the set as active.
- Set buff (1.1.0): per character, kept up while any of its sets is active. Built for a Ret paladin who tanks Righteous Fury only when playing with their mage. Upkeep holds the 5 minute early warning for Righteous Fury; another spell gets Upkeep's defaults.
- Login spell lives in Tandem, not Upkeep. A reload keeps a pending reminder but never re-arms a done one. Reminders show in rested areas: setup happens in town.

## Gotchas
- Right after a real login the game reports the logout stance for a moment, then casts the default stance for you: don't trust `GetShapeshiftFormInfo` before `settleUntil`, and don't count casts without a matching `UNIT_SPELLCAST_SENT` (1.0.1 fix).
- `TandemDB.muted` is saved on purpose: after a crash while muted, the next load's `UpdateSound` → `Unmute` restores sound.
- `U` from any member deletes the set: a member whose copy is gone (wiped SavedVariables) makes the others drop it at the next hello.
- Key everything on `Util.Norm`; whispers and invites need the stored full name.
- `GroupMembers` returns `complete = false` when a name is unreadable; set creation and loot bail out rather than guess.
- `MAX_MEMBERS` 5 also keeps `S`/`NQ` inside the 255-byte message limit.

## Open
- In game: set creation, startup after logout, the 1.0.1 login spell fix and the 1.1.0 set buff (Righteous Fury) work. Untested: 3+ member sets, a character in several sets, raid-assistant invites, the `LFGInvitePopup` path.
- Mock tests: only `tests/tandem_buff_test.lua` (the set buff, with Sets and Util stubbed).
