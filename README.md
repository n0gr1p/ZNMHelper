# ZNMHelper (experimental Windower addon)

Multibox ZNM pop rotation and trophy lotting for Windower 4.

**Status: prototype; code has not been tested in game.** Do not use unattended until at least one observed pop and loot cycle has been validated. No client should have another automatic loot addon overriding ZNM trophy lots/passes.

## Install

Copy the repository folder to `Windower4/addons/ZNMHelper` on **every client** and `//lua l ZNMHelper`. The addon uses Windower IPC (`windower.send_ipc_message`), so all characters must be Windower instances on the same machine with IPC functioning.

1. On each client: `//znmh leader Niightsiide` (or choose another leader).
2. Move the correct ZNM pop into **main Inventory** on every character that should pop.
3. Park **each participating character** within range of the correct ???. No manual target selection is required. The addon resolves the nearby ??? directly and refuses an ambiguous location with multiple ??? entities in range.
4. On the leader only: `//znmh start chigre`. The leader queries clients and selects a holder. The selected character independently checks its nearby `???` every 2 seconds, **without targeting**. The `???` must be unambiguous, in range, and report `valid_target == true` continuously for **20 seconds** before the trade packet is sent. If the `???` disappears, becomes invalid, or changes entity ID/index, the timer resets. This applies to the **first pop and every subsequent pop**. After an NM disappears, the leader waits 12 seconds and for the trophy to clear before selecting another holder. The 25-second NM-spawn timeout begins only after a trade packet is sent.
5. `//znmh status`; `//znmh stop` at any time.

**Do not leave it unattended.** If the NM does not appear within 25 seconds after sending a trade packet, the addon stops. A missing `???` or `valid_target ~= true` does **not** start this timeout: the current popper keeps checking every 2 seconds until the flag remains true for 20 seconds. The old fixed 180-second hold has been removed. `valid_target` is a client-side readiness signal and the 20-second safety buffer is precautionary; neither is a server-side confirmation of trade acceptance. A rejected packet can still trigger the existing 25-second timeout. One-off trade issues may require manual intervention.

## Passive ??? state diagnostics

On a parked character, run `//znmh debugpop on`. The addon inspects nearby `???` entities directly from `get_mob_array()` **without targeting, trading, or affecting pop rotation**. It writes **one timestamped CSV record per second**, including unchanged snapshots, so transient entity flags and timing can be reconstructed even if there is no visible state transition.

Logs are written to:

```text
Windower4/addons/ZNMHelper/data/ZNMHelper_pop_<Character>_YYYYMMDD.csv
```

Each character has a separate append-only file containing timestamp, character, `CHANGE`/`SAMPLE`/`MANUAL` event type, stage, nearby count, entity ID/index, `valid_target`, `status`, `spawn_type`, `target_type`, `hpp`, `is_npc`, squared distance, coordinates, and pop-rotation state (`running`, `waiting`, `seen_nm`, `awaiting_ack`, `pending_stage`). Missing values stay as empty CSV columns rather than being silently replaced with guesses.

The file is flushed **after every record** to reduce data loss on a crash or forced client exit. Only start/stop, explicit one-shot confirmation, and write failures print in game chat; diagnostic records do not spam chat. If a log file cannot be opened or written, the addon reports the failure and disables monitoring rather than silently pretending it logged.

- `//znmh debugpop on` — begin local per-second file logging
- `//znmh debugpop once` — append one manual snapshot to the file
- `//znmh debugpop off` — stop logging and close the file

Debug logging is intentionally local and non-persistent. Enable it separately on each client you want to observe, then compare the CSV before, during, and after the cooldown. The popper now requires `valid_target == true` for a 20-second safety buffer before trading. That signal is **not proof of server-side trade acceptance**.

## Loot routing

Set on leader, and broadcast to all clients:

```
//znmh recipient tyger Niightsiide
//znmh recipient tinnin Niightsiide
```

For Chigre, Verdelet, Experimental Lamia, Mahjlaef and Nuhn, the current pop *owner* is designated trophy recipient automatically. The addon tracks that owner explicitly, reapplies the owner assignment to peers during readiness queries, and scans treasure slots 0–9 for automatic lot/pass. If no owner has been assigned yet, it does not pass these trophies. The other characters pass only the configured trophy, and the designated character lots it. One Rare/Ex trophy per owner per wave; turn it in to Sanraku before continuing a repeat wave. The addon does **not** trade trophies to Sanraku.

**Automatic lotting is enabled only during an explicitly started ZNM run.** The leader broadcasts `START` to arm each client; `//znmh stop` broadcasts `STOP`, clearing the session loot flag and stale owner assignment on every client. Merely setting the stage or receiving readiness queries cannot activate lotting, and changing the stage during an active run is refused.

**Fixed-recipient stages are different from owner stages:** Vulpangue, Iriz Ima, Armed Gears, Gotoh Zha, and Dea are currently configured to lot their trophies to **Etamame even if Etamame has no pop item**. Those defaults remain unchanged. Experimental Lamia's armband is owner-routed, so Etamame should not receive a ZNMHelper lot request for it unless Etamame is the assigned popper.

### Persistent loot-decision audit

Every automatic `lot_item` or `pass_item` request is recorded in a per-character daily CSV file:

```text
Windower4/addons/ZNMHelper/data/ZNMHelper_loot_<Character>_YYYYMMDD.csv
```

Each row records timestamp, character, requested action (`REQUEST_LOT` or `REQUEST_PASS`), stage, trophy, recipient, claimed owner, treasure slot, and active-session state. These are records of *requested actions*, not proof that the game awarded the trophy. If Etamame appears to be lotting something unexpected, compare Etamame's file with the actual treasure-pool item.

For Tyger, choose one Mythic recipient before each kill, or stop the queue between recipients. **Do not spawn the three trial Tyger pops before the Magian trial is active.**

## Known stage aliases

| Stage | Pop item | Trophy |
|---|---|---|
| `chigre` | Spoilt Blood | Chigre |
| `verdelet` | Mint Drop | Verdelet's Wing |
| `lamia` | Myrrh | Ex. Lamia Armband |
| `mahjlaef` | Exorcism Treatise | Mahjlaef's Staff |
| `nuhn` | Rose Scampi | Nuhn's Esca |
| `tyger` | Singed Buffalo | Tyger's Tail |
| `vulpangue` | Hellcage Butterfly | Vulpangue's Wing |
| `irizima` | Senorita Pamama | Iriz Ima's Hide |
| `armedgears` | Ferrite | A. Gears' Fragment |
| `gotohzha` | Sheep Botfly | G. Zha's Necklace |
| `dea` | Olzhiryan Cactus | Dea's Horn |
| `tinnin` | Monkey Wine | Tinnin's Fang |

## Limitations / safety

- The addon trades to the only nearby `???` without selecting it. If multiple `???` entities are in range, it refuses to trade until the location is unambiguous.
- No movement or pathfinding, no purchasing or retrieving pop items from bags, no NM combat logic. Use UnifiedCombat for fighting.
- Windower treasure slots are 0–9. Trophy routing is based on matching resource item names. It intentionally leaves other loot alone.
- The leader's NM presence check relies on local mob visibility. All clients should stay close enough to see the named monster and the leader should not zone mid-run.
- ZNM trophy-to-seal exchanges are not automated. Rare/Ex inventory limits still apply.
- The local config is stored per Windower client; `recipient` commands broadcast currently connected clients.
- If the wrong NM, target, or loot is observed, use `//znmh stop` immediately.
- We have not verified this code's runtime behavior, packet acceptance, or full orchestration during live FFXI gameplay. Start with **one Chigre pop** and inspect the lot/pass results before attempting a full wave.
