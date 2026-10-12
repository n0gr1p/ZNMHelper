# ZNMHelper (experimental Windower addon)

Multibox ZNM pop rotation and trophy lotting for Windower 4.

**Status: prototype; code has not been tested in game.** Do not use unattended until at least one observed pop and loot cycle has been validated. No client should have another automatic loot addon overriding ZNM trophy lots/passes.

## Install

Copy the repository folder to `Windower4/addons/ZNMHelper` on **every client** and `//lua l ZNMHelper`. The addon uses Windower IPC (`windower.send_ipc_message`), so all characters must be Windower instances on the same machine with IPC functioning.

1. On each client: `//znmh leader Niightsiide` (or choose another leader).
2. Move the correct ZNM pop into **main Inventory** on every character that should pop.
3. Park **each participating character** within range of the correct ???. No manual target selection is required. The addon resolves the nearby ??? directly and refuses an ambiguous location with multiple ??? entities in range.
4. On the leader only: `//znmh start chigre`. The leader queries clients, chooses one holder, asks it to trade its item, waits until the named NM appears and then disappears, checks for unresolved trophy in treasure pool, and (after 12 seconds) selects another holder. That holder retries every 2 seconds while the ??? is absent or the character is busy; the 25-second NM-spawn timeout begins only after a trade packet is sent.
5. `//znmh status`; `//znmh stop` at any time.

**Do not leave it unattended.** If the mob does not appear within 25 seconds after sending a trade packet, it stops. An absent ??? does not start this timeout and is retried automatically. This does not yet confirm server acceptance of a trade packet; an entity remaining in memory while unavailable may still cause a premature attempt. Failure to pop correctly can require manual intervention. It cannot verify the actual event completion, ownership of seals, or NPC menu outcomes.

## Loot routing

Set on leader, and broadcast to all clients:

```
//znmh recipient tyger Niightsiide
//znmh recipient tinnin Niightsiide
```

For Chigre, Verdelet, Experimental Lamia, Mahjlaef and Nuhn, the current pop *owner* is designated trophy recipient automatically. The addon tracks that owner explicitly, reapplies the owner assignment to peers during readiness queries, and scans treasure slots 0–9 for automatic lot/pass. If no owner has been assigned yet, it does not pass these trophies. The other characters pass only the configured trophy, and the designated character lots it. One Rare/Ex trophy per owner per wave; turn it in to Sanraku before continuing a repeat wave. The addon does **not** trade trophies to Sanraku.

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
