# Phase 4 brief — Zonas, Endereçamentos, Causa e efeito (linked devices), island transport, multi-central

_2026-10-28. Planning only: no code exists for anything below. Authority: below the protocol and the
blueprint; this file records the decisions taken in the planning sessions of 2026-10-28, what is
deliberately deferred, the phases, and the list of decisions still owed by the product owner.
Sibling briefs: `phase2-leaf-brief.md`, `phase3-ota-brief.md`. The reference registers the rows
(`docs/sempreiot-system-reference.md` §3.5 rows 5.10–5.13, §3.2 row 2.9)._

---

## 1. What the product owner asked (2026-10-28)

1. Any product can be a **NODE or a LEAF** depending on how it is powered (a smoke detector on mains
   is a node, on batteries a leaf). A factory decision at the first flash.
2. Three pieces of information on every device: **Nome** (name), **Endereçamento** (where it is, e.g.
   "1º andar") and **Zona** (a group that is triggered together, e.g. "Zona de portões" — in a fire,
   zone 1 opens every door). Screens filter by zona and endereçamento; both are manageable.
3. **Linked devices**: the installer decides who triggers whom — this detector sounds these sirens,
   an alarm in this zone triggers that zone. A panel on the tablet (and remotely) to set it up.
4. **Communication between centrals**: two blocks, one central each; an alarm in block 2 sounds the
   sirens of block 1. By the mesh when the two sites' devices can hear each other, by the internet
   over long distances.
5. **Internet as the gap filler**: a device that neither wiring nor any Wi-Fi signal can reach joins
   the central through the internet. Not a channel commitment on the main mesh.

## 2. Decisions (2026-10-28)

### 2.1 Family at the factory (item 1) — no new mechanism

1. **The family is the image, chosen at the factory** (`tools/flash.sh node|leaf --model …`), exactly
   as reference §2.1 already says. A product that exists in both families has **one model string per
   family** (today: `SIOT-SMOKE-AC-01` node `0x0205`, `SIOT-SMOKE-01` leaf `0x0301`).
2. **The behaviour is one feature component compiled into both images** (`siot_sensing` when it
   comes), written image-agnostic from day one. The features contract (`firmware/components/features/README.md`)
   already allows it.
3. **The decision is final in the field.** Cross-family OTA is refused by design; changing a unit's
   family is a cable flash. Written on the product pages when they are updated.
4. **No runtime choice by the ACOK pin.** One image with Mesh-Lite and the deep-sleep leaf stack
   breaks "family = image" (OTA) and the 1.75 MB image cap.
5. Catalogue rule to add in reference §2.1: sibling models (same sensor, two families) are listed
   side by side and share the app's 3D model and display name.

### 2.2 Nome, Endereçamento, Zona (item 2)

1. **The units store none of this.** Name travels in `NAME_ANNOUNCE` as today (Case A needs it: the
   unit announces its own name so the board's roster never depends on the phone). Endereçamento and
   Zona live **only in the board's tables and on the tablet**. No node or leaf firmware change.
2. **Both are ids behind names.** The user types and sees names; the system keys everything by an id
   (`u16`, `0` = none). Why not strings on the wire: a rename would mean re-sending `SET_DEVICE` to
   every unit of that zone, and a rule keyed by text breaks on a typo or a rename. With ids a rename
   touches one row and every device, filter and rule follows. The number is never shown.
3. **Two label tables on the board**, `zones` and `addresses`: `{id u16, name ≤ 32 bytes}`, created,
   renamed and deleted from the tablet, pushed to it in a paged uplink frame like `DEVICE_TABLE`, so a
   replacement tablet recovers them with the roster (blueprint rule 5). The device table gains
   `zone_id u16` and `address_id u16` per entry.
4. **Setup asks for what the installer knows at that moment:** name mandatory (default: product +
   sticker id, one tap), endereçamento **optional** from the installation's list or typed, **zona
   not asked** (it is a design decision that belongs with the rules, on the tablet). Everything can be
   set and changed later on the tablet, always. The phone keeps endereçamento in its installation
   record / work log and it reaches the board through the enrolled list or the tablet, never
   through the unit.
5. **Today's 16-byte `zone` string in `NAME_ANNOUNCE`** becomes the **endereçamento by name** the
   installer typed at setup (protocol §7.11 ADDRESS; decided 2026-10-28 after the first bench run: an
   endereçamento typed at setup must show on the tablet without any further step). The board resolves it
   to a label id — creating the label when new — and sets it only while the unit has none; the tablet's
   `SET_DEVICE_IDS` always wins. In `SET_DEVICE` / `DEVICE_TABLE` the slot is *reserved* (length 0). The
   devtab / `SET_DEVICE` code that handled the string is **replaced** by the id handling (no dead code).
6. **The board's device-table record gets a version byte.** A board that boots a firmware with a newer
   record version **drops the table and rebuilds it** from what it hears; the tablet's existing
   "Reenviar nomes à placa" restores names, endereçamentos and zonas. No migration code, ever. Nothing
   has shipped, so no cable flash is needed either.
7. **Endereçamento stays ≤ 32 bytes as a label**; the per-unit cost is 4 bytes (two ids) against the
   17 the zone string cost.
8. Managed lists on the tablet: a **Zonas** screen and an **Endereçamentos** screen (create, rename,
   delete, assign units); filters by either on **Dispositivos** and **Rede**; both in the cloud mirror
   `state` message; both in the walk-test report; the OTA rollout filter gains `4 = one zone id`
   (`2 = one zone string` stays for old boards).

### 2.3 Causa e efeito — linked devices (item 3)

Name: **Causa e efeito** (the industry term; inspectors ask for the cause-and-effect matrix). Not a
"developer panel": the user is the installer at commissioning, the operator reads it.

1. **A rule = causes → effects.** A cause is an ALARM from **a unit, a zone, or anywhere**; an effect is
   an action on **a unit, a zone, or everything**. Actions start with **sound** (siren); the same model
   later covers a relay on the I/O module, the doors of a zone, a push to the phones, and an alarm
   forwarded to another central.
2. **Rules are stored and executed on the board.** The board is the certified control unit: the site
   must behave with the tablet unplugged and the internet down. On every authenticated ALARM the board
   resolves the matching rules and sends `COMMAND SOUND` (to be defined — the slot exists in protocol
   §7.6) to each effect with `F_ACK_REQ` and the downlink retry (§9.1).
3. **A safe floor the rules can never remove:** with **no rules, or with the board dead, every siren
   sounds on every authenticated alarm** it overhears (blueprint §6.3 rule). Rules only refine the floor.
   *(Recommended; owed by the product owner — §6 D1.)*
4. **Each effect unit holds its own expanded cause list** (MACs), pushed by the board whenever a rule
   or a zone changes (`SET_LINKS`, new COMMAND). A siren reacts to an overheard alarm from a linked
   unit with the board dead; the unit never needs to understand zones.
5. **Rules are evaluated by the board that owns the effects; causes may be remote.** "Alarm in block 2
   sounds block 1" is a rule stored on board 1 whose cause is *(central 2, zona Portões)*. Board 2 never
   commands block 1's sirens; it only forwards its alarm events (unit MAC + zone id) to anyone paired
   with it. **Fixed now so the local engine is the complete engine**: every selector carries a
   `central` field (`0` = this central; the board's MAC otherwise), zone ids are per central (a remote
   zone is the pair central + zone). Local code ignores a non-zero central.
6. **Editing:** rules are edited on the tablet behind the installer PIN (Nível 4), every change
   audited; the operator reads. **A remote Administrador may edit too** (decided 2026-10-28, the third
   exception to mirror rule 2 after Identificar and the Internet update): the phone publishes on its own
   `{id}/cmd/{user}` topic, AWS proves who, the tablet checks the level and applies the change to the
   board, the board confirms. Conditions: the central must be online (a change with the central
   offline is **refused with a message, never queued**), the tablet shows who changed what, the matrix
   on the phone shows the rules **as the board confirmed them**, never as submitted.
7. **Two views of the same rules:** the **matrix** (causes as rows, effects as columns, a tick per
   link; what inspectors expect and what goes in the PDF) and the **map** (tap a detector → its effects
   light up; tap a siren → what triggers it).
8. **Every effect is confirmed on the map by the unit's own ACK**, like commands today (✓ board, ✓✓
   unit), so a siren that did not respond is visible.
9. **A rule that points to a unit or zone that no longer exists is shown as a fault**, never silently
   dropped. Forgetting a unit that a rule names asks for confirmation.
10. **Scope by version:**
    - v1: immediate rules, unit/zone → unit/zone; the floor; the per-unit cause list; matrix + map;
      the audit; remote edit.
    - v1 also: **templates** (evacuação geral · por zona · por andar) — one tap gives a sane
      configuration before the installer refines it.
    - v1 also: **dry run** — "o que acontece se este detector alarmar?" lights the effects on the map
      and blinks the real units with `IDENTIFY`, sounding nothing; and a **real test** that drives the
      sirens, logged like the system test (`SystemTests`-style row).
    - later: delays before general evacuation, **double knock** (two detectors of one zone), day/night
      modes — all capped by the standards, so they come with the compliance review.
    - later: cross-central causes (§2.5).

### 2.4 Internet as the gap filler — the island transport (item 5)

1. **No uplink on the board, no channel commitment.** A unit that no mesh signal reaches does not need
   the mesh channel at all. It joins the **customer's Wi-Fi router** as a Mesh-Lite island (the mode
   Mesh-Lite was built for: router = the customer's SSID), on the router's channel. Its children and its
   leafs hang on it as usual (leafs learn the channel from the parent ACK).
2. **The island root tunnels SAFR frames over MQTT** (AWS IoT, TLS) to the central: the tablet
   subscribes and injects the frames into its pipeline as if they had arrived by USB, and sends downlink
   back the same way. SAFR stays end-to-end authenticated inside the tunnel (blueprint rule 7). The
   tablet is the junction and **re-injects every island frame to the board over USB** (§7 R3), so the
   board holds the whole site and its rules fire for island causes and island effects alike. With the
   tablet unplugged the island is unreachable, which is the supplementary nature of this path.
3. **An island is an installer's choice, never automatic**: provisioning gains optional
   `router_ssid` / `router_psk`, and a unit so marked uses the router, not the board's AP. A unit in
   reach of both must not flap.
4. **Supervision unchanged:** when the internet drops the island goes missing in 45 s and raises a
   trouble; its sirens keep sounding on local alarms (the floor). The island is a *supplementary* path.
5. **The same tunnel is the long-distance path between centrals** (§2.5).
6. **Cloud identity for the island root**: a per-unit identity (factory step or provisioned by the
   phone) and an IoT policy that allows only its central's tunnel topics — designed with the lambda.

### 2.5 Multi-central (item 4) — **deferred**

**Deferred on 2026-10-28: only one board exists on the bench.** Nothing is built; the design is
recorded so the local phases carry what it needs (§2.3 item 5: central field in every selector, the
board MAC as central identity, per-central zone ids, forwarded alarm events carry MAC + zone id).

When it returns, the two paths as discussed:

- **By the mesh, when any node of one site hears any node of the other:** **ESP-NOW** between the two
  meshes (connectionless, runs beside the mesh, already used by leafs). A border node of site B hands
  the frame to a node of site A, which injects it into its own uplink. Discovery reuses the survey
  probe with a new `purpose`. Needs: both sites on the **same Wi-Fi channel** (one radio cannot listen
  on two channels; the installer's choice, not an external router's), a shared SAFR key or a pair key
  pushed by both boards, a `PEER_EVENT` message with dedupe, supervision of the peer path ("bloco 2
  inalcançável"). No new hardware.
- **By the internet, long distance:** the MQTT tunnel of §2.4, central to central.
- **Wired peer link** (RS-485 / Ethernet on the board PCB, the certifiable path networked panels use):
  a PCB note for the future, not planned.

**Bench prerequisite:** a second board (and a second tablet or the phone mirror).

## 3. What exists already (nothing below is new work)

- Family = image, model per product, pin map per model, images refuse a foreign model (reference §2.1).
- `name` + `zone` strings on the wire and in the board's table (`NAME_ANNOUNCE` §7.11, `SET_DEVICE`
  §7.6, `DEVICE_TABLE` §7.12), the installation's `zones` list on the phone, the wizard's name + zone
  step, "Reenviar nomes à placa".
- `COMMAND` downlink with the unit's own ACK, retries (§9.1), ticks on the map; `IDENTIFY`.
- The cloud mirror, the watch rule, `{id}/cmd/{user}` with AWS-proved identity and the Administrador
  check (OTA internet plan D7/D8); the audit trail.
- Mesh-Lite NAT on every node; `esp_modem`, `iot_bridge` already dependencies of the node image.
- ESP-NOW survey probe / offer with a `purpose` byte (§7.14 / §7.15).

## 4. Protocol additions — **written 2026-10-28 as revision 3.8** (`docs/safr/protocol-safr-v3.md` §14, §7.6, §7.11, §7.12, §13.6)

_The table below was the to-do list; the protocol is now the authority for every layout. Differences from the
table: `SOUND` is `COMMAND 0x06`, `SET_LINKS` `0x1E`, labels `0x20–0x22`, rules `0x23–0x25`, `LABEL_TABLE`
`MSG_TYPE 0x16`, `RULE_TABLE` `0x17`, `DEVICE_TABLE` `format = 2` adds `ZONE_ID ‖ ADDRESS_ID ‖ LINK`; and
**`SET_DEVICE` is unchanged** — a unit's ids go in the new board-only `SET_DEVICE_IDS` (`0x26`), because
the node firmware rejects a `SET_DEVICE` with extra bytes and because assigning a zone must never send a
frame into the mesh or wake a detector._

**Phase A, board side — coded 2026-10-28:** `siot_labels` (two NVS blobs, revision per kind), the device-table
record v3 (version byte, ids, link, no zone string; records of another version dropped on load),
`DEVICE_TABLE` format 2 + `LABEL_TABLE` after it, `SET_DEVICE_IDS` / `SET_LABEL` / `DEL_LABEL` (refused
while a unit uses the label) / `GET_LABELS`, OTA filter 4; the zone slot sent empty everywhere. Board, node and
leaf build; 66 host tests pass (`test_labels.c` new). Nodes and leafs untouched.

**Phase A, app side — coded 2026-10-28:** schema v15 (`DeviceLabels`, `zoneId` / `addressId` / `linkKind` per unit, the
zone string column dropped), `LABEL_TABLE` + format 2 in the ingest, `labelIndexProvider` naming every unit's zone /
endereçamento, the **Zonas** and **Endereçamentos** screens (drawer; create / rename / delete behind the PIN, delete refused
while a unit carries the label), the Dispositivo screen's "Zona e endereçamento" picker (`SET_DEVICE_IDS`), Dispositivos
search + filter chips by zona / endereçamento, "Reenviar nomes à placa" resending labels and ids too, the mirror carrying
both names, the wizard's step 3 = name + optional endereçamento (zone left to the tablet; the phone's installation list
renamed `addresses`, old records read). `flutter analyze` clean, 744 tests pass (`safr_v38_labels_test.dart` new).
**Not in this slice:** a zona / endereçamento filter on the Rede map; the OTA screen offering filter 4 (the board supports it);
the walk-test report (not built yet). *Bench 2026-10-28:* steps 2–5 passed; the popover gained ENDEREÇAMENTO / ZONA and lost
the heartbeat monitor, the map labels units by endereçamento, each label opens its devices; an endereçamento typed at setup
now reaches the board through the unit's announce (protocol §7.11 ADDRESS) and the phone's `/enroll` list. **Bench order:** flash the board first — a v3.8 tablet on a pre-v3.8 board gets v3.2
device-table pages (no product fields) and its label commands would be relayed into the mesh.

| Item | Where | Note |
|---|---|---|
| `COMMAND SOUND` | §7.6 | pattern, duration, `SILENCE` interaction (§7.1.4); unit ACK |
| `SET_LINKS` (board → unit) | §7.6 | the unit's expanded cause list (MACs); stored in the unit's NVS; replaces, never appends |
| `SET_LABEL` / `LABEL_TABLE` | §7.6 / new uplink | board-only; `kind` (zone / address), `id`, `name ≤ 32`; paged like `DEVICE_TABLE` |
| `zone_id u16 ‖ address_id u16` | §7.12 `DEVICE_TABLE` entry | appended; `format = 2` |
| `SET_DEVICE` v2 | §7.6 | `mac ‖ name ‖ zone_id ‖ address_id` (string zone slot reserved, length 0) |
| `SET_RULE` / `DEL_RULE` / `GET_RULES` / `RULE_TABLE` | §7.6 / new uplink | selector = `{central[6] ‖ kind u8 ‖ id}`; causes × effects; paged |
| `NAME_ANNOUNCE` zone slot | §7.11 | *reserved*: senders put length 0, receivers ignore |
| OTA filter `4 = one zone id` | §13.6 | `2` stays for the string |
| Device-table record version | board NVS (`siot_devtab`) | not on the wire; documented in `docs/devices/board.md` storage |
| Island tunnel topics | `docs/cloud/central-mirror.md` §2 | `{id}/mesh/up`, `{id}/mesh/down` (names to settle), QoS, policies |

## 5. Phases (each ends with something you can see on the bench)

| Phase | Content | Firmware | App | Bench exit |
|---|---|---|---|---|
| **A — Zonas e Endereçamentos** | label tables on the board, ids in the device table, record version byte, wizard change, Zonas / Endereçamentos screens, filters, mirror, report, OTA filter 4 | board only | yes | rename a zone on the tablet, every unit of it follows; replace the tablet, "Reenviar" restores all; filter the map by zona |
| **B — Siren + Causa e efeito** | `siot_siren` (sounder, `SOUND`, the floor), rules engine on the board, `SET_LINKS`, Vínculos matrix + map, templates, dry run, real test, audit, remote edit | board + node | yes | one detector, two sirens: a rule sounds only the linked one; board unplugged → both sound (floor); dry run blinks without sound; a phone edits a rule and the tablet shows who |
| **C — Island transport** | SAFR over MQTT on the node (island root), tunnel in the tablet, island provisioning, cloud identity + policy | node | yes | a node on the bench router, no mesh path, shows online on the tablet, alarms, is commanded; internet cut → missing in 45 s, siren still sounds locally |
| **D — Multi-central** | **deferred** (§2.5) | — | — | needs a second board |

Order: A → B → C. C and B are independent in code and may be swapped if a siren PCB is late.

## 6. Decisions owed by the product owner — **recommendations adopted 2026-10-28** (the user: "follow the recommended decisions for now, later we may modify them")

| # | Question | Recommendation |
|---|---|---|
| D1 | With the board dead, or with no rules: do sirens sound on **any** alarm, or only on linked ones? | any alarm (fail-safe floor); rules refine |
| D2 | Rule shape confirmed: causes = unit / zone / anywhere; effects = unit / zone / everything? | yes |
| D3 | Is a unit without a zona allowed to count as installed, or is zona mandatory before commissioning ends? | allowed; the walk-test report flags "sem zona" |
| D4 | May one unit belong to more than one zona? | no in v1 (one `zone_id`); zones are exclusive like panel zones |
| D5 | Remote edit of rules by an Administrador: confirmed? | yes, with §2.3 item 6 conditions |
| D6 | Endereçamento: a flat list ("1º andar") or hierarchical (bloco / andar / sala)? | flat list in v1 |
| D7 | Both blocks on one Wi-Fi channel is acceptable for the mesh bridge (when multi-central returns)? | yes |
| D8 | Who may use the customer's Wi-Fi for an island: any installer, or a decision per site? | installer, per unit, written in the report |

## 7. Open risks

- **R0 — one root session on the board** (found on the bench 2026-10-28): the board's TCP listener keeps a single root; with two level-1 units (the far unit hears the board's AP but not its sibling, so Mesh-Lite's fusion never demotes it) the two roots replace each other on the board. The tablet now shows both as ROOT; the board must accept one session per level-1 unit and send the downlink through all of them. Not in Phase A; before Phase B's bench.

- **R1 — TLS heap on an N4 island root** carrying children, NAT and the tunnel. Measure early (Phase C
  step 1); it decides whether islands need the N8R8 (reference §4.1 "if the heap test fails").
- **R2 — AWS IoT message cost** for an island at 250 units × 4 heartbeats/min. The island root should
  batch heartbeats into one message per interval.
- **R3 — settled 2026-10-28: the board sees every island frame.** The tablet re-injects each frame
  that arrives through the tunnel to the board over USB, and relays the board's downlink for island
  units back through the tunnel, so the board holds the whole site and runs every rule: an island
  detector sounds the main building's sirens and the other way round. Open detail: the board must
  tell an island unit from a mesh unit in its table (a flag per entry) so it does not try to reach it
  down the mesh.
- **R4 — Sound pattern and delays** are standard-bound (temporal-3, EN 54-3, capped delays); verify
  against purchased editions before the compliance review (reference §4).
- **R5 — Rules referencing retired / forgotten units** (§2.3 item 9) must be visible on the tablet and
  on the phone; never dropped by a sync.

## 8. Deliberately not done in this phase

- Multi-central (§2.5): no second board. Design points that it needs are carried (§2.3 item 5).
- Wired peer link: PCB note.
- Runtime family choice by the power pin (§2.1 item 4): rejected.
- An uplink (STA / Ethernet / 4G) on the board: not needed by any item above; the board stays AP-only.
- Delays, double knock, day/night: later rows of Causa e efeito.
