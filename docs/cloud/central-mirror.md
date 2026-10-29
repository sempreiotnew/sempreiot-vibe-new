# Central mirror — the tablet's live picture on the user's phone (design v1)

**Status, 2026-10-03: the live map, the alarms, the firmware update (view only), the "who is
watching" eye and Identificar from the phone are in code, with tests. All but Identificar were seen
working on a tablet and a phone; Identificar has not run on devices yet. The cloud permissions of
§7 are applied. **2026-10-05:** release announcements (§4.4) and the Internet update started from
an Administrador's phone (rule 2, §4.6) are in code — design in `docs/ota/ota-internet-plan.md`;
not run on devices yet.**

A user who has access to a central opens it on the phone and sees what the tablet shows: the Rede
map with every unit, the LEDs blinking, the packets going up and down, a firmware update running.
The data travels central → AWS IoT (MQTT) → phone.

The one rule that shapes everything: **the central sends its live picture only while at least one
user is watching.** With nobody watching, nothing of it is published. The one exception: **the
alarms held on the panel, always** (decided 2026-10-03).

---

## 1. Rules

1. **On demand.** No watcher = no `state`, no `frames`, no `ota` message. Presence (`will`) and
   storage keep working as today — they are what makes the central reachable.
   **Alarms are the exception:** the list of held alarms is published on every change, watched or
   not, and retained — a user who opens the app after an alarm started gets it at once, even if
   the central has gone offline since.
2. **A mirror, not a second panel.** The phone shows; it does not command. Nothing is reset,
   silenced, renamed or retired from a phone. **Two exceptions:**
   - **Identificar** (decided 2026-10-03): it lights a unit's LED and changes nothing else (§3.3).
   - **An Internet update** (decided 2026-10-05, replacing "a firmware update is never started from
     the cloud"): an **Administrador** may start one from the phone and cancel it (§4.6). Only a
     version **published** for that central, never a file chosen on the tablet. Never over a held
     alarm. The tablet shows who started it and can pause or cancel it at any moment.
3. **Never in the fire path.** Publishing runs beside the SAFR pipeline and never delays an ACK, a
   latch or a siren. If publishing fails, the tablet carries on.
4. **Never stale as live.** Every message carries a sequence number and a time. The phone shows the
   picture as live only while the central is `online` on `will` and messages keep their sequence;
   otherwise the map is dimmed with "sem dados ao vivo".
5. **The SAFR key never leaves the site.** The central publishes what it already decoded and
   authenticated, never raw frames. The phone needs no key.
6. **One LED language.** The phone runs the same `DeviceLedEngine` on the same ticks, so a mirrored
   LED is the tablet's LED, a little later. No new colour, no new duration (CLAUDE.md, LED rule).
7. **Same widgets.** The phone reuses the tablet's screens, fed from MQTT instead of USB.

---

## 2. Topics

`{id}` is the central's Cognito identity id, as today.

| Topic | Direction | Retained | When | Content |
|---|---|---|---|---|
| `{id}/will` | central → cloud | yes | always (exists) | online / offline, wifi, usb, mesh |
| `{id}/storage` | central → cloud | yes | always (exists) | disk usage |
| `{id}/alarm` | central → cloud | **yes** | **always**: every change of the held alarms, and every new MQTT session | the alarms held on the panel (§4.5) |
| `{id}/test` | central → cloud | **yes** | **always**: every change of the running system test or of the history, and every new MQTT session | the system test running now and the last 10 (§4.7) |
| `{id}` | phone → central | no | while a phone has the central open | `watch` ping (§3) |
| `{id}/state` | central → cloud | no | watched: on hello, then on change | snapshot of every unit (§4.1) |
| `{id}/frames` | central → cloud | no | watched: every 250 ms if anything moved | frame movements (§4.2) |
| `{id}/ota` | central → cloud | no | watched: on hello, then on change (≤ 1/s) | the update run and the push to the board (§4.3) |
| `{id}/ota/history` | central → cloud | no | watched: when the phone asks | past runs (§4.3) |
| `sempreiot/releases/{channel}` | cloud → every central | **yes** | when `ota_release.sh` publishes | the catalog of published firmware (§4.4) |
| `{id}/release` | cloud → this central | **yes** | when `ota_release.sh --central` publishes | this central's own catalog (§4.4) |
| `{id}/cmd/{user}` | phone → central | no | an Administrador taps Atualizar / Cancelar | `ota_start` / `ota_cancel` (§4.6); `{user}` = the phone's Identity ID, which AWS lets only that user publish under |
| `{id}/cmd/{user}` *(planned 2026-10-28)* | phone → central | no | an Administrador edits Causa e efeito | `label_set` / `label_del` / `rule_set` / `rule_del` (§4.8) |
| `{id}/rules` *(planned)* | central → cloud | no | watched: on hello, then on change | the label tables and the rule table **as the board confirmed them** (§4.8) |
| `{id}/mesh/up` · `{id}/mesh/down` *(planned, names to settle — Phase C)* | island root ↔ central | no | always while an island exists | SAFR frames, end-to-end authenticated, tunnelled over MQTT (`phase4-cause-and-effect-brief.md` §2.4) |

Why the ping rides the bare `{id}` topic: a user's `Access_…` policy already allows publishing
there and nowhere else under the central, so no lambda and no per-user policy changes.

The central subscribes **by name** to what others send it — `{id}` and `{id}/access` — and no
longer to `{id}/#`: that wildcard also returned everything the central itself publishes, which with
the mirror would be every frame batch, delivered and billed a second time.

Snapshots are **not retained**: a retained snapshot would have to be refreshed on every change with
nobody watching (rule 1) or would lie (rule 4). The alarm list is the opposite case — it changes a
few times in an incident, and it is exactly what must not be missed — so it is retained.

---

## 3. Watching

- The phone publishes `{"type":"watch","hello":true,"sub":"…","name":"…"}` when the user opens the
  central, then the same without `hello` every **30 s** while any screen of that central is open
  and the app is in the foreground. `sub` is the user's id (the one Acessos lists), `name` the
  account the user signed in with.
- **Watching = having the central open**, on any of its tabs (Principal included), not only on the
  map. It starts the moment the central is opened from Centrais.
- **Leaving says so.** When the user goes back to the home page (or the app goes to the
  background) the phone publishes `{"type":"unwatch"}` and unsubscribes; the central drops that
  phone at once and, if it was the last one, stops streaming at once.
- The **75 s** timeout (two missed pings plus margin) is only for a phone that vanishes without
  saying so: killed, no signal. Several phones = one stream; all of them receive it.
- **What leaving does not close:** the always-on channel. The alarm list (`alarm`, retained) is
  not part of the watch — the phone keeps it subscribed on the home page and on Centrais. Anything
  the home page is to show later (alarms, troubles, events of every central) belongs on that
  always-on side, published on change like `alarm`, never on `state` / `frames`.
- `hello` asks for the snapshots again (`state`, `ota`), so a second phone joining a running stream
  gets its starting picture. At most one snapshot per second, whatever the number of hellos.
- A phone that is closed, killed or without signal simply stops pinging. Leaving the central's
  screens also **unsubscribes** from `state` and `frames`, so a phone stops receiving (and AWS stops
  billing its deliveries) even while another phone keeps the stream open.
- After a reconnect of the central (new MQTT session) the watch list is empty; phones' next ping
  restarts the stream, and a phone that sees `will` go `online` sends a `hello` at once.

### 3.1 The eye on the tablet — who is watching

The tablet's top bar carries an eye (`mirror_watchers_button.dart`): **crossed out = nobody is
watching and nothing of the map is being sent; lit with a number = that many phones are watching
and the map is being sent.** A tap lists them: name, id, access level (from the central's own
Acessos list) and since when.

The central keeps one entry per `sub` and drops it when that phone says `unwatch`, or 75 s after
its last ping. The name and the id
are what the phone says of itself — a label for the operator, not a proof of identity; the access
itself is enforced by the IoT policy, not by this list.

### 3.2 Counting the messages

Both builds print one line a minute on the console whenever any MQTT message was sent or received
(`core/utils/mqtt_stats.dart`):

```
[MQTT] last 60 s — sent 214 msgs, 71 KB, 221 billed (frames 211 · state 3) · received 2 msgs, 0 KB, 2 billed (watch 2) · ≈ 13380 billed/h at this rate
```

"Billed" counts as AWS does (one unit per 5 KB started). A minute with no message prints nothing —
which is what the tablet shows with nobody watching. The account's totals are in CloudWatch,
namespace `AWS/IoT`, metrics `PublishIn.Success` and `PublishOut.Success`.

### 3.3 Identificar from a phone

The phone's unit menu has **Identificar** (mains units that are in communication, as on the
tablet). It does not send a frame itself — it asks the central:

1. The phone publishes `{"v":1,"type":"identify","mac":"…","sub":"…","name":"…"}` on `{id}`.
2. The central accepts it only from a phone that is watching, one request per unit at a time, and
   answers at once with the event `["identify_sending","<mac>",0]` — "heard". For a unit it knows,
   hears and that is not a battery detector it then sends IDENTIFY (10 s) the same way its own
   menu does, and writes an audit line (`remote` / `identify`, with who asked).
3. The blink starts only when the **unit itself** confirms — its own ACK relayed up by the board
   (2026-10-15; the board's ACK only says it relayed the command: a unit that just died blinked on
   the screens alone). The tablet's LED engine starts it and the mirror
   carries it to **every** watching phone as an event in the next frame batch
   (`"events":[["identify","<mac>",10]]`); each phone's LED engine starts the same blue blink. An
   Identificar pressed on the tablet reaches the phones the same way.
4. No confirmation from the root: `["identify_failed","<mac>",0]`, and the asking phone says "sem
   confirmação do root" (also when nothing follows the "heard" for 15 s). The board took it but the
   unit never answered: the command's own red step (`command` event, "sem resposta", after 15 s on
   the tablet) — the phone never gives a verdict of its own.
5. No "heard" within 6 s: the phone says "a central não respondeu" — the central is offline, or
   its app is a build that does not know the request. **Both apps must carry this feature: the
   tablet's build as well as the phone's.**

A batch that carries an event is sent QoS 1 (an event is not repeated by the next batch).

**Every command's steps, since 2026-10-08.** The tablet follows each command it sends to a unit
(`device_command_provider.dart`: Identificar, Testar, Silenciar / Ligar som, Rearmar — from its own
popover or a phone's request) and publishes every step as `["command", mac, kind × 16 + step, who]`:
kind 0 Identificar · 1 Testar · 2 Silenciar · 3 Ligar som · 4 Rearmar (5–7 are what a unit sent — never published, each phone derives them from the ticks); step 0 sent · 1 the board took
it · 2 the unit confirmed it (its own ACK) · 3 the test came back · 4 no confirmation; `who` = the
phone user who asked, absent for the tablet. The phone puts it into its own tracker — learning a system test's membership from the events themselves (the broadcast's `sending` opens the list, every unit status of the same command joins it), so outcomes stay for the whole test, the tally counts them and they leave together, as on the tablet; a phone never invents a verdict past the window, it waits for the tablet's — so its Rede map
draws the same pill, checks and rings as the tablet; the command packets themselves arrive as ticks
(a COMMAND going down, the unit's ACK coming up). A phone still asks only for Identificar, as above;
the `identify*` events stay for phones of older builds.

The level of the user is not checked: any accepted user may identify (open decision D3).

---

## 4. Messages

All JSON, all with `"v":1`. Field names are short on `frames` only, where size is the cost.

### 4.1 `state` — the units

```json
{"v":1,"seq":41,"at":"2026-10-03T21:00:05.236Z","link":"connected",
 "units":[{"mac":"AA:BB:…","role":"node","layer":1,"parent":null,"rssi":-58,"bat":null,
           "online":true,"heard":true,"awaiting":false,"updating":false,"lastSeen":"…",
           "alarm":false,"alarmAt":null,"name":"Hall","zone":"Térreo",
           "product":3,"hw":1,"fw":"0.2.1","boardState":2,"boardFlags":0,
           "candidates":[["CC:DD:…",-61]]}]}
```

One entry per `TopologyNode` (`topology_provider.dart`), same fields; absent = null / false / 0.
`awaiting` (2026-10-08): known from the board's table only, never heard by the tablet — `layer` is
then -1, the unit is counted "aguardando o primeiro sinal" and not drawn in the tree.
`link` is the board link (`serialLinkProvider`): with the cable down every unit is offline on the
phone too.

`commands` (2026-10-14, absent when there is none): every command of the tablet still on the map —
a system test (`FF:FF:FF:FF:FF:FF`, first) with each of its units, an Identificar, a Rearmar — as
`{"mac":"…","wire":<DeviceCommandStatus.wire>,"by":"<phone account>","note":"2 confirmaram · 1 pendente"}`.
The steps still travel as `command` events (§4.2) as they happen; the snapshot is for a phone that
joins in the middle of a test (or asks for the snapshot again after a lost batch): it starts with
the clocks, the ticks and the Central's tally, not only with what moves from then on. The tracker on
the phone ignores a step it has already passed, so a snapshot older than the events never goes back.

When it is published, while watched:

- on `hello`;
- when the map changes — a unit appears, goes missing, alarms, is renamed, changes parent, the
  board link changes — at most once per second;
- every 30 s when only what every heartbeat changes moved (last seen, dBm). Between two snapshots
  the phone keeps "last seen" moving by itself, from the frames it replays.

Size: about 250 bytes per unit — 12 KB for 50 units, 60 KB for 250, in one message (AWS limit:
128 KB, about 500 units).

### 4.2 `frames` — what moved

```json
{"v":1,"seq":1207,"t0":1791061205236,
 "ticks":[[0,"AA:BB:…",0,0,0,"11:22:…",2,null,5310],[180,"AA:BB:…",1,0,1,null,1,null,null]]}
```

`events` (optional) carries what is not a frame movement: `["identify_sending", mac, 0]`,
`["identify", mac, seconds]`, `["identify_failed", mac, 0]` and `["command", mac, kind × 16 + step,
who?]` (§3.3).

One tick = one `SafrTrafficTick` (`safr_traffic_provider.dart`):
`[ms since t0, mac, direction (0 up, 1 down), severity, ack, parentMac, msgType, eventCode, uptimeS]`.
The phone replays the ticks with their offsets into its own traffic bus; the LED engine and the
packet animation consume them unchanged. A gap in `seq` = frames were lost: the phone asks a
`hello` and carries on.

A batch closes every 250 ms, or earlier at 50 ticks (about 4 KB — one batch stays inside one
AWS-billed message of 5 KB), and is not sent when empty. QoS 0: a lost batch is not resent, the
next snapshot repairs what it changed.

### 4.3 `ota` — the update

```json
{"v":1,"seq":4,
 "run":{"runId":"…","all":true,"phases":["board","node"],"phase":1,"target":"…",
        "targets":{"node":"0.2.1"},"queues":{"node":["AA:BB:…"]},
        "units":[{"key":"AA:BB:…","family":"node","state":"downloading","percent":43,
                  "attempts":1,"before":"0.2.0","version":"0.2.0"}],
        "stage":"rolling","pausedBy":"alarm","message":"…","startedAt":"…","startedBy":"master"},
 "push":{"phase":"sending","chunksDone":30,"chunksTotal":120,"bytesDone":30000,"bytesTotal":120000}}
```

Since 2026-10-05 it also carries `releases` (the published versions the central may install:
version, date, who published, notes, `mine` for one-central releases, sizes — no keys or hashes) and
`updates` (what the central's badge counts: the units per family below the highest version).

`run` is the tablet's `DeviceUpdateRun` (`device_update_state.dart`), every field; `null` = no
update on screen. `push` is the image on its way from the tablet to the board — only its phase and
how far it is; `null` = none. The image itself, the steps of the push, its log lines and the
board's rollout table stay on the tablet.

While watched the central looks at the update once a second and publishes when it is not what it
last sent (and on `hello`): a percent that moves ten times in a second is one message. With nobody
watching the update is not even read.

`ota/history` answers `{"type":"ota_history"}` from a phone: the rows of `OtaRuns` and
`OtaRunUnits`, newest first, the last 20 updates or as many as fit in 100 KB. The phone asks when
its "Atualizar dispositivos" opens and when a run ends. Nothing is stored in the cloud, so
`syncedAt` stays unused.

On the phone "Atualizar dispositivos" is the tablet's screen, view only: the map with the ring and
the phase on the unit being updated, the pill, the bar with the same words, a unit's details and
its past updates, Registro → Histórico. No Pausar / Retomar / Concluir, no "Firmwares no
tablet"; choosing, "Atualizar" and Cancelar only for an Administrador, Internet only (§4.6). The line on Rede ("Atualização de firmware em
andamento · Abrir") is there too.

### 4.4 `release` — a new firmware exists

**Built 2026-10-05** — `docs/ota/ota-internet-plan.md` (design), `docs/ota/ota-tools.md` (the
script).

- **What it is:** the catalog of every published version — one retained message per channel for
  every central, plus one on `{id}/release` for a single central. It is published by
  `firmware/tools/ota_release.sh`, never by a phone or a central, and nothing polls.
- **Where the images are:** the private bucket `sempreiot-releases`, organised by version.
- **What the central does with it:**
  - It downloads the highest version of each family into "Firmwares no tablet".
  - It checks hash, family and version.
  - It counts the units below that version for the badge on "Atualizar dispositivos".
- **What the phone gets:** the published versions and the count, inside `ota` (§4.3).

### 4.6 An Internet update from a phone (`{id}/cmd/{user}`)

```json
{"v":1,"type":"ota_start","id":"muvia60t-1","all":true,"name":"…"}
{"v":1,"type":"ota_start","id":"…","family":"node","version":"0.3.4","units":["AA:BB:…"],"name":"…"}
{"v":1,"type":"ota_cancel","id":"…","name":"…"}
```

- **Who is asking.** The topic's last level is the phone's Identity ID. `SempreIoTCognitoPolicy`
  allows `topic/*/cmd/${cognito-identity.amazonaws.com:sub}`: a user can publish there only under
  its own ID. The central reads who asked from the topic, never from the payload (`name` is only
  the label it shows).
- **Who may.** The central looks that Identity ID up in its access relations. It must be an
  accepted Administrador (`LEVEL_4`) or Master; anyone else is refused.
- **The checks after that.** The version must be published for this central. The controller's own
  blockers apply (a run, a push, a rollout, a held alarm). The units must be ones the central knows.
- **The run itself.** The same `DeviceUpdateController.start/startAll` as the tablet's, with
  `source = internet` and `startedBy = remote:<name>`. The tablet shows "Atualização iniciada
  remotamente por …" over the run.
- **The answer.** It goes back as an `ota_answer` event on `frames`: `working` at once, then
  `started` or `refused` plus the reason. The phone waits up to 8 s for `working`, then up to
  3 min, because the central may have to download the images first.
- **Audit.** Every start, cancel and refusal is in the audit trail, with the user's Identity ID.
- **On the phone.** An Administrador sees the Internet bar (no Manual, no "Firmwares no tablet")
  and the same update sheet, without a PIN, plus **Cancelar** while a run goes. Everyone else sees
  what is available and "Só um Administrador desta central pode iniciar uma atualização pela
  internet." Code: `remote_ota.dart` (the central), `central_mirror_viewer.dart` `sendOtaStart` /
  `sendOtaCancel` (the phone). Tests: `test/central/remote_ota_test.dart`, the "from a phone" group
  of `test/ota/device_update_controller_test.dart`, `test/central/central_mirror_screen_test.dart`.

### 4.7 `test` — the system test (2026-10-14)

```json
{"v":1,"at":"2026-10-14T18:42:05.236Z",
 "running":{"id":"63f2…","started":"2026-10-14T18:41:50.000Z","verdict":"running","boardAcked":true,
            "units":[{"mac":"AA:BB:…","name":"Sirene Hall","outcome":"confirmed","at":"…"},
                     {"mac":"CC:DD:…","name":"Detector Cozinha","outcome":"pendingWake"}]},
 "recent":[{"id":"…","started":"…","ended":"…","verdict":"passed","units":[…]}, …]}
```

`running` (absent = no test runs) and `recent` (the last 10, newest first) are `SystemTestRun`
(`domain/system_test/system_test_run.dart`): `verdict` = `running` / `passed` / `failed` /
`cancelled`; a unit's `outcome` = `pending` / `pendingWake` (a battery detector, on its next wake) /
`confirmed` / `noAnswer` / `missing` (offline when the test started) / `cancelled`; `by` = the phone
account that started it (absent = the tablet). Retained, QoS 1, written on every change of either
and on every new MQTT session — **with nobody watching too**, like `alarm`: a phone that opens the
central, or is reloaded, in the middle of a test reads it the moment it subscribes, whatever the
timing of `state` and `frames`. On the phone it **seeds the command tracker** (the map's clocks and
ticks, the Central's tally) through the same door as the `command` events, so nothing already passed
goes back; the Central's popover lists it under "Últimos testes" and the report sheet opens by
itself when a running test ends, on the tablet and on the phone alike. Cancelling is the tablet's
alone (the popover's "Cancelar teste"); a phone only looks.

Size: about 90 bytes per unit per run — 11 runs × 50 units ≈ 50 KB (AWS limit 128 KB; the tablet
keeps every run in its database, the message carries the last 10).

### 4.8 Causa e efeito from a phone (`{id}/cmd/{user}`) — planned 2026-10-28

The third exception to rule 2 (after Identificar and the Internet update), decided 2026-10-28:
an **Administrador** may create, change and delete zones, endereçamentos and rules from the phone
(protocol §14). Same path and same proof as §4.6: the phone publishes on its own `{id}/cmd/{user}`
topic, the central reads who asked from the topic, checks Nível 4 in its access relations, applies the
change to the board over USB and publishes the tables the board sent back on `{id}/rules`.

- **The central must be online.** A change with the central offline is refused with a message on the
  phone, never queued: nobody may believe a rule is active that the board never received.
- **The phone shows the tables as the board confirmed them** (`RULE_TABLE` / `LABEL_TABLE` pages),
  never as submitted; the ✓ on the matrix waits for the page.
- The tablet shows who changed what; every change goes in the audit trail (`actor = remote:<name>`).
- Payload: `{cmd: 'rule_set', rule: {...}}` etc. — one record per message, the same fields as the
  protocol record; the central encodes the SAFR COMMAND.

### 4.5 `alarm` — the alarms held on the panel

```json
{"v":1,"at":"2026-10-03T21:00:05.236Z",
 "alarms":[{"mac":"CC:DD:…","name":"Hall","zone":"Térreo","since":"2026-10-03T20:59:41.000Z"}]}
```

The units whose alarm is latched (protocol §7.1.4): held until the operator resets at the tablet,
whatever the sensor says afterwards. Retained, QoS 1.

- Published on every change of the list — an alarm latches, the reset clears — whether anyone is
  watching or not. After the reset the retained message is the **empty list**, not a deleted one,
  so a phone that is connected sees the alarm end.
- Published again on **every new MQTT session** of the central: an alarm that latched while the
  tablet had no internet reaches the cloud the moment it is back, and a restarted tablet rewrites
  what the broker holds.
- The central's Last Will does not touch this topic: if the central drops during an alarm, `will`
  says offline and `alarm` still says what was held.

On the phone: an **ALARME** badge on the central's card of the Centrais list, and the alarm banner
on its Principal (the tablet's banner without "Rearmar"). A unit in alarm is also red on the map,
from `state`.

What this is not: a notification. With the app closed the phone shows nothing until it is opened
(§8 D5).

---

## 5. The user's view of a central (phone)

After the user picks a central on **Centrais**, the phone shows **the same shell as the tablet**:
the same app bar, the same bottom bar — **Principal · Dispositivos · Rede** — and the same screens,
fed by the mirror. The back arrow returns to Centrais.

Above Dispositivos and Rede a strip says when the picture is not live: "Conectando à central…",
"Central sem conexão — última imagem há …", "Sem conexão com a nuvem". The units are then drawn
without communication (rule 4).

Menu and actions — what a user gets:

| Item on the tablet | On the phone | Why |
|---|---|---|
| Principal, Dispositivos, Rede | shown | the mirror |
| Armazenamento | shown (exists) | already published |
| Informações | not yet | the central does not publish it yet |
| Atualizar dispositivos | shown, **view only** — no choosing, start, pause, cancel; no "Firmwares no tablet" | updates start on site |
| Sobre, theme | shown | the phone's own |
| **Instalação** | hidden | joins the central to an installation: on site only |
| **Logs seriais** | hidden | raw packets and key diagnostics stay on site |
| **Bloquear central** (lock button, PIN) | hidden | locks the tablet's own screen |
| Acessos | hidden | the operator at the tablet grants access |
| Identificar | **shown** — asked to the central, which sends it (§3.3) | lights an LED, changes nothing |
| Other unit actions (rename, zone, test, RESET / Rearmar, silence, retire, Sincronizar com a placa) | hidden | rule 2: no command from a phone |
| A tap on a unit | its basics, Identificar and the Dispositivo screen, read only | — |

What cannot be mirrored, as on the tablet: survey blinks, setup, button hold — they never cross the
wire (see the header of `device_led_provider.dart`). The **IDENTIFY blink** is mirrored: the
tablet starts it on the root's ACK, which is not a tick, so it travels as an event (§3.3).

Not built in step 2: the counters of Principal (placeholders on the tablet too), the event history.

---

## 6. Cost

A 50-unit site moves about 3 frames per second (mains units every 15 s, detectors every 60 s).

| | Messages | Data |
|---|---|---|
| Nobody watching | 0 — plus one retained `alarm` message per alarm, per reset and per reconnect of the central | 0 |
| One phone watching, per hour | about 14,000 from the central, the same number delivered to the phone, 120 pings | about 2 MB |

AWS IoT bills per message (about US$ 1 per million, to be confirmed on the bill), so one hour of
watching costs about three cents; a second phone on the same central adds only its deliveries.

---

## 7. Cloud changes

| Change | Repository | Live in AWS |
|---|---|---|
| **Central policy**: publish on `state`, `frames`, `ota`, `ota/*`, without retain | done (`lambda/central/policies.mjs`) | **applied 2026-10-03** (`Central_central-002` v7, `Central_central-003` v8) |
| **Rule `telemetry_2` disabled** | — | **applied 2026-10-03** |
| **Central policy**: publish **and retain** on `alarm` | done (`lambda/central/policies.mjs`) | **applied 2026-10-03** |
| **Central policy**: publish **and retain** on `test` (§4.7) | done (`lambda/central/policies.mjs`, 2026-10-14) | **applied 2026-10-14** with `tools/cloud_test_topic_policy.sh` (`Central_central-003` v11, `Central_central-002` v10). It had to go BEFORE the build of 2026-10-14 reached a tablet — without it the tablet is dropped the moment it connects (it publishes `test` right after `alarm`), reconnects and is dropped again: seen on the bench 2026-10-14 as "wifi: limited" flapping |

**A policy goes live before the build that needs it:** AWS IoT closes the connection of a client
that publishes where its policy does not allow. A tablet whose build publishes a topic its policy
lacks is dropped, reconnects and is dropped again — its presence flaps and nothing of the cloud
works until the policy is updated.

**Seen 2026-10-03, not fixed:** the live `Central_central-002` does not allow `storage` (the
repository's builder and `Central_central-003` do). A tablet signed in as central-002 is dropped
each time it publishes its storage snapshot.

Why the rule goes: it copies every MQTT message of the account (`FROM '#'`) into the `Telemetry`
table under one fixed key, and each row wakes a lambda that only logs it. Nothing reads that table.
With the mirror it would have stored and billed every frame batch.

Both live policies already hold five versions (the AWS limit), so the oldest one is deleted before
the new version is created.

Not needed: any change to the user policies (`Access_…`, `SempreIoTCognitoPolicy`) or to the access
lambdas.

Left for later: an IAM user with limited rights for cloud administration (today the root user).

**2026-10-05 (OTA through the Internet), applied with `firmware/tools/ota_cloud_setup.sh`:**
- `Central_*`: Subscribe + Receive on `sempreiot/releases/*`. Also in `lambda/central/policies.mjs`.
- `SempreIoTCognitoPolicy`: Publish on `topic/*/cmd/${cognito-identity.amazonaws.com:sub}` (§4.6).
- The identity pool's role: read the release images (each central only its own private folder).
- The release script publishes as the person who runs it (`aws login`).

---

## 8. Open decisions

| # | Question | State |
|---|---|---|
| D1 | Alarms with nobody watching | **Decided 2026-10-03: always published, retained** (§4.5) |
| D2 | The menu of §5 | **Decided 2026-10-03: Instalação, Logs seriais, Bloquear central (and Acessos, unit actions) are hidden** |
| D3 | Do access levels (1–4) change what a user sees, and who may Identificar? | Open — every accepted user sees the same and may identify |
| D4 | A history of frames in the cloud (replay, audit) — needs always-on publishing and its cost | Open — none |
| D5 | A notification on the phone with the app closed (push) when an alarm latches — needs a cloud rule on `alarm` and a push service | Open — today the alarm is shown when the app is opened |

---

## 9. Build order

1. **This page and the cloud permissions.** Done 2026-10-03.
2. **Live map and alarms.** Central: watch list, `state`, `frames`, `alarm`
   (`central_mirror_publisher.dart`). Phone: the tablet's shell inside a central, Principal /
   Dispositivos / Rede fed by the mirror, the reduced menu, the alarm banner and badge
   (`central_mirror_viewer.dart`). Format: `central_mirror_codec.dart`; tests:
   `test/central/central_mirror_test.dart`. **Seen working on a tablet and a phone,
   2026-10-03.**
3. **Updates and who is watching.** `ota`, `ota/history`, the phone's view-only "Atualizar
   dispositivos"; the eye on the tablet; the per-minute message count. Seen working 2026-10-03.
4. **Identificar from the phone**, and the IDENTIFY blink mirrored (§3.3). **In code 2026-10-03,
   not run on devices yet.**

5. **Releases and the Internet update from a phone** (§4.4, §4.6). **In code 2026-10-05**, not run
   on devices yet.
