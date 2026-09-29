# SempreIoT — Installation Lifecycle v1

_2026-09-24. How an installation is created, shared, filled with units, read by the central, edited and
recovered — in every order, by any number of installers. Authority: below `system-blueprint-v1.md`, above
every brief. Wire details live in `docs/safr/protocol-safr-v3.md` (v3.2) and win over this file._

---

## 1. Principles

1. **Membership is holding the code.** A unit belongs to an installation when it holds the code
   (`SYSTEM_ID`, `NET_SSID`, `NET_PSK`, `SAFR_PSK`, `CHANNEL`, `MESH_ID` — blueprint §0). Nothing else
   makes it a member: not a list on a phone, not a list on the board, not the cloud.
2. **Install in any order.** Units before the board, board before units, board and tablet before any
   unit, several installers at once — all end in the same state, because every unit is provisioned the
   same way (blueprint rule 4) and the board discovers units from what it hears (rule 9).
3. **The board's device table is the roster.** It is *discovered* from authenticated traffic and
   *annotated* by the operator on the tablet. Phone-side lists are work logs. Two work logs are never
   merged; they do not need to be.
4. **The sticker `pop` is the only proof of physical authority.** It provisions a unit today. It also
   arms a fresh board from the tablet (Case B) and, later, lets the board hand the code to a new
   installer or a replacement tablet. Nothing in this document introduces an account, a role, or an
   internet dependency for installation work.
5. **Secrets never travel in clear.** The plaintext backup QR is gone. The code leaves a device only
   inside a passphrase-encrypted envelope (phone ⇄ phone, phone ⇄ tablet) or inside the `pop`-derived
   provisioning envelope (app → unit, later board → app).
6. **Protocol changes are additive.** Header, crypto and every existing message stay as they are.
   An old tablet keeps working with a new board and vice versa.

---

## 2. Actors and artefacts

| Artefact | Where it lives | What it is |
|---|---|---|
| The code | every unit (`siot_inst.code`), tablet secure storage, each installer phone's secure storage, encrypted backups | blueprint §0 |
| Sticker | printed on every unit, board included | `{id, mac, pop}`; `pop` ≥ 16 chars (resolved, §8) |
| Phone work log | installer phone, per installation | units this phone provisioned: `{mac, id, name, zone, provisionedAt}`. A log, not the roster. |
| Encrypted backup (v2) | QR on a phone or tablet screen, or text | the code + installation name, AES-128-GCM under a key derived from a passphrase (PBKDF2-SHA256, 200 000 iterations). Format `{"v":2,"kdf":"pbkdf2-sha256","iter":…,"salt":…,"nonce":…,"ct":…}`. v1 (plaintext) is read-only legacy and warned about. |
| Board device table | board NVS namespace `siot_devtab` | one entry per MAC (§3) |
| Tablet registry | Drift `MeshDevices` | a mirror of the board table plus live supervision (reference §3.6.1) |
| Admin window (Phase 3) | board | a 5-minute setup network opened by a double tap on the board so an installer with the board sticker can pull the code |
| Setup channel (USB) | board ⇄ tablet | SAFR frames under SYSTEM_ID `0x0000` keyed from the board sticker's `id` + `pop`; carries `SET_INSTALLATION` (Case B) and `GET_CODE`/`CODE` (tablet pulls the code, §4.1). Protocol §3.1. |

Personas are the blueprint's: installer (phone, offline), operator (tablet). No new ones.

---

## 3. The board device table

### 3.1 Entry

| Field | Persisted | Notes |
|---|---|---|
| `mac[6]` | key | NVS key = 12 lowercase hex chars |
| `role u8` | yes | `SAFR_ROLE_*` (0 root, 1 node, 2 leaf); `0xFF` unknown until learned from `NAME_ANNOUNCE` (§7.11 v3.2 trailing byte) or `TOPOLOGY` |
| `state u8` | partly | `expected 0 · online 1 · missing 2 · retired 3`. Only `expected` and `retired` are stored; `online`/`missing` are derived at run time from `last_seen` |
| `flags u8` | yes | `SEEN_EVER 0x01`, `ANNOTATED 0x02` (operator-set name/zone wins over `NAME_ANNOUNCE`), `PENDING_RENAME 0x04`, `HEARD_WHILE_RETIRED 0x08`, `PENDING_DECOMMISSION 0x10` |
| `first_seen u32` | yes | epoch s of the first authenticated frame, written once |
| `last_seen` | no (RAM) | drives `online`/`missing` |
| `name[33]`, `zone[17]` | yes | UTF-8, ≤ 32 / ≤ 16 bytes |

Capacity: `CONFIG_SIOT_DEVTAB_CAP`, default **120** (3 NVS entries per unit in the existing 24 KB `nvs`
partition). 250 needs a partition decision that belongs to the OTA phase (OTA blueprint §8). NVS is
written only on first sighting and operator actions.

### 3.2 State machine

| From | To | Trigger | Who |
|---|---|---|---|
| ∅ | `expected` | `/enroll` hint at board provisioning; `SET_DEVICE` or `REPLACE_DEVICE` naming a MAC never heard | phone hint / tablet |
| ∅, `expected` | `online` | first authenticated frame from the MAC (`SEEN_EVER`, `first_seen`) | board |
| `online` | `missing` | silent for 3 × its interval: AC unit 45 s; leaf 3 × its heartbeat interval; role unknown → 45 s | board |
| `missing` | `online` | any authenticated frame | board |
| `expected`/`online`/`missing` | `retired` | `RETIRE_DEVICE`; `REPLACE_DEVICE` (the old MAC); `DECOMMISSION` | tablet |
| `retired` | `expected` (never heard) / `missing` (heard before) | `UNRETIRE_DEVICE`; clears `HEARD_WHILE_RETIRED` | tablet |
| `retired` | ∅ | `FORGET_DEVICE` — refused unless `retired` | tablet |

Name and zone: `NAME_ANNOUNCE` updates them when `ANNOTATED` is clear, or when it matches the pending
values (then `PENDING_RENAME` clears). `SET_DEVICE` sets `ANNOTATED`, and sets `PENDING_RENAME` if the
unit is not `online`; the board re-originates `SET_DEVICE` to the unit on its next frame.

Retired MACs: an authenticated frame from a retired MAC sets `HEARD_WHILE_RETIRED` and is then dropped —
not journaled, not relayed to the tablet, not counted as a child. The check runs after CCM so a spoofed
header cannot set the flag. Downlink to a retired MAC is still relayed (a `DECOMMISSION` needs it).

### 3.3 What the table replaces

The ≤ 8-entry `enrolled` list (`siot_config.h`) and the RAM-only child tracker in the coordinator.
`INSTALLATION` (0x09) keeps its layout and is now encoded from the table's first entries (same cap as
today), so a pre-v3.2 tablet sees exactly what it saw before. New tablets use `DEVICE_TABLE` (0x0B),
which is paged.

---

## 4. Key custody — who can recover the code from whom

| Holder | Gets the code from | Gives the code to |
|---|---|---|
| Installer phone (creator) | generates it | units (provisioning), other phones and tablets (encrypted QR) |
| Installer phone (second) | encrypted QR from any holder; Phase 3: board admin window | units, other phones, tablets |
| Tablet | **from the board over USB** (`GET_CODE`, operator types or scans the board sticker `pop`) — the primary path, no camera or phone needed; or encrypted QR from a phone (camera only); or generates it (Case B) | board (`SET_INSTALLATION`, Case B), phones (encrypted QR) |
| Board | provisioning like any unit; or `SET_INSTALLATION` from the tablet | the tablet, over USB, after it proves the board's `pop` (`GET_CODE`); Phase 3: an installer with the board sticker (admin window) |
| Node / leaf | provisioning | nobody — units never hand out the code |
| Cloud | not in scope (Phase 4 option: store the **encrypted** v2 envelope only) | — |

The rule "the tablet never holds the PSKs" (blueprint rule 5, old text) was never true — the tablet
needs `SAFR_PSK` to authenticate frames. The honest rule, now in the blueprint: **the board never sends
the code over USB except to a tablet that proves the board's `pop`** (`GET_CODE`). The tablet learns
the roster from the board over USB, always.

### 4.1 How the code reaches the central (no camera needed)

The board has no screen and never shows a QR. The tablet may have no camera. Therefore:

1. The installer provisions the board from the phone like any unit (sticker → setup network →
   `/provision`). The board now holds the code.
2. The operator plugs in the tablet, opens Instalação → "Ler código da placa", and **types the `pop`
   printed on the board's sticker** (or scans the sticker if the tablet has a camera). The sticker is on
   the board, next to the USB cable.
3. The tablet derives the setup-channel key from `id` + `pop` (protocol §3.1), sends `GET_CODE`, the
   board answers `CODE`, the tablet stores the code and from then on authenticates every frame with it.
   Then `GET_INSTALLATION` + `GET_DEVICE_TABLE` as usual.

The `pop` step exists so that a laptop plugged into the board's USB port cannot pull the site key. The
encrypted QR from a phone is an alternative for tablets with a camera, and it is the only path for
phone ⇄ phone sharing. Case B (§5 B) needs no camera either: the operator types the board's `pop` and
the tablet writes the code it generated.

---

## 5. Scenarios

Every scenario ends with the same invariant: units hold the code, the board holds the table, the tablet
mirrors the table and holds the code. "Provision a unit" always means blueprint §3 step A2: sticker →
join `SIOT-SETUP-<id>` → `/info` → `/identify` → `/provision {code, name, zone}` → `/status = stored`
→ the unit reboots into normal mode and its setup network disappears.

**A. Phone first.** Installer creates the installation on the phone (name only; the code is generated
with `Random.secure()`, `NET_SSID = SIOT-<SYSTEM_ID hex4>`). Provisions every unit. Provisions the board
the same way; the wizard also pushes the phone's work log as `/enroll` hints → `expected` entries.
Tablet is plugged in; the operator types the board sticker's `pop` and the tablet pulls the code from
the board (`GET_CODE`, §4.1) — no camera, no phone needed. On link-up the tablet sends
`GET_INSTALLATION` (legacy) and `GET_DEVICE_TABLE`. Units come online and are discovered; `expected`
entries flip to `online`; names arrive by `NAME_ANNOUNCE`.

**B. Tablet and board first.** Operator taps "Criar instalação nesta central" on the tablet: the tablet
generates the code, asks for the board sticker (camera or typed `{id, pop}`), and sends
`SET_INSTALLATION` over USB under the **setup channel** (SYSTEM_ID `0x0000`, key
`HKDF-SHA256(ikm = pop, salt = id, info = "siot-setinst-v1")`). The board must be in SETUP (no code);
it stores the code, ACKs and reboots into normal mode. The tablet stores the code and shows the
encrypted QR; each installer scans it. Units are provisioned as in A and go `online` within seconds.

**C. Units first, board days later.** A's per-unit step, any time earlier, by any phone holding the
code. Units sit in JOINING (white solid) with no network until the board exists — the board raises the
installation Wi-Fi and nothing else does (blueprint rule 1). Battery detectors work standalone until
then (rule 10). Range can still be checked without the board: §6 survey mode. Then A's board and tablet
steps. Nothing else.

**D. Second installer.** Gets the code offline from any holder: the first installer's phone or the
tablet shows "Compartilhar" → passphrase → QR; the second phone scans it in "Entrar em instalação
existente" and types the passphrase. Each phone keeps its own work log. The board discovers every
unit regardless of which phone provisioned it. Phase 3 adds a third path: double-tap the board, join
its admin window with the board sticker, pull the code.

**E. Add a unit later.** Provision it with any phone holding the code. It appears `online` on the
tablet within seconds (AC) or on its next wake (leaf). Annotate on the tablet if the installer's name
needs fixing.

**F. Replace a failed unit.** Provision the new unit (E). On the tablet, open the old unit's card →
"Substituir por…" → pick the new unit → `REPLACE_DEVICE {old, new}`: the board copies name and zone
to the new MAC (`ANNOTATED`, `PENDING_RENAME` until the new unit re-announces), retires the old MAC,
and if the old unit is `online` originates a `DECOMMISSION` to it. The old entry stays `retired` until
the operator taps "Esquecer".

**G. Retire or remove a unit.** "Aposentar" → `RETIRE_DEVICE`: the board drops the MAC's frames from
now on and the tablet hides it from supervision. Optional "Apagar da placa" → `DECOMMISSION` (typed
confirmation, `EditorGate`, audit row): the unit erases its code and returns to setup mode. Then
"Esquecer" → `FORGET_DEVICE`. A retired unit left powered shows the badge "aposentado mas
transmitindo" (`HEARD_WHILE_RETIRED`).

**H. Rename or move to another zone.** Tablet → `SET_DEVICE {mac, name, zone}`. The board updates the
table and ACKs at once, then relays to the unit; the unit stores the new name/zone in NVS and
re-announces. If the unit is not online, the change is pending and is pushed on its next frame. A
rename on the phone only edits the phone's log.

**I. Lost or dead installer phone.** The code is recovered from: the tablet's encrypted QR; another
installer's phone; Phase 3 admin window; Phase 4 cloud escrow. If the phone is believed compromised,
re-key (M).

**J. Dead board.** Provision the new board from any code holder (phone, A3) or arm it from the tablet
(B, `SET_INSTALLATION`). Plug USB. The tablet's stored code already matches; the table is rebuilt by
discovery within about two minutes of AC units rejoining. Operator annotations were on the old board;
the tablet offers "Reenviar nomes à placa", which sends `SET_DEVICE` for every row it has a name for.

**K. Dead tablet.** The new tablet is plugged in; the operator types the board sticker `pop` and the
tablet pulls the code from the board (`GET_CODE`, §4.1). Nothing else is needed; the table arrives via
`GET_DEVICE_TABLE` as usual. A phone's encrypted QR is the alternative if the tablet has a camera.

**L. Factory-reset unit re-added.** Re-provision it (E). If it had been retired, the board keeps
dropping it and sets `HEARD_WHILE_RETIRED`; the tablet offers "Reativar" → `UNRETIRE_DEVICE`. If it
was never retired, it simply comes back `online`. Firmware note: after a reset `BOOT_CTR` restarts at 2,
so the replay table must accept a lower `BOOT_CTR` from a MAC unheard for longer than the dedupe window.

**M. Re-key (Phase 4, optional).** `REKEY {envelope, switch_at}` sent under the old key; units switch
at `switch_at`, the board last, the tablet on the operator's confirmation. `switch_at` must be at least
one full leaf heartbeat interval away so sleeping units receive it. Units offline at the switch must be
re-provisioned. **Limit:** a compromised unit that is still online receives the new key like everyone
else; re-key excludes lost or offline units, not live ones.

### 5.1 Dedup and wrong-installation guards

- A unit raises `SIOT-SETUP-<id>` **only while it has no code**. After `/status = stored` it reboots
  and the network is gone. Two installers therefore cannot provision the same unit twice; the second one
  needs a physical 5 s hold first.
- `/provision` answers `409 already_stored` once the unit is in `stored` (the seconds before reboot);
  `/info.state` shows `stored`.
- Wizard: if the scanned sticker's setup network is not on air, the app says "Este dispositivo já foi
  configurado (talvez por outro instalador). Para reconfigurar, segure o botão 5 s." and stops.
- The wizard header always shows the installation name, so a phone that holds several installations
  does not provision into the wrong one. A unit provisioned into the wrong installation is fixed by
  factory reset + re-provision; if the wrong site is in radio range it will join that site until then.
- Two work logs may both contain a MAC (reset, then re-provisioned by another phone). Harmless: logs are
  never merged and the board table is keyed by MAC.

### 5.2 Battery detectors (leafs)

- **Discovery is transport-agnostic.** A leaf's frames reach the board through its parent AC unit,
  authenticated end to end, and populate the table like any other.
- **Retire, replace, forget are immediate** for leafs — they are board-side.
- **Rename and decommission are never immediate** for a leaf: it is awake only briefly after its own
  heartbeat. These ride the parent mailbox + ACK `PENDING` bit — **specified in protocol §12.5
  (2026-09-28)**: the parent queues ≤ 4 frames per leaf, flags them in the heartbeat ACK with the count,
  and sends them right after; the board's table stays the truth and re-originates every pending
  `SET_DEVICE` / `DECOMMISSION` on the leaf's first frame through **any** parent, so a stale mailbox on
  a dead parent is harmless. Until the leaf firmware exists, the board keeps `PENDING_RENAME` /
  `PENDING_DECOMMISSION` in the table, the tablet shows "pendente: aplica quando o detector acordar",
  and remote wipe of a leaf is best effort — retire plus the physical 5 s hold is the reliable path.
- **Events raised while no parent answers are never lost:** the leaf keeps them in an outbox (16
  entries, NVS-mirrored) and delivers them, original timestamps and sequence numbers, on the next wake
  that finds a parent; the parent then holds them in custody until the board ACKs (protocol §12.6). An
  active alarm is never parked: the leaf stays awake, broadcasts if its parent is gone, and sounds.
- A leaf sends `NAME_ANNOUNCE` **once after provisioning**, not on every deep-sleep wake (a wake is a
  reboot); the "announced" flag lives in RTC memory. Leaf names otherwise come from hints or `SET_DEVICE`.
- Provisioning: same flow; the setup network stays up **2 minutes** (protocol §12.9, was 10), then the leaf sleeps with the button as its only wake source; a short press re-arms 2 minutes. After `stored` the leaf gives its verdict on the spot (§6 below, protocol §12.8).

---

## 6. Survey mode — range test without the board

**Who:** every unit type. The prober is any provisioned **AC node or battery leaf** that has **no path to
the board**: no mesh at all, or a mesh the nodes formed among themselves (Mesh-Lite elects a root even
with no board; that mesh carries nothing to the tablet). "No path" = not the root with the board's TCP
session open, and no downlink frame (TIME_SYNC / LINK_CHECK from the tablet, ACK from the board) in the
last 90 s. Its TEST button then becomes a range survey. Responders are every
provisioned unit holding the same code within reach: AC nodes, leafs that happen to be awake, **and the
board** if it is already powered (it answers on the installation channel even though it is not a mesh
node — node-to-board reach is the link that matters most). Once a unit is ONLINE, its TEST button is the
walk-test event again (reference §3.5 row 5.3).

**Leafs (protocol §12.8):** the survey is run **from** a leaf, never *to* it — a sleeping leaf answers
nothing, so the installer presses the detector, and the AC devices and the board, always awake, answer.
A press wakes the leaf and **always transmits**: an immediate blue blink, then either the walk test
(bound, parent has a path: blue sent → **cyan** = the panel confirmed, within ≈ 3 s) or the survey
(unbound or no path: one blink per answering unit in its colour, one red = nobody). A leaf that is
unbound or was last told "no path" first looks for a parent again on every press, so the first press
after the board comes back is already a walk test. No dark period on a
leaf and no white breathe: a leaf shows no LED while asleep. Right after provisioning the leaf does the
same on its own for ≤ 30 s and ends with the walk test: blue → **cyan** (the panel confirmed) or one red blink.

1. Short press → the LED goes **dark at once: the button is locked** for the whole survey. The unit
   broadcasts an authenticated `PARENT_PROBE {purpose = 1 (survey)}` over ESP-NOW, four times 1.2 s
   apart under the same MSG_ID. With no board on site every unit scans all channels for the board's
   Wi-Fi for ~3 s every ~13 s and is deaf and mis-tuned meanwhile; 3.6 s of copies outlasts one scan
   on either side, so at least one copy always lands (bench 2026-09-24). No access point, no mesh needed.
2. Every unit in range that holds the same code answers each copy with a unicast
   `PARENT_OFFER {purpose = 1, rssi_seen, layer}` and shows, once per press, **1 s solid in the colour
   of the signal it heard the probe at**: green ≥ −75 dBm, yellow ≥ −85 dBm, red below. So the
   installer standing at a passive unit sees how well *that* unit hears the pressed one.
3. The pressed unit stays dark and blinks **once per answering unit** (400 ms, in the order the first
   answers arrive) in the colour of that link's RSSI — the weaker of the two directions. Three units in
   reach = three blinks. Copies from the same unit never blink again.
4. 4.5 s after the press the window closes: one red blink if nobody answered, then the **white breathe
   returns = unlocked**. A press while the LED is dark is ignored (logged as locked). The console lists
   every answer with both directions' dBm.

The installer's whole rule: **dark = wait, breathing = press** on a node; on a detector, **press once and read the blinks** (cyan = panel, colours = neighbours, red = nothing).

What it proves: the radios reach each other at the mounted distance, and both units hold the same code
(an answer needs the key). What it does not prove: mesh throughput — a Mesh-Lite link needs a better
signal than one ESP-NOW frame, hence the conservative threshold. The message pair is the blueprint's
leaf parent-discovery pair with a `purpose` byte (protocol §7.14/§7.15); leafs use `purpose = 0`.

Transport: on a node ESP-NOW belongs to Mesh-Lite (it owns `esp_now_init` and the single receive
callback), so probes and offers go through `esp_mesh_lite_espnow_*` with SempreIoT's own data type
byte `0xD2`; the board, which has no Mesh-Lite, sends raw ESP-NOW with the same one-byte prefix. A
node's NAME_ANNOUNCE is (re)sent only once a path to the board exists, for the same reason.

---

## 7. Tablet gating and audit

- The Instalação screen (import, export, create, unlink, recover) and every device-management action
  (rename, retire, unretire, replace, decommission, forget, resend names) sit behind `EditorGate`
  (Master or Level 4 PIN).
- `DECOMMISSION` additionally requires typing the unit's name in the confirmation dialog.
- Each action writes an `AuditEvents` row (actor = the role that unlocked the gate; never the code).
- On link-up the tablet compares the board's `SYSTEM_ID` (from `INSTALLATION`, or from the
  `foreign_system` diagnostic when frames do not decrypt) with the one it holds and shows a banner
  "A placa pertence a outra instalação (0xNNNN); a importada é 0xMMMM" until resolved.

---

## 8. Open items resolved by this document

| Item | Resolution |
|---|---|
| `NET_SSID` format (brief §14 #2) | `SIOT-<SYSTEM_ID hex4, uppercase>` — the blueprint wins; the app changes. |
| `SET_INSTALLATION` ARGS (brief §14 #1) | Defined, protocol §7.6 v3.2, APP-BRIEF layout; sent on the setup channel. |
| `pop` minimum length | 16 characters in firmware (`SIOT_POP_MIN_LEN`), sticker tool and docs. |
| LED after factory reset | white blink (setup mode), same as first power-up; blueprint §8 corrected. |
| Board roster cap | 120 now; 250 waits for the OTA-phase partition decision. |
| Replace / retire / board replace (reference 7.1, 7.2) | Scenarios F, G, J. |
| Board `device_table` (brief §14 #11) | §3 of this document. |
| Admin gesture on the board | double tap (short tap is already the site-wide TEST). |

---

## 9. Limits (read before promising anything to a customer)

- Re-key cannot exclude a compromised unit that is still online (M).
- The admin window (Phase 3) replaces the installation AP for up to 5 minutes; the root loses the board
  meanwhile. It is refused while an alarm is latched, closes after the first successful pull, and is the
  last-resort path — prefer the encrypted QR.
- Retired is not removed: a retired unit that still holds the code can still join the Wi-Fi mesh; the
  board only drops its SAFR frames. True exclusion is decommission (wipe) or re-key.
- Renames and decommissions of sleeping leafs are pending until the parent mailbox exists.
- No unit confirms "online" to the phone. The wizard reaches `stored`; "online" is the tablet's word
  (blueprint rule 9 — never "assumed").

---

## 10. Phase map

| Phase | Scope | Ships alone? |
|---|---|---|
| 0 | This document; protocol v3.2 amendments; blueprint, reference, brief, app-doc line fixes | yes |
| 1 | App only: encrypted backup v2 + share/join screens (phone ⇄ phone), `NET_SSID` fix, zones saved from the wizard, `/enroll` retry + warning, dedup message, `EditorGate` on Instalação, SYSTEM_ID banner, codec groundwork for v3.2 | yes |
| 2 | Firmware: board device table, `DEVICE_TABLE`, `SET_DEVICE`/`RETIRE`/`UNRETIRE`/`REPLACE`/`DECOMMISSION`/`FORGET`, setup channel on the board (`SET_INSTALLATION` for Case B, **`GET_CODE` for "Ler código da placa"**), node handlers, `409 already_stored`, survey mode; tablet: "Ler código da placa" (type/scan `pop`), Case B UI, management UI; Drift v8 + reference §3.6.1 — implemented 2026-09-24, bench pass pending | yes |
| 3 | Board admin window (double tap: installation AP suspended, `SIOT-SETUP-<id>` for 5 min, `GET /code` encrypted for the sticker, refused within 10 min of an ALARM), phone "Entrar pela placa" — implemented 2026-09-24, bench pass pending | yes |
| 4 | Optional: cloud escrow of the encrypted envelope, `REKEY`, `/status = online` | — |
