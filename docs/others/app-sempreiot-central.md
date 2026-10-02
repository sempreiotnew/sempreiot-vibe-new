# SempreIoT Central App — Engineering Documentation

_Generated 2026-09-14 from a full read of the source. Keep it next to `protocol-safr-v3.md` and update it when the provisioning contract or the pipeline changes._

Source snapshot: `mobile/sempreiot_central_app/` (Flutter, Riverpod 2, Drift, Amplify Auth). Paths below are relative to `lib/` unless noted. Everything here comes from reading the code; where intent is inferred it says "appears to".

> Scope note: a few cosmetic/generated files were not reviewed for this doc (`core/theme/app_colors.dart`, `theme_ext.dart`, `app_text_styles.dart`, `auth_exceptions.dart`, `sign_up_result.dart`, `i_storage_repository.dart`, `app_search_bar.dart`, `wizard_buttons.dart`, `auth_form_widgets.dart`, `register_screen.dart`, `forgot_password_screen.dart`, `app_database.g.dart`, `test/safr/safr_v3_vectors_test.dart`). Nothing below depends on their contents.

---

## 1. Purpose and the two operating modes

The app is a fire-alarm **central** (control panel UI) for an ESP32 esp-mesh-lite network of smoke/heat detectors, plus a remote **viewer/operator** app for phones and web. One codebase, two builds, selected at compile time:

| | CENTRAL mode | APP (viewer) mode |
|---|---|---|
| How selected | `--dart-define=APP_MODE=central` → `AppConfig.isCentral` (`core/config/app_config.dart`) | default (`APP_MODE` absent or anything else) |
| Root widget | `main.dart` `_CentralRoot` → `centralInitProvider` → `MainScreen` | `_AppRoot` → `appInitProvider` → `MainScreen` or `LoginScreen` |
| Identity | Machine Cognito user from the `iot` metadata row (`iot_client_id`/`iot_password`, provisioned via `FACTORY` dart-define) — `CentralCredentialsService` | Human Cognito user via Amplify (email/phone/password, Google, Apple) |
| Serial / SAFR | Yes — `safrIngestProvider`, `supervisionProvider` started in `centralInitProvider`; `SerialNotifier` opens the first USB device | Never (`SerialNotifier._init` returns on web; providers are never read) |
| MQTT | `centralIotConnectionProvider` connects immediately at startup, regardless of lock | `iotConnectionProvider` connects after auth + user sync |
| Screen lock | 6-digit **unlock PIN** overlay (`_PinOverlay` in `main_screen.dart`) gates the UI; MQTT/serial run underneath | None — Cognito session |
| Bottom tabs (`MainTab.tabs`) | Principal, Central*, Dispositivos*, Rede, Eventos (*placeholders) | Principal, Centrais |
| Drawer extras | Armazenamento, Informações, Acessos (badge = pending requests), Logs seriais | Configurar Dispositivo (provisioning wizard; hidden on web) |
| Theme / prefs keys | one global key | keyed per Cognito `userId` |

Mode is decided once, by `String.fromEnvironment`, and every branch is a plain `AppConfig.isCentral` check spread through UI and providers (`networkStatusProvider`, `themeProvider`, `MyQrScreen`, `MainDrawer`, `MainAppBar`, `centralStatusPublisherProvider`, etc.). There is no runtime switch.

A third *sub-mode* exists inside APP mode: `MainScreen(centralId: <identityId>)` pushed from `CentralsListScreen` for an ACCEPTED central. It shows the central dashboard with a reduced drawer (`MainTab.centralDetailTabs`), no bottom nav, and all status comes from that central's retained MQTT payloads. If the relation stops being ACCEPTED (BLOCKED arrives over MQTT), `MainScreen` pops to root ("acesso revogado").

Build-time knobs: `APP_MODE`, `FACTORY` (JSON applied to the metadata table on every boot in central mode — factory-reset semantics), `DEVICE_AP_URL` (provisioning mock), `SAFR_ALLOW_PLAINTEXT` (bench only). `.env` (loaded by `flutter_dotenv`) carries Cognito/IoT endpoints.

---

## 2. Architecture overview

### Folder layout

```
lib/
  main.dart                      app entry, mode split, centralInitProvider
  core/
    config/      app_config.dart (dart-defines), amplify_config.dart (Amplify JSON built from .env)
    connectivity/ connectivity_provider.dart (interface present?), network_status_provider.dart (offline/limited/online)
    database/    app_database.dart (Drift schema v10 + helpers)
    services/    sigv4_signer.dart (presigned WSS URL for AWS IoT)
    theme/       app_theme.dart, theme_provider.dart (+ missing app_colors/theme_ext)
    utils/       mqtt_log.dart (structured debugPrint for MQTT)
  features/<x>/{application,data,domain,presentation}
    app/           app_init_provider.dart (APP-mode startup sequence)
    auth/          Amplify Cognito auth (repo impl, notifiers, user_api_service)
    access/        users<->centrals relationships, QR screens, add/rename sheets
    centrais/      CentralsListScreen (APP mode)
    central/       everything the panel does: SAFR domain, serial/ingest/downlink/supervision,
                   central MQTT session, credentials/PINs, panel screens
    iot/           MQTT-over-WebSocket repository, presence, credentials
    provisioning/  SoftAP device-provisioning wizard (APP mode)
    storage/       Android internal-storage gauge, remote snapshot via MQTT
  presentation/    screens/{auth,main,splash}, widgets/iot_network_animation.dart  (shared shell UI)
  shared/widgets/  pin_pad.dart, presence_indicator.dart
```

The `CLAUDE.md` rules say AppSync/GraphQL; the code does **not** use AppSync at all — backend calls are plain `http` to Lambda function URLs behind `https://api.sempreiot.com`, and real-time is a hand-rolled MQTT 3.1.1 client over WebSocket.

### State management — Riverpod providers that own something

| Provider | File | Owns |
|---|---|---|
| `authNotifierProvider` (AsyncNotifier) | auth/application/auth_provider.dart | Cognito session, 20-min silent refresh timer, sign-in/out |
| `loginNotifierProvider`, `registerNotifierProvider` | auth/application | form state machines (sealed states) |
| `appInitProvider` | app/application/app_init_provider.dart | APP startup: auth → `POST /user` → MQTT connect; false = show login |
| `iotMqttRepositoryProvider`, `iotConnectionProvider`, `iotMessageStreamProvider(topic)` | iot/application/iot_provider.dart | user MQTT session (singleton `IotMqttRepositoryImpl`), reconnect loop (5 s), per-topic streams |
| `centralMqttRepositoryProvider`, `centralIotConnectionProvider`, `centralMqttMessagesProvider` | central/application/central_iot_provider.dart | central's machine MQTT session, subscribes `{identityId}/#`, publishes retained presence |
| `presenceStatusProvider(id)`, `centralLiveStatusProvider(id)` | iot/application/presence_provider.dart | decoded retained `{id}/will` payload |
| `savedCentralsProvider` | access/application/user_access_provider.dart | APP-mode list of centrals (SharedPreferences cache keyed by user, backend sync, MQTT `access-response` listener) |
| `requestAccessProvider`, `lookupProvider(subId)` | same | publish access request; `GET /lookup` |
| `centralAccessRelationsProvider` + derived pending/granted/blocked | access/application/central_access_provider.dart | CENTRAL-mode relationship list (backend + `access` metadata row + MQTT `/access` pings) |
| `centralIdProvider` | same | `"central-003"` derived from `iot_client_id` |
| `serialProvider`, `serialDataProvider` | central/application/serial_provider.dart | USB port, byte reframer, TX |
| `serialLinkProvider` | serial_link_provider.dart | protocol-aware link status |
| `safrIngestProvider` | safr_ingest_provider.dart | parse → DB → ACK pipeline |
| `safrDownlinkProvider` | safr_downlink_provider.dart | ACK/TIME_SYNC/LINK_CHECK/COMMAND/EVENT_LOG_REQ, pending-ACK retries, journal high-water mark |
| `supervisionProvider`, `meshLinkStateProvider` | supervision_provider.dart | offline detection per device, root freshness |
| `topologyProvider` | topology_provider.dart | graph nodes for the Rede tab |
| `safrTrafficProvider` | safr_traffic_provider.dart | broadcast bus of frame ticks for the animation |
| `otaPushProvider` (+ `otaPushTimingsProvider`) | ota_push_controller.dart, ota_push_state.dart | the firmware push to the board (protocol §13.3): file, phase, steps, counters, log, what this session saw stored on the board. Lives as long as the app, not the screen |
| `otaPushViewProvider`, `otaBannerDismissedProvider` | ota_push_report.dart | the push as every screen but "Atualização de firmware" reads it (= `otaPushProvider`; a provider of its own so a widget test hands a state over); the push whose outcome the operator closed on the Rede banner |
| `otaBoardBusProvider`, `boardDeviceProvider` | ota_board_events_provider.dart | what the board says about a push (OTA_PUSH_RESULT, its own NAME_ANNOUNCE and HEARTBEAT, each with the frame's BOOT_CTR), fed by ingest; the board's own `MeshDevices` row (product of the board family, else layer 0 with a heartbeat) |
| `otaRolloutProvider` (+ `otaRolloutTimingsProvider`) | ota_rollout_controller.dart, ota_rollout_state.dart | the rollout, board → units (protocol §13.6): per family the rollout state, the target version and one row per unit; start / pause / resume / abort; its log. Nothing stored: learned again from the board after every app start. Started in `centralInitProvider` |
| `otaRolloutViewProvider`, `otaHeldOnBoardProvider`, `otaUpdatingUnitsProvider`, `otaRolloutOverlayProvider`, `otaRolloutBannerProvider`, `otaRolloutDismissedProvider` | ota_rollout_report.dart | the rollout as the screens read it; what the board holds (its `OTA_ROLLOUT` headers, else this session's memory of a push); who is being updated and since when (supervision, "Atualizando"); what the Rede maps and their banner draw |
| `otaRolloutBusProvider`, `linkUpSequenceProvider` | ota_rollout_events_provider.dart | `OTA_ROLLOUT` pages and the units' `OTA_STATUS` / `OTA_RESULT`, fed by ingest; a counter the downlink moves when its link-up sequence ended |
| `firmwareFilePickerProvider` | central/data/services/firmware_file_picker.dart | the system file chooser (`file_picker`), bytes of the chosen file |
| `deviceEventsProvider`, `deviceEventsFilterProvider`, `latchedAlarmsProvider`, `activeAlarmProvider` | device_events_provider.dart | Eventos feed (last 300), filters, alarm latch |
| `serialLogsProvider`, `serialWireDiagProvider`, `serialStatsProvider` | serial_logs_provider.dart | raw packet console + counters |
| `credentialsAdminProvider` + `auditTrailProvider`, `configuredLevelPinsProvider`, `rootUserProvider`, `unlockPinConfiguredProvider` | credentials_admin_provider.dart | hashed PINs, rate limiter, audit |
| `centralAuthProvider` | central_auth_provider.dart | unlock-PIN lock state |
| `deviceInfoProvider`, `deviceCredentialsProvider` | device_info_provider.dart, device_metadata_providers.dart | `info` / `credentials` metadata rows |
| `centralStatusPublisherProvider`, `centralStoragePublisherProvider` | central_status_publisher.dart, central_storage_publisher.dart | retained MQTT presence/storage payloads (watched by `MainScreen`) |
| `storageProvider`, `remoteStorageProvider(id)` | storage/application | Android free-space poll (30 s) / remote snapshot |
| `provisioningWizardProvider` (autoDispose) | provisioning/application | wizard state machine |
| `themeProvider`, `statusPanelArcadeProvider`, `sharedPreferencesProvider` | core/theme, presentation/screens/main | per-user prefs |
| `networkStatusProvider`, `connectivityProvider` | core/connectivity | offline / limited (no MQTT) / online |

### Persistence — Drift DB `sempreiot`, schema v10 (`core/database/app_database.dart`; catalogue of record: system reference §3.6.1)

| Table | Purpose |
|---|---|
| `SerialPackets` | every reframed serial frame, raw bytes + hex preview (forensics). Index on `received_at`. Purged >30 days. |
| `DeviceMetadata` | key/value JSON store. Keys: `info` (name, firmware_version, subId, old_subId, dates), `credentials` (salted hashes: pin, unlock_pin, password, level_pins, salt, hashed flag, root), `access` (mirror of relation list), `iot` (iot_client_id/iot_password **plaintext**), `pin_guard` (rate limiter), `safr_jrn_seq` (journal high-water mark) |
| `AuditEvents` | append-only security trail: actor (`master`/`admin`/`root`/`system`/`central`), action, JSON detail |
| `MeshDevices` | trusted registry keyed by MAC: role, layer, parent, RSSI, battery, first/last seen, last heartbeat, replay counters (`lastBootCtr`,`lastMsgCtr`), `supervisionState`, `name`, `lastDevSeq`, `alarmLatched(+At)`; v3.5 product identity (schema v10, all nullable): `productCode` (16-bit PRODUCT, high byte = family), `hwRev`, `fwVersion` — null until the unit or the board's table reports them, never overwritten by unknown/empty |
| `DeviceEvents` | humanized feed: severity 0..3, wire eventType/eventCode, `detailJson`, `packetId`, `errorKind` (crc_failed/auth_failed/foreign_system/plaintext_rejected/parse_error), `ackedAt`, `devSeq`. Purged >30 days (see Loose ends). |

Other storage: SharedPreferences (`saved_centrals_<userId>`, theme/panel keys, `iot_identity_id_*`); no secure storage anywhere.

### Screen map

```
APP mode:   SplashScreen → LoginScreen (modal login / Google / Apple / Register / Forgot)
            → MainScreen(home) ─ tab Principal (_AppDashboard, placeholder counts)
                                ─ tab Centrais → CentralsListScreen ─ FAB AddCentralSheet (+QrScannerScreen)
                                                                     ─ MyQrScreen
                                                                     ─ ACCEPTED → MainScreen(centralId) ─ drawer: Armazenamento (remote)
                                                                     ─ else → CentralStatusScreen (auto-hands off on ACCEPTED)
                                ─ drawer: Configurar Dispositivo → ProvisioningWizardScreen
CENTRAL:    Splash → MainScreen (locked, _PinOverlay) → Principal (_CentralDashboard) / Rede (TopologyScreen embedded) / Eventos (EventsScreen)
            drawer: StorageScreen, DeviceInfoScreen, DeviceAccessScreen ⟶ EditorGate ⟶ AccessPinsScreen ⟶ PinChangeScreen / AuditLogScreen,
                    SerialLogsScreen ⟶ SafrDetailScreen (also from an event card's sheet)
                    FirmwareUpdateScreen ("Atualização de firmware", §5 "Firmware push")
            Rede node sheet: IDENTIFY / SILENCE / TEST commands, rename
```

Navigation is plain `Navigator.push` with `MaterialPageRoute` — no router, no web URLs (contrary to `CLAUDE.md`).

---

## 3. Startup and auth flow

**APP mode** (`_AppRoot` → `appInitProvider`):
1. `main()` loads `.env`, configures Amplify Auth (`buildAmplifyConfig`: user pool + identity pool + Hosted UI OAuth with `openid email`, redirect `sempreiotcentral://callback` or `http://localhost:52901/` on web), loads SharedPreferences.
2. `authNotifierProvider.build` → `Amplify.Auth.getCurrentUser()`. Null → `LoginScreen`.
3. `LoginScreen`: "Continuar com Sempre IoT" opens `SempreIoTLoginModal` (email or phone + password → `USER_SRP_AUTH`; phone users are synthesised as `<digits>@phone.sempreiot`), Google/Apple via `signInWithWebUI`. Federated sign-in is refused (signed out again, `FederatedEmailConflictException`) if `GET /user/check-email` says a *local* confirmed user has that email.
4. On a user: `UserApiService().registerUser()` → `POST https://api.sempreiot.com/user` with Bearer **id token**, body `{subId, identityId, email, name}` (`lambda/user`): idempotent upsert into DynamoDB `User`, attaches the shared IoT policy to the identity (`policies.mjs`, not in snapshot), 409 on email conflict → app signs out.
5. `iotConnectionProvider.connect()` → `IotCredentialsService.fetch()` (Amplify session credentials, forced refresh every 25 min) → `SigV4Signer.buildSignedWebSocketUrl` → MQTT CONNECT. Then `SplashScreen`/`LoginScreen` push `MainScreen`.

**CENTRAL mode** (`centralInitProvider`): seed metadata defaults → apply `FACTORY` JSON if present (wipes the metadata table first) → read `safrIngestProvider` + `supervisionProvider` (which transitively construct serial, downlink, traffic) → purge rows older than 30 days → `MainScreen`, locked. Errors "fail open" to `MainScreen`. `CentralCredentialsService` (`central/data/services/central_credentials_service.dart`) authenticates the machine user with raw Cognito HTTP (`InitiateAuth USER_PASSWORD_AUTH` → `GetId` → `GetCredentialsForIdentity`), caches id token and AWS creds with 5-min margins; `getIdToken()` is the bearer for the central's REST calls.

**Lambdas / REST surface actually called by the app** (all `https://api.sempreiot.com`, Bearer = Cognito id token; no SigV4 on REST):

| Endpoint | Lambda | Who | Purpose |
|---|---|---|---|
| `POST /user` | `user` | APP on every init | register/ensure user row + IoT policy |
| `GET /user/check-email?email=|phone=` | `user` | APP (register, federated guard) | `{exists, confirmed, hasLocalUser}` via Cognito ListUsers |
| `GET /lookup?subId=&type=central` / `?identityId=` | `lookup` | APP | resolve a scanned subId to `{subId, identityId, name, type}` from `Device`/`User` tables (scan for reverse lookup) |
| `GET /access/requests?userSubId=` or `?centralIdentityId=` | `access-resolve` (GET branch) | both | all `CentralAccess` rows for a user / a central |
| `POST /access/resolve` `{action: RESOLVE|LEVEL_CHANGE|BLOCK|UNBLOCK, ...}` | `access-resolve` | CENTRAL | mutate relation, create/attach or detach IoT policy `Access_{centralId}_{userSubId}`, publish `{userIdentityId}/access-response` |
| (MQTT) `{centralIdentityId}/access` | `access-request` via IoT Rule `SELECT *, topic(1) as centralIdentityId FROM '+/access'` | APP publishes | creates PENDING row if none/rejected; silently ignores PENDING/ACCEPTED/BLOCKED |
| not called by app | `central` | ops tool (README `curl localhost:3001`) | creates the machine Cognito user `<centralId>@sempreiot.com`, identity, IoT policy, `Device` row; returns the password that goes into `FACTORY.iot` |

`SigV4Signer` (`core/services/sigv4_signer.dart`) is used only for the IoT WebSocket presigned URL (service `iotdevicegateway`, path `/mqtt`, 24 h expiry, session token appended *unsigned*, as the AWS SDKs do). `aws_signature_v4`/`aws_common` are in `pubspec.yaml` but unused.

---

## 4. Access model and security

**Entities.** A user↔central relationship is one DynamoDB row `CentralAccess(centralIdentityId, userSubId)` with `status ∈ {PENDING, ACCEPTED, REJECTED, BLOCKED}`, `level` (only when ACCEPTED), `requestId`, timestamps. In the app: `AccessRelation` (central side) and `SavedCentral` (user side, plus local nickname). Identity of a central = its machine user's Cognito **sub** (what the QR encodes); the MQTT/IoT policy side uses its **identityId** (Cognito Identity Pool). `lookup` bridges the two.

**Levels** (`access/domain/entities/access_level.dart`): LEVEL_1 Visualizador, LEVEL_2 Operador, LEVEL_3 Técnico, LEVEL_4 Administrador, MASTER (unique per central, enforced by the Lambda and re-checked in the UI). Levels currently gate nothing in the viewer app itself — every ACCEPTED user gets the same IoT policy and the same screens; the level only labels the badge.

**Flow.**
1. Central shows its QR (`MyQrScreen`, data = subId; also `DeviceInfoScreen` shows `info.subId`). User scans (`QrScannerScreen`, `mobile_scanner`) or types it in `AddCentralSheet` → `GET /lookup` → card with live `PresenceIndicator`.
2. "Solicitar Acesso" → `RequestAccessNotifier.request`: first re-reads `GET /access/requests?userSubId` and refuses locally if BLOCKED/PENDING/ACCEPTED; then publishes `{requestId(uuid v4), userSubId, userIdentityId}` to `{centralIdentityId}/access` and adds a PENDING `SavedCentral`.
3. Central (`CentralAccessRelationsNotifier`) sees any `/access` publish on its `{id}/#` subscription and, debounced 900 ms (+1 retry), re-syncs from `GET /access/requests?centralIdentityId`. Pending cards appear in `DeviceAccessScreen` (drawer badge count).
4. Operator accepts/rejects → `POST /access/resolve RESOLVE` → Lambda sets ACCEPTED+LEVEL_1, creates and attaches IoT policy granting subscribe/receive on `{centralIdentityId}` and `{centralIdentityId}/*` and publish on `{centralIdentityId}`, then publishes to `{userIdentityId}/access-response`. The user app updates the card live and `CentralStatusScreen` hands off to the dashboard.
5. Level change / block / unblock — same POST with other actions; BLOCK detaches the policy immediately; UNBLOCK flips to REJECTED (user may request again).

**PIN gates on the central** (`credentials_admin_provider.dart`, all values salted SHA-256, hashed in place on first read of a plaintext `FACTORY` row; shared persisted rate limiter: 3 failures → lockout 30 s × 2^lockouts, max 1 h; every failure audited):

| Secret | Metadata key | Used by |
|---|---|---|
| Unlock PIN (6 digits) | `credentials.unlock_pin` (seeded from master PIN on migration) | `_PinOverlay` in `MainScreen` via `centralAuthProvider` |
| Master PIN | `credentials.pin` | `EditorGate` (identifies Master), `PinChangeScreen` |
| Level PINs 1–4 | `credentials.level_pins.LEVEL_n` | `EditorGate` (LEVEL_4 identifies Administrador); change/reset in `AccessPinsScreen` |
| root + senha | `credentials.root`, `credentials.password` | granting/demoting MASTER (`_LevelChangeSheet` in `device_access_screen.dart`), editing root/senha (`_RootEditSheet`) |

`EditorGate` (`central/presentation/widgets/editor_gate.dart`) fronts `DeviceAccessScreen` and `AccessPinsScreen`; the role it returns is attached as `actor` to audits. Only Master may reset a PIN without knowing the current one (`skipCurrent`) and edit root/senha.

**Security assessment (from code):**
- Authorization for the access mutations is *client-side*: the Lambda trusts any valid Cognito token (see its own TODO about verifying the caller is the central's machine user). A user token could call `LEVEL_CHANGE` or `BLOCK` directly.
- Contrary to the comments in `access_api_service.dart`/`access_level.dart` ("PIN for the target level is verified locally"), `_LevelChangeSheet` does **not** ask for the level's PIN for LEVEL_1–4; only the screen gate (Master or Nível 4 PIN) and, for MASTER ops, root+senha. `configuredLevelPinsProvider` exists but is not consulted there.
- `iot_password` is stored in plaintext in Drift; `FACTORY` JSON (with PINs and the IoT password) appears in shell history/README.
- Viewer access is all-or-nothing at the IoT policy level; levels are cosmetic today.
- Presence (`*/will`) and storage (`*/storage`) are readable by *any* authenticated user of the pool (shared policy grant), by design.

---

## 5. Serial / SAFR pipeline (CENTRAL mode)

```
USB (usb_serial, 115200 8N1, DTR/RTS low)
  └─ SerialNotifier._drainFrames  [serial_provider.dart]
       scan 0xA5 → VER ∈ {1,2,3} → LEN 32..256 → wait → CRC (v2/v3) → emit frame; counters bytes/dropped/frames
         ├─► SerialLinkNotifier [serial_link_provider.dart]  disconnected/connecting/error/connected (latched on 1st valid frame)
         └─► SafrIngestService.handleFrame  [safr_ingest_provider.dart]
               1. INSERT SerialPackets (always)
               2. parseSafr [domain/safr/safr_parser.dart] → v1 (legacy, raw log only) | v2/v3 parseSafrWireFrame
                    CRC → SYSTEM_ID == 0x5346 → F_ENC → AES-128-CCM decrypt (safr_crypto.dart, dev PSK, nonce = SRC_MAC‖BOOT_CTR‖MSG_CTR, AAD = 30-byte header) → payload codec (safr_v2_payloads.dart)
               3. error? → DeviceEvents diagnostic row (severity 1) and stop     plaintext & !kSafrAllowPlaintext → 'plaintext_rejected'
               4. onTraffic tick → topology animation
               5. ACK payload → SafrDownlink.handleAck (resolves pending downlink)
                  EVENT_LOG_DATA → _handleJournalData (dedupe by (ORIG_SRC_MAC, DEV_SEQ), latch, feed row 'historic', jrn_seq) + downlink.handleJournalData
                  else → _updateTrustedState (transaction):
                        replay check (bootCtr == last && msgCtr <= last → drop, no row)
                        dedupe: EVENT by (mac, devSeq) against DB; others by (mac, msgId) in a 30 s in-memory window
                        upsert MeshDevices (HEARTBEAT: layer/parent/rssi/battery/lastHb, layer 0 ⇒ root; TOPOLOGY: role/layer/parent/rssi; EVENT: battery, lastDevSeq, ALARM ⇒ alarmLatched=1;
                                            NAME_ANNOUNCE: name/zone/role + v3.5 productCode/hwRev/fwVersion when the frame carries them and they say something — PRODUCT 0, HW_REV 0 or an empty version keep what is stored)
                        new EVENT ⇒ INSERT DeviceEvents (detailJson with sensors, flags, retx, hops)
               6. F_ACK_REQ ⇒ SafrDownlink.sendAck (ACK every time, even dupes/replays) and stamp ackedAt
  ▲
  └─ SafrDownlink [safr_downlink_provider.dart]  (SafrEncoder: SRC 00:00:00:00:00:01, random BOOT_CTR, MSG_ID/MSG_CTR ++)
       link-up  → TIME_SYNC (F_ACK_REQ, tracked) → EVENT_LOG_REQ(since = safr_jrn_seq, max 0) ; paginate on LAST until EMPTY
                → GET_INSTALLATION → GET_DEVICE_TABLE args `page, format` = `0, 1` (v3.5: always format 1 = entries with the product fields; an older board ignores the byte and answers in the v3.2 layout)
       hourly   → TIME_SYNC
       every 30 s → COMMAND LINK_CHECK broadcast (tracked, silent) ; edge-triggered synthetic 'link_check_failed' / 'link_check_restored'
       UI       → sendCommand(mac, IDENTIFY[10]/SILENCE/TEST) ; sendReset(broadcast) → clearAlarmLatch only if ACKed
       tracked send = same MSG_ID, fresh MSG_CTR, retry after 2 s up to 3 attempts, then 'command_unconfirmed' trouble (severity 1)

SupervisionNotifier [supervision_provider.dart]  every 5 s + on MeshDevices change:
   offline if now − lastSeenAt > 45 s (root/relay) or 180 s (leaf, or unknown role with layer ≥ 2); edges persist supervisionState and insert synthetic TROUBLE COMM_FAULT 'device_missing' / OK 'device_restored'
   EXCEPT a unit that is being updated (protocol §13.4): its row of the rollout is offered / downloading / verifying / rebooting / self-test → online ("Atualizando"), no trouble, for 300 s since the row entered those states; then the rule above again
meshLinkStateProvider: 'connected' iff serial link connected and the root device (role 0 or layer 0) is online
topologyProvider [topology_provider.dart]: nodes from supervision; role fallback layer0→root, has-children→node, else leaf; online = linkUp && online; leaf "sleeping" if online and silent > 20 s
   Leaf states per protocol §12 (2026-09-28, `docs/devices/leaf.md` §8b): `awake` (< 3 s since a frame, or alarm latched) / `sleeping` = leaf && online && !awake, with `nextWakeInSeconds` on the 60 s cadence / offline with "há X"; `parentCandidates` (Drift v9, from a leaf's bind-time TOPOLOGY) → `singleParent` / `weakLink` warnings on the sheet. Ingest keeps a known leaf's role across heartbeats and reads the NAME_ANNOUNCE role byte
   Product identity (SAFR v3.5, Drift v10): `TopologyNode.productCode` / `hwRev` / `fwVersion`, `product` = `SafrProduct.fromCode` (catalogue in `domain/safr/safr_product.dart`), `productLabel` ("Sirene · SIOT-SIREN-01") and `firmwareLabel` for the UI
```

**Product, hardware revision, firmware version (SAFR v3.5).** Two sources, both parsed in `safr_v2_payloads.dart`: the unit's own `NAME_ANNOUNCE` (§7.11; optional `PRODUCT u16 ‖ HW_REV u8 ‖ FW_LEN u8 ‖ FW` right after ROLE — a truncated extension, `FW_LEN > 24` or FW running past the payload is ignored and name/zone/role are still accepted) and the board's `DEVICE_TABLE` (§7.12; bit 7 of the COUNT byte = every entry of the page carries the same four fields after ZONE, real count = `COUNT & 0x7F`; bit clear = the v3.2 layout). `_handleDeviceTable` stores a non-zero product / non-zero revision / non-empty version field by field; every other upsert in `safr_ingest_provider.dart` copies the stored values. The catalogue (`SafrProduct`) maps code → model string, family (`SafrProductFamily`: board 0x01, node 0x02, leaf 0x03) and pt-BR label; `0x0000` = not reported; a code outside the catalogue is kept and shown as "Produto desconhecido 0x0206", with the family from the high byte. Shown as the facts **Produto** and **Firmware** ("—" when not reported) in the device menu (`widgets/device_menu.dart`, opened from Rede, Rede 3D and Dispositivos) and on the Dispositivo screen (`device_settings_screen.dart`, card IDENTIFICAÇÃO, plus "Revisão de hardware" when stated).

**Latching.** `MeshDevices.alarmLatched` is set on any accepted ALARM (live or journaled) and cleared only by `AppDatabase.clearAlarmLatch`, called from `SafrDownlink.sendReset` after the root ACKs the RESET COMMAND (alarm-hold banner on Principal — `latched_alarm_banner.dart`, broadcast — or per device from the Rede node sheet). The Eventos tab was removed on 2026-09-23. RESTORE events never touch it; the latch survives restarts. Test: `test/safr/safr_ingest_test.dart` "ALARM latches; RESTORE does NOT clear".

**Dedupe.** EVENTs: exact, persistent, by `(deviceMac, devSeq)` in `DeviceEvents` (absorbs 60 s F_RETX re-announcements and journal replays; `retx: true` recorded in detail when it does get through as a new DEV_SEQ). Non-events: `(srcMac, msgId)` in a 30 s map. Replay (nonce counters not increasing within a boot) is dropped before dedupe and produces **no** diagnostic row (the `errorKind` comment lists `replay` but it is never written).

**Implemented vs. `docs/safr/protocol-safr-v3.md`:**

| Spec item | Status in code |
|---|---|
| §3 framing, §5 CRC, §4 CCM, §3.1 SYSTEM_ID pre-decrypt drop, §4.1 plaintext rejection | Implemented (`safr_v2_frame.dart`, `safr_crypto.dart`, `crc16.dart`). Reframer min LEN is 32 (v2) not 34; `safrCrcOk` re-checks 34 for v3. |
| §6 DEV_SEQ dedupe, §7.9 journal replay through same pipeline | Implemented |
| §7.1.4 ALARM latch, RESET clears only after root ACK | Implemented |
| §7.1.4 TROUBLE cleared by matching RESTORE; root/repeater AC-loss latch | **Not implemented** — no per-device trouble state; RESTORE is just another feed row |
| §7.7 TIME_SYNC on link-up + hourly, §7.8 EVENT_LOG_REQ on link-up + pagination, journal-reset detection | Implemented; but the "re-request 3× after 5 s, then link TROUBLE" rule is **not** (no timer) |
| §7.8/§6 "gap in DEV_SEQ ⇒ request backfill" | Not implemented |
| §9.1 fast retry (3 × 2 s, same MSG_ID, fresh MSG_CTR), ACK every time | Implemented |
| §9.2 uplink supervision 3× interval | Implemented (45 s / 180 s) |
| §9.3 LINK_CHECK every 30 s | Implemented; trouble raised on the first unconfirmed LINK_CHECK (which already retried 3×), not after three consecutive misses |
| §9.3 "USB connected only if valid frame within 10 s" | **Deviates on purpose**: `serial_link_provider.dart` latches `connected` on the first valid frame and keeps it while the port is open |
| §9.4 link-quality trouble (≥5 CRC/auth failures / 60 s) | Not implemented (counters only shown in `SerialLogsScreen`) |
| §4 replay ⇒ "log diagnostic" | Dropped silently |
| Severity-priority TX queue, alarm-first rendering | Not implemented (feed is chronological; `_StatusStrip` counts last 24 h) |
| §11 append-only event history | `deleteOlderThan(30 days)` also deletes `DeviceEvents` |
| Per-installation PSK/SYSTEM_ID | Dev constants everywhere (`safrDevPsk`, `safrDevSystemId = 0x5346`); `SafrEncoder`/parser accept a key parameter but nothing supplies one |
| §13.2, §13.3, §13.7 firmware push to the board (v3.5) | Implemented on the tablet side, see "Firmware push" below |
| §13.4, §13.6 rollout, board → mains units (v3.5) | Implemented on the tablet side, see "Rollout" below. `OTA_OFFER` (COMMAND 0x1B) is the board's: the tablet never sends it. §13.5 (battery units, 2026-09-30): a leaf rollout starts like a node one; the row of a leaf that was offered reads "Aguarda a próxima ativação" until it answers on its wake; the form carries a note on what to expect (one wake to hear the offer, the pull on that wake, the self-test on the next) |
| Appendix A vectors | `tool/print_safr_v3_vectors.dart` + (missing from snapshot) `test/safr/safr_v3_vectors_test.dart` |

### Firmware push to the board (protocol §13.3, 2026-09-29)

Drawer → **Atualização de firmware** (CENTRAL mode only). The operator picks a `.bin`; the tablet reads what it is from the file, sends it to the board over the USB cable and shows every step. No database table: the state, the steps and the log live in `otaPushProvider` for as long as the app runs.

| Piece | File | What it does |
|---|---|---|
| Codecs | `domain/safr/safr_ota_payloads.dart` (a `part` of `safr_v2_payloads.dart`) | `OTA_PUSH_BEGIN` 0x0F, `OTA_PUSH_CHUNK` 0x10, `OTA_PUSH_END` 0x11, `OTA_PUSH_RESULT` 0x12, `OTA_BAUD` = COMMAND 0x1A (`BAUD u32`), `SafrOtaReason` (§13.7, with the pt-BR text of each). 0x13–0x15 and COMMAND 0x1B–0x1D are named only. `SafrAckPayload.detailRaw` / `.otaReason`: byte 3 of an ACK read as a REASON |
| CRC-32 | `domain/ota/crc32.dart` | IEEE 802.3, check value `0xCBF43926` |
| Image header | `domain/ota/firmware_image.dart` | `esp_app_desc_t` at offset 32: magic `0xABCD5432` (LE), `version` at 48, `project_name` at 80 → family (`sempreiot-board` / `-node` / `-leaf`). Anything else, or a version over 24 bytes, is refused before a byte is sent |
| Port | `application/serial_provider.dart` | `writeFrameWithData` (frame + raw bytes in ONE write), `setBaudRate` (then 150 ms), one queue for every write and speed change, back to 115200 after 20 s without a valid frame at another speed, and on every port open |
| Downlink | `application/safr_downlink_provider.dart` | `sendOta` / `sendOtaBaud`: the same pending-ACK tracking as every command, with the timeout and attempts the push asks for; no TROUBLE event on failure |
| Ingest | `application/safr_ingest_provider.dart` | `OTA_PUSH_RESULT` → `otaBoardBusProvider` (not a device to register); the board's NAME_ANNOUNCE and HEARTBEAT are also sent there |
| Controller | `application/ota_push_controller.dart` | the push, below |
| Report | `application/ota_push_report.dart` | what a push means, in words, for every screen: `otaPushReport` (what was sent, who received it, what changed, one line for the banner), `otaBoardActivity` (the board on the map), `unitFamily` / `pendingFirmwareFor` (what waits on the board for a unit), `OtaUnitGroups`, `OtaPacketThrottle` |
| Screen | `presentation/screens/firmware_update_screen.dart`, `widgets/firmware_update_widgets.dart` | below, "What the operator sees" |
| Rede | `presentation/widgets/ota_rede_widgets.dart`, `screens/topology_screen.dart`, `screens/network_3d_screen.dart`, `widgets/network_3d/*`, `widgets/device_menu.dart` | below, "What the operator sees" |

Flow: `OTA_BAUD 921600` (not confirmed → stay at 115200) → `BEGIN` (the board answers `OTA_PUSH_RESULT {receiving, NEXT_SEQ}` and then the ACK: start at `NEXT_SEQ`) → chunks of 4096, one at a time, each waits for its ACK → `END` → `OTA_PUSH_RESULT` `ok` / `failed`. Node / leaf image: "guardado na placa", then `OTA_BAUD 115200`. Board image: the port goes to 115200 by itself (the board restarts 1.5 s after its verdict and sends no ACK for a speed change), the tablet asks `GET_DEVICE_TABLE` every 5 s so the board hears it, and the push is **confirmed** by the second `OTA_PUSH_RESULT ok` (BOOT_CTR different from the one that took the image), **rolled back** by `failed` / SELFTEST_FAIL or a NAME_ANNOUNCE with another version. A NAME_ANNOUNCE with the new version alone confirms only after 150 s: the board says what it runs before its self-test (120 s) is over.

| Number | Value | `OtaPushTimings` |
|---|---|---|
| OTA_BAUD ACK | 2 s × 3 | `baudAckTimeout`, `baudAttempts` |
| BEGIN ACK | 3 s × 3 (after the cable came back, first 1.5 s × 2 at the speed the push had) | `beginAckTimeout`, `probeAckTimeout` |
| Chunk ACK | 3 s, then the same chunk again; 5 answers in a row that are not OK = failed | `chunkAckTimeout`, `chunkMaxFailures` |
| Chunk sent again | after a timeout: same MSG_ID, fresh MSG_CTR (§9.1); after BAD_CRC: a new MSG_ID | `reuseMsgIdOnTimeout` |
| END ACK / verdict | 2 s × 3 / 30 s | `endAckTimeout`, `verdictTimeout` |
| Cable out | 60 s, then failed | `linkLossTimeout` |
| Board restart to verdict | 180 s | `boardConfirmTimeout`; `selfTestWindow` 150 s from the moment the board is heard again |

**What the push does, and what the app must never suggest.** The tablet sends an image to the BOARD only. A board image is installed by the board itself. A node or leaf image is only STORED on the board: **no device is updated by a push** and nothing of the push may read as if one were. Sending the stored image to the units is the rollout, below — a separate act of the operator, with its own question.

**What the operator sees** (2026-09-29, after the first bench test: "the screen showed success but the versions are still -dev"):

- **Atualização de firmware**, top to bottom: (1) the **report card** (`OtaReportCard`), while a push runs and after it — title, then three answers: *O que foi enviado*, *Quem recebeu*, *O que mudou*; (2) **Versões em execução** (`OtaRunningVersions`): the board, then "Rede elétrica", then "Bateria", one row per unit the tablet knows (`topologyProvider`) with name, product and the firmware it runs now ("—" when it never said), and under the version "na placa: 0.1.1 (ainda não enviado)" when this session saw an image of the unit's family stored on the board with another version; a group of more than 4 folds ("Mostrar todas"); (3) **Ligação**: the cable and what is stored on the board; (4) **Arquivo** and the actions — a node / leaf file says, before it is sent, that it will only be stored; (5) **Detalhes**, folded: steps, counters, log with "Copiar". Open by itself only while a push runs and after one that failed or was rolled back.
- The card, outcome by outcome: *stored* → "Imagem guardada na placa", neutral look (never the green of a success), "Nenhum dispositivo foi atualizado … até você usar "Enviar aos dispositivos""; *confirmed* → "Placa atualizada", `old → new` (old = the board's row when the push began, `OtaPushState.boardVersionBefore`); *rolled back* → the board tried X, failed its self-test, is back on Y; *verified, not confirmed* → "A placa está reiniciando" / "em autoteste" with what it waits for and the seconds; *failed / refused* → the reason and "Nada mudou na placa". A push that broke AFTER the board restarted (`OtaPushState.boardRestarted`) says "Não se sabe" instead: only the board knows what it runs then.
- **Rede and Rede 3D** (`otaPushViewProvider`): a **banner** on top (`OtaRedeBanner`) — "Atualização: placa ← firmware da placa 0.1.1 · 43 %", or "… firmware de rede elétrica 0.1.1 (será guardado na placa) · 43 %" (the percent / phase is a piece of its own at the end, so a narrow screen never cuts it off); a tap opens the update screen; after the push it shows the outcome in one line until closed or until another push starts. While a push runs the CENTRAL chip shows the board (board icon), a **progress ring** around it (`OtaProgressRing`, the app's accent colour) and the caption "Placa: recebendo 43 %" / "verificando" / "reiniciando" / "autoteste" in place of "CENTRAL"; the **tablet** is drawn beside it (right of the CENTRAL; under it in the 3D "Larga" view) with the USB cable, and packets cross that cable: blue = a frame sent, cyan = the board's ACK coming back (`AppColors.ledBlue` / `ledCyan`), one pair per 8 chunks and never two within 700 ms (`OtaPacketThrottle`). The tablet, the cable and the ring are on the map only while a push runs — the board stays folded into the CENTRAL chip the rest of the time. With no mesh at all the map still shows the CENTRAL while a push runs. No node and no leaf ever shows a ring or a packet of a push.
- **Every unit on the maps** has the firmware it runs under its name (`FirmwareTag`, "v0.1.0-dev"; nothing when it never said; the board's is on the CENTRAL caption's line, and gives way to the phase while a push runs) and a small box marker when an image of its family waits on the board. The **device menu** adds "Na placa: 0.1.1 (ainda não enviado)" under "Firmware".
- **The LED is not touched.** The ring, the caption, the banner and the tablet are drawings of the app. The board's LED on screen keeps mirroring the board: during a push it is blue almost without a gap, because the board ACKs every chunk and every ACK it sends is a 500 ms blue pulse, 8 in the queue (`siot_coordinator.c` `tx_sink` → `SIOT_EVT_SAFR_TX`). Those ACK frames reach `safrTrafficProvider` like every uplink frame (`SafrIngestService.handleFrame` calls `onTraffic` before it hands the ACK to the downlink), so nothing had to change; `test/central/device_led_test.dart` group "firmware push" holds it. The chunks the tablet sends light nothing: the board relays none of them.

**What the tablet does not know** (shown as it is, not guessed) — *superseded for the stored images on 2026-09-29 by the rollout, below: the board is asked with `GET_ROLLOUT`; the rest of this paragraph is what is left when a board does not answer it*: what the board holds in `fw_store` is known only from the pushes of this app session (`OtaPushState.storedOnBoard`, RAM) — after an app restart nothing is pending on any screen although the image is still on the board, and an image the board dropped is still shown as stored; there is no message to ask the board (§13.6 is not implemented). The version a unit runs is what it last reported (NAME_ANNOUNCE / DEVICE_TABLE), not a live reading.

Rules of the application: a BOARD image needs the operator's yes to "cerca de 30 segundos sem supervisão" and is not started — nor given its END — while an alarm is latched; "Cancelar" stops sending and tells the board nothing; FORCE (FLAGS bit 0) is a switch that exists in debug builds and in builds made with `--dart-define=OTA_ALLOW_FORCE=true`.

`safr_frame.dart` (root of `central/domain/`) is the **v1** parser (21-byte AAD, 4-byte nonce padded to 7, different PSK `2B7E1516…`), kept so old stored packets render in `SafrDetailScreen`; `SafrIngestService` stores v1 frames raw and ignores them.

---


### Rollout: the board sends the stored image to the units (protocol §13.4, §13.6, 2026-09-29)

The board sends the node image it holds to the mains units, one at a time, the mesh root last; the tablet starts it, steers it and shows it. **No database table**: everything is learned from the board (`GET_ROLLOUT` → `OTA_ROLLOUT`), also after an app restart in the middle of a rollout. Update history is a later step.

| Piece | File | What it does |
|---|---|---|
| Codecs | `domain/safr/safr_ota_rollout_payloads.dart` (a `part` of `safr_v2_payloads.dart`) | `OTA_CONTROL` args (COMMAND 0x1D), `GET_ROLLOUT` args (0x1C), `OTA_ROLLOUT` 0x15 (header + entries), `OTA_STATUS` 0x13, `OTA_RESULT` 0x14; `SafrOtaUnitState`, `SafrOtaRolloutState`, `SafrOtaAction`, `SafrOtaFilter`. Same refusals as `siot_ota_proto.c`; a page with fewer entries than `COUNT`, or with bytes behind the last one, is refused |
| Ingest | `application/safr_ingest_provider.dart` | `OTA_ROLLOUT` → bus (the board's own report, not a device to register). `OTA_STATUS` / `OTA_RESULT` → the unit's row is refreshed (it was heard), then → bus, once: a replay or a retransmission is ACKed and not handed over. The duplicate key is now `SRC_MAC # BOOT_CTR # MSG_ID` (a unit that restarted counts its MSG_IDs from 1 again). An ACK confirms a frame of the tablet only when its `DST_MAC` is the tablet (or broadcast): a unit's ACK of the board's `OTA_OFFER` is relayed up and carries a MSG_ID of the board's sequence |
| Downlink | `application/safr_downlink_provider.dart` | `sendGetRollout` (no ACK, like `GET_DEVICE_TABLE`), `sendOtaControl` (tracked, `F_ACK_REQ`; ACK ERROR → REASON in DETAIL); the link-up sequence ends by moving `linkUpSequenceProvider`; the ACK of an `OTA_RESULT` is a traffic tick like the ACK of an EVENT (the unit's cyan) |
| Controller | `application/ota_rollout_controller.dart` | below |
| Words | `application/ota_rollout_words.dart` | states, reasons (for a unit, not for a file), headline, filter, counts, tries, "versão agora → alvo", why the board refused |
| Report | `application/ota_rollout_report.dart` | `otaHeldOnBoard`, `OtaUpdatingUnits`, `OtaRolloutCandidates` (products / zones present, who the filter reaches), `otaRolloutOverlay`, `otaRolloutBanner`, `otaDownloadPath` |
| Screen | `screens/firmware_update_screen.dart`, `widgets/ota_rollout_widgets.dart` | section DISPOSITIVOS: one `OtaRolloutCard` per family the board holds |
| Rede | `widgets/ota_rede_widgets.dart` (`OtaRedeBanner`, `OtaUnitRing`, `OtaUnitTag`), `screens/topology_screen.dart`, `screens/network_3d_screen.dart`, `widgets/network_3d/device_3d_chip.dart` | below |

**The controller.** `GET_ROLLOUT` (page 0) is sent: when the downlink's link-up sequence ended (after `GET_DEVICE_TABLE`), when the update screen opens, when the board reported a node / leaf image stored (`OTA_PUSH_RESULT ok`), 3 s after the ACK of an `OTA_CONTROL` if no page came by itself, when a set of pages stopped before its last page, when a unit talks about an update the tablet has no row for, and while a rollout is `rolling` and no page came for 15 s. **Pages**: a set starts at page 1 and is whole at `PAGE = PAGE_COUNT`; only then its entries replace the rows of the family. The header (state, target, total) of a page that breaks a set is applied at once, the rows stay, the table is asked again. `STATE idle` removes the family (nothing held). **Live frames**: an `OTA_STATUS` moves a row forward only (a later state, or the same state with a higher percent) and never a row the board settled; an `OTA_RESULT` settles it (`ok` → done, `NOT_NEWER` → skipped, else failed) until the next page. **When they disagree, the page wins**: it replaces the row. **Since when a unit is being updated** (`activeSince`): when its row entered offered … self-test — kept while it moves between those states, restarted by a new offer (`ATTEMPTS` changed); learned in the middle, it is `now − AGE_S`. **Pause cause**: the header only says `paused`; "a pedido do operador" when this session's pause was ACKed in the last 30 s, "por alarme" when an alarm is latched (looked at again 2 s later), else not known. **`start` and `resume` are refused locally while any alarm is latched**; `start` also for the leaf family, with the cable out, while a push runs and while a rollout runs.

| Number | Value | `OtaRolloutTimings` |
|---|---|---|
| `GET_ROLLOUT` unanswered | 3 s → "the board did not answer": what this session saw stored is shown instead | `answerTimeout` |
| `OTA_CONTROL` ACK | 2 s × 3 | `controlAckTimeout`, `controlAttempts` |
| Page after an `OTA_CONTROL` | 3 s, then `GET_ROLLOUT` | `pageAfterControl` |
| Set of pages incomplete | 2 s, then `GET_ROLLOUT` | `pageSetTimeout` |
| Silence while `rolling` | 15 s (the board sends every 5 s), checked every 5 s | `rollingSilence`, `watchdogPeriod` |
| UPDATING instead of missing | 300 s (`DEADLINE_S`; the tablet never sees the offer) | `updatingGrace` |

**What the operator sees.**

- **Atualização de firmware → DISPOSITIVOS**: per family the board holds, "Na placa: firmware de rede elétrica 0.1.1". Nothing sent yet, or a rollout that ended: the form **Enviar aos dispositivos** — Todos · Por produto · Por zona · Um dispositivo (products and zones from the known units of the family), how many units will get it (online, product known), how many are silent / never said their product / already run it. The question before it starts names the number and says they restart one at a time, the root last. While it runs: **ENVIANDO / PAUSADO / PAUSADO POR ALARME**, "1 de 3 atualizado · há 2 min 05 s" ("há pelo menos" when it was not started in this session), and one row per unit: name, product, "0.1.0 → 0.2.0", the state in words with the percent, the tries, the reason in plain pt-BR; the root is marked ROOT · POR ÚLTIMO. **Pausar / Retomar / Cancelar** (cancel asks first). When it ended: **CONCLUÍDO / PARCIAL**, the failures together in a box, and the form again. The **leaf** family shows the stored image; its button is off, with why. "Versões em execução", the link card and the device menu now read what the board holds from `otaHeldOnBoardProvider`. "Detalhes → Registro" holds the lines of the push and of the rollout by time; "Copiar" takes all.
- **Rede and Rede 3D**: the banner says what goes where — "Atualização: placa → Sirene hall (2 de 5)" · "40 %" — then the outcome until closed (only of a rollout this session saw end). The unit being updated has a **progress ring** (`OtaUnitRing`, the app's accent colour) and the phase under its name; units waiting show a small hourglass and "aguardando" ("por último" on the root); done units a check and their new version; failed units an error marker. While a unit downloads, a blue packet leaves the CENTRAL every 1.5 s and travels the tree to it (`AppColors.ledBlue`, the colour of "a frame sent").
- **"Atualizando", never "Sem comunicação"**: `TopologyNode.updating` / `.heard`; `deviceStateLabel`. A unit that is silent because it restarts stays `online`; it is no root contender (`root_election_provider.dart`).
- **The LED is not touched.** The mirror does what `siot_ui_led.c` does for the frames the tablet sees: `OTA_STATUS` and `OTA_RESULT` are not in `is_message` → blue 100 ms tick (folded), on the unit and on the board that relays them; the unit's ACK of the board's offer → blue 500 ms; the tablet's ACK of the `OTA_RESULT` → cyan 500 ms on the unit; `OTA_ROLLOUT` → a tick on the board. A unit that is silent while it restarts shows a dark LED (what it does then never crosses the wire). `test/central/device_led_test.dart` group "firmware rollout". Not mirrored, because the tablet never sees those frames: the board's `OTA_OFFER` and the board's own ACK of the unit's `OTA_RESULT`.

## 6. Cloud / MQTT

`IotMqttRepositoryImpl` (`iot/data/repositories/iot_mqtt_repository_impl.dart`) is a minimal MQTT 3.1.1 client on `web_socket_channel`: static singletons per role (user / central) so hot restart cannot duplicate client IDs; client id = identityId (`web-` prefix on web); clean session; keep-alive 30 s with PINGREQ every 15 s and a 10 s PINGRESP watchdog; QoS 1 publish/subscribe with PUBACK; SUBACK 0x80 retried up to 5× with backoff (policy attachment latency); a multi-packet WebSocket frame is walked packet by packet. Credentials come from an `IotCredentialsService` (`fetch()` → `AwsCredentials{accessKeyId, secret, sessionToken, identityId, userId}`), the central overriding it with `CentralCredentialsService`.

| Topic | Direction | Payload | Notes |
|---|---|---|---|
| `{centralIdentityId}/will` | central → retained | `{"status":"online","wifi":online\|limited\|offline,"usb":connected\|connecting\|error\|disconnected,"mesh":connected\|connecting\|disconnected,"updated_at":ISO}` | Also the MQTT Last-Will (`{"status":"offline"}`, retained). `centralStatusPublisherProvider` republishes on any change (400 ms debounce); explicit `offline` on graceful dispose. Readable by every user via shared policy `*/will`. |
| `{centralIdentityId}/storage` | central → retained | `{"label","totalBytes","availableBytes","updated_at"}` | `centralStoragePublisherProvider`, only when the displayed numbers change |
| `{centralIdentityId}/access` | user → | `{"requestId","userSubId","userIdentityId"}` | IoT Rule → `access-request` Lambda; the central only uses it as a "go re-sync" signal |
| `{userIdentityId}/access-response` | Lambda → | `{"decision":ACCEPTED\|REJECTED\|LEVEL_CHANGED\|BLOCKED,"centralIdentityId","level"?,"resolvedAt"}` | `SavedCentralsNotifier` updates the card |
| `{ownIdentityId}/#` | both subscribe | — | user: debug log only; central: feeds `centralMqttMessagesProvider` |

**What a VIEWER actually receives:** presence + comm status (Wi-Fi/USB/mesh/cloud tiles mirror the central's own gadget through the same tile builders in `comm_status_gadget.dart`), storage snapshot, and access decisions. **No SAFR events, alarms, device registry or topology are published to the cloud** — the viewer dashboard's device/event counters are hard-coded zeros (`_CentralDashboard._total*`), the Rede/Eventos tabs are not offered in the restricted tab set, and the granted IoT policy's publish right on `{centralIdentityId}` has no consumer on the central. The "real-time following" today is limited to the central being online and its link health.

---

## 7. Provisioning wizard (APP mode, `features/provisioning`)

> **Out of date (2026-09-24).** This section describes the pre-installation wizard. The current flow
> (sticker `{id, mac, pop}`, `/identify` + `/provision` envelope, installation code, `/enroll`) is in
> `pocs/APP-BRIEF.md` and the system reference §3.1; the target lifecycle (encrypted backups, sharing
> between installers, tablet reading the code from the board, device management) is
> `docs/others/installation-lifecycle-v1.md`. Rewrite this section after lifecycle Phase 1 ships.

Entry: drawer "Configurar Dispositivo" (hidden on web: mixed-content and AP-loses-internet). Screen: `ProvisioningWizardScreen` renders one widget per `ProvisioningStep` with a 5-phase header (Identificação, Conexão, Central, Configuração, Conclusão). State machine: `ProvisioningWizardNotifier` (`provisioning_wizard_provider.dart`).

**QR payload** (`DeviceQrPayload.tryParse`): JSON `{"deviceId":"dev-001","signature":"abc123"}`; both fields required, anything else (e.g. a central subId) is rejected with "QR Code inválido". Manual entry of both fields is offered too.

**Device SoftAP contract** (`DeviceApService`, base `DEVICE_AP_URL`, default `http://192.168.4.1`, every call `.timeout(3 s)`, `Content-Type: application/json`). The mock `mocked-device-autoconnect/server.js` is declared "the protocol spec for the real firmware".

| Call | Request | Success | Failure handling in app |
|---|---|---|---|
| `GET /info` | — | 200 `{id, mac, model, fw, product, family, hw_rev, state, nonce}` → `DeviceApInfo` (`product` = the PRODUCT code of reference §2.1; absent on firmware before 2026-09-29, then the catalogue is looked up by `model`) | any error = "not reachable yet", keep polling |
| `POST /identify` | `{deviceId, signature}` | 200 `{ok:true}` | 403 (`signature_mismatch`) → `SignatureMismatchException` → `identifyFailed`; other errors → back to polling `/info` |
| `POST /provision` | `{centralId, networkReady}` | 202 (or 200) `{ok:true}` | 409 `not_identified`, 400 `missing_central_id`, timeout → back to `confirm` with error banner |
| `GET /status` | — | 200 `{state, detail}`; the firmware answers `idle` \| `identified` \| `stored` (it never reports `joining` / `online` from its setup network); the unit reboots 1 s after the first `stored` reply | unreachable after a `202` from `/provision` = the unit rebooted into normal mode → `resultStored` |
| `POST /reset` | `{joinResult?, joinDelayMs?}` | mock-only helper | used by the integration test, not the app |

Mock state machine: `idle → identified → stored | connecting → connected | failed`; `JOIN_RESULT=drop` makes the server stop answering after the 202 (simulates the AP channel switch).

**Steps in order:**

| Step | Widget | What happens |
|---|---|---|
| `scan` | `ScanStep` | scan/type credentials → `setCredentials` |
| `connectWifi` | `ConnectWifiStep` | instructs to join SSID **`SEMPREIOT-<DEVICEID uppercased>`** (the SSID format is only asserted by this UI string), "Abrir Ajustes de Wi-Fi" via `app_settings`; notifier polls `GET /info` every 2 s |
| `identifying` | `IdentifyingStep` | first `/info` success → `POST /identify` |
| `identifyFailed` | `IdentifyFailedStep` | 403; buttons: rescan or retry with same data |
| `selectCentral` | `SelectCentralStep` | pick one of the user's ACCEPTED `SavedCentral`s (sends its **subId** as `centralId`) or type any string |
| `confirm` | `ConfirmStep` | summary + checkbox "A central já está ligada com a rede mesh ativa" (`networkReady`, default true) → `POST /provision` |
| `provisioning` | `ProvisioningProgressStep` ("Enviando informações") | `POST /provision` → `202` (the unit wrote the code to flash: from here `stored` is confirmed) → polls `GET /status` every 2 s: `stored` twice, or the setup network gone → `resultStored`; `failed` → `resultFailed`. `resultFailed` by timeout (30 polls) now only happens when `/provision` itself was never answered. Fixed 2026-09-29: the wizard used to wait for a `/status` the unit never sent (it rebooted first) and always ended on the timeout screen |
| `result*` | `ResultStep` | success / stored / assumed ("verify on your central") / failed (retry → back to `confirm`) ; "Configurar outro dispositivo" restarts |

What is **not** exchanged with the device today: no Wi-Fi credentials, no mesh ID/password, no SAFR PSK, no SYSTEM_ID, no server endpoint — only `centralId` (a Cognito sub string) and the `networkReady` bit. The device never reports which central it joined back to the cloud, and the central does not learn about the provisioning; the only feedback loop is the device appearing on the serial link. `protocol-safr-v3.md` §4 explicitly makes per-installation PSK+SYSTEM_ID injection by this wizard a launch prerequisite, so the "first setup" redesign has to carry at least those two secrets (and probably the mesh credentials) across this HTTP hop, presumably after `/identify` proves the device.

**Integration test** (`test/provisioning_wizard_integration_test.dart`, needs the mock; skipped otherwise; `--dart-define=DEVICE_AP_URL=http://localhost:8080`): drives the notifier directly, resets the mock via `POST /reset` per case, and asserts: happy path → `resultSuccess`; wrong signature → `identifyFailed` with error text; `JOIN_RESULT=fail` → `resultFailed`; `drop` → `resultAssumed` (≤45 s); `networkReady=false` → `resultStored`; plus a pure unit test that `DeviceQrPayload.tryParse` accepts the JSON and rejects a bare subId, missing signature, empty string.

---

## 8. Main screen and UI

`MainScreen` (`presentation/screens/main/main_screen.dart`, 2 k lines) hosts: `MainAppBar` (branding = central name from `info.name` in CENTRAL mode, nickname + subId when viewing a central, lock button, avatar → profile sheet with sign-out), `MainDrawer` (tabs + SISTEMA items + theme toggle + "Sobre" placeholder + footer lock/sign-out + `v0.1.4`), `MainBottomNav`, and `_TabBody` (AnimatedSwitcher between tabs; `central`/`centrais`/`devices` tabs are `_PlaceholderTab`s).

Principal tab: `_CentralDashboard` — status section switchable between a card and an "arcade" panel (`statusPanelArcadeProvider`) that uses `DotMatrixDisplay` (`widgets/dot_matrix_display.dart`: 5×7 LED font, accent stripping, whole-column marquee at 12 cols/s, glow paint) plus three LEDs; metric cards (all hard-coded 0); COMUNICAÇÃO gadget (`CentralCommGadget` reads `networkStatusProvider`, `serialLinkProvider`, `meshLinkStateProvider`, `centralIotConnectionProvider`; `UserCentralCommGadget` reads the retained presence payload and greys everything when the central is offline via `_OfflineDim`); BATERIA/TEMPERATURA gadgets with **fake constants** (78 %, 32 °C). `_AppDashboard` (APP home) is similar with zero counts. The lock overlay (`_PinOverlay`) draws over everything with `IoTNetworkAnimation`, a connectivity banner, dots, numpad (its own private `_Numpad`/`_PinDots`, duplicating `shared/widgets/pin_pad.dart`), "Continuar bloqueado".

`StorageScreen` (`features/storage/presentation/screens/storage_screen.dart`): local gauge from a `MethodChannel('com.sempreiot.central/storage')` (Android only; zeros on web) polled every 30 s; remote variant reads `remoteStorageProvider` and shows an offline banner. `EventsScreen`: stat strip (24 h), latched-alarm banner with Rearmar, severity/device filter chips, day-separated feed of cards (title/subtitle mapping from `SafrEventCode`, ✓✓ when `ackedAt`), detail sheet → `SafrDetailScreen` for the raw packet. `TopologyScreen`: zoomable mesh graph with traveling packets from `safrTrafficProvider` (events from nodes and downlink ACKs; every uplink frame from a leaf, 700 ms per hop) drawn as oriented data packets in the LED language (`AppColors.ledBlue` / `ledCyan`, red alarm, orange trouble — reference §3.6.2); links, their dBm labels and the sheet's "Sinal" in the signal-tier colour of `core/theme/signal_colors.dart` (reference §3.6.2: green ≥ −75, yellow ≥ −85, red below); a sleeping leaf's link keeps its last dBm in the sleep colour and its avatar shows an animated moon (`_SleepingMoon`, clipped to the circle); node sheet with facts, rename (writes `MeshDevices.name`) and IDENTIFY/SILENCE/TEST. `SerialLogsScreen`: link status, wire counters (bytes/dropped/frames), CRC/auth error counts, hex console (500 rows), legend sheet, copy-all, clear. `SafrDetailScreen`: v2/v3 fully decoded and explained frame (validation card, facts, hex toggle) or legacy v1 layout.

Theme: `AppTheme.light/dark` (Material 3, colors from missing `app_colors.dart`), dark by default, persisted per user; `context.bgColor/surfaceColor/textPrimary…` come from the missing `theme_ext.dart`.

---

## 9. Tests and tools

| File | What it covers | Needs |
|---|---|---|
| `test/safr/safr_v3_roundtrip_test.dart` | encode→parse for every MSG_TYPE incl. F_RETX, sentinels, signed temp/RSSI, EVENT_LOG_DATA(+EMPTY), plaintext mode; error taxonomy (crcFailed vs authFailed precedence, wrong key, tampered header/SYSTEM_ID, foreignSystem, truncated, badVersion); facade dispatch | nothing |
| `test/safr/safr_ingest_test.dart` | `SafrIngestService` against in-memory Drift: raw+registry+feed+ACK, latch semantics, F_RETX dedupe-but-ACK, plaintext rejection, foreign SYSTEM_ID, journal replay dedupe, heartbeat silent registry update, auth failure isolation, replay rejection, v1 raw-only | `AppDatabase.forTesting` |
| `test/safr/safr_v3_captured_test.dart` | reframes a real UART capture `test/fixtures/safr_v3_captured.hex` (skipped if absent), expects zero CRC/auth failures and that the Appendix-A vectors are present byte-for-byte | fixture + `safr_v3_vectors_test.dart` (`buildSpecVectors`) |
| `test/safr/safr_v35_product_test.dart` | SAFR v3.5: product catalogue (known, unknown, 0); NAME_ANNOUNCE with / without / truncated / oversized extension; DEVICE_TABLE with COUNT bit 7 set and clear; GET_DEVICE_TABLE args `page, 1` | nothing |
| `test/central/product_ingest_test.dart` | ingest stores product / hardware revision / firmware version from NAME_ANNOUNCE and DEVICE_TABLE and keeps them across frames that lack them (heartbeat, event, older announce, v3.2 table, journal replay) | `AppDatabase.forTesting` |
| `test/central/database_migration_test.dart` | Drift v9 → v10 on a file database: the three columns are added, rows survive | temp dir |
| `test/central/device_product_facts_test.dart` | widget: "Produto" / "Firmware" on the Dispositivo screen and in the device menu, tablet and phone, portrait and landscape | nothing |
| `test/ota/safr_ota_codec_test.dart` | protocol §13.3 / §13.7: the four messages, OTA_BAUD args, CRC-32, REASON numbers and texts — the vectors of `firmware/test/host/main/test_ota_proto.c` | nothing |
| `test/ota/firmware_image_test.dart` | family and version out of a fake image header; every file that is refused; chunking | nothing |
| `test/ota/serial_notifier_test.dart` | frame + raw bytes in one write, the write queue, speed change and its settle time, fallback to 115200 on silence | `SerialNotifier.detached` |
| `test/ota/ota_push_controller_test.dart` | the push against `fake_board.dart`, a board played byte for byte on the port (real encoder, ACK tracking, ingest, reframer): stored, confirmed, BAD_CRC, lost ACK, lost chunk, OUT_OF_ORDER, board without the transfer, resume, cable out and back, board power-cycled, BEGIN refused, verification failed, rollback, lost confirmation, OTA_BAUD unanswered, cancel, alarm; steps and log lines | `AppDatabase.forTesting` |
| `test/ota/firmware_update_screen_test.dart` | widget: the screen in tablet and phone, portrait and landscape; the report card outcome by outcome (stored = "Nenhum dispositivo foi atualizado", not green); "Versões em execução" with what waits on the board; "Detalhes" folded / open; the board-restart question; alarm and cable blocks; "Copiar" | nothing |
| `test/ota/ota_push_report_test.dart` | the words of every outcome and of the banner; the board's activity phase by phase; packet throttle; unit family, pending image, groups | nothing |
| `test/ota/ota_rede_test.dart` | widget, Rede and Rede 3D, tablet and phone, portrait and landscape: banner (running, outcome, closed, tap), ring + caption + tablet on the CENTRAL only, phases, versions and pending markers on the chips, "Na placa" in the device menu | nothing |
| `test/ota/safr_ota_rollout_codec_test.dart` | protocol §13.4 / §13.6: OTA_CONTROL, GET_ROLLOUT, OTA_ROLLOUT, OTA_STATUS, OTA_RESULT — the vectors of `firmware/test/host/main/test_ota_proto.c` | nothing |
| `test/ota/ota_rollout_ingest_test.dart` | the rollout's frames through ingest: handed over once, ACKed every time, a restarted unit's MSG_IDs, an ACK addressed to the board confirms nothing of the tablet's | `AppDatabase.forTesting` |
| `test/ota/ota_rollout_controller_test.dart` | the rollout against `fake_board.dart` + `fake_rollout.dart` (a board and its mesh played the way `ota_rollout.c` / `siot_ota_node.c` do it): what the board holds, three units with the root last, filters, NOT_NEWER skipped, two failures → partial, self-test failure, a unit without OTA, pause on alarm and resume, operator pause, abort, refusals, a board that never answers, app restart in the middle, board restart, pages (whole sets, a lost page, silence), status / result against pages | `AppDatabase.forTesting` |
| `test/ota/ota_rollout_report_test.dart` | what the board holds, headline, counts, every state and reason in words, tries, banner, map overlay, download path, candidates and filters, the merged log, the 300 s | nothing |
| `test/ota/ota_rollout_screen_test.dart` | widget: the DISPOSITIVOS section in tablet and phone, portrait and landscape — form, filters, the question, table, pause / resume / cancel, partial with its failures, leaf, blocks, the log and "Copiar" | nothing |
| `test/ota/ota_rollout_rede_test.dart` | widget, Rede and Rede 3D, four sizes: banner, ring, phases, waiting / done / failed markers, outcome closed, "Atualizando" in the device menu | nothing |
| `test/central/supervision_updating_test.dart` | the supervision rule and its one exception: updating units raise no "dispositivo ausente" for 300 s, then the rule again; root election ignores a unit that restarts | `AppDatabase.forTesting` |
| `test/provisioning_wizard_integration_test.dart` | see §7 | running mock |
| `tool/print_safr_v3_vectors.dart` | prints the three golden frames (`dart run`) for pasting into the spec / firmware | — |
| `tools/capture-safr.sh` | `stty 115200 raw`, `cat` the port for N s, `xxd -p` into the fixture | macOS device names |

No tests for access/auth/MQTT.

---

## 10. Loose ends / TODOs found in code

- **Dead / unused**: `features/central/presentation/screens/central_pin_screen.dart` (4-digit PIN screen, never routed; `MainScreen._PinOverlay` is the real one and expects 6 digits), `presentation/screens/splash/loading_screen.dart`, `features/auth/application/user_sync_provider.dart` (superseded by `appInitProvider`), `serialDataProvider`, `IotCredentialsService.cachedIdentityId/lastConnectedUserId`, pubspec deps `aws_signature_v4`, `aws_common`, `path_provider`. `_Numpad/_PinDots` in `main_screen.dart` duplicate `shared/widgets/pin_pad.dart`.
- **Placeholders**: dashboard counters (`_totalDevices…` = 0 in both dashboards), battery 78 % / temperature 32 °C gadgets, `Central`/`Dispositivos`/`Centrais` tabs, drawer "Sobre" (no `onTap`), `CentralLiveStatus.mesh` doc says "always disconnected until real mesh devices exist" (now real).
- **Hard-coded dev secrets**: SAFR PSK `25 11 8B A1 …` (`safr_crypto.dart`), v1 PSK `2B 7E 15 16 …` (`safr_frame.dart`), `SYSTEM_ID 0x5346`; `central-123456789` fallback userId in `central_credentials_service.dart`; README contains real Cognito IDs, a Lambda URL, JWTs, and FACTORY payloads with PINs/IoT passwords. `.env.copy` points at a different user pool (`us-east-1_01sayARtr`) than the README commands (`us-east-1_t6mTbVcqB`) — two environments.
- **Backend TODO** (`lambda/access-resolve/index.mjs`): verify the caller's JWT is the central's machine user; today any user token can mutate relations. `lambda/user` has large commented-out previous versions.
- **Spec gaps** (see §5 table): trouble/restore state, AC-loss latch, link-quality trouble, EVENT_LOG_REQ timeout/retry, DEV_SEQ gap backfill, replay diagnostic row, per-installation key provisioning, priority queue, 30-day purge of `DeviceEvents` vs. "append-only".
- **Access model gaps**: level PIN is not verified when granting LEVEL_1–4 (only the editor gate); levels have no effect in the viewer; `SavedCentral.subId` is what the wizard sends as `centralId` while the backend/IoT side keys on `identityId` — decide which one a device should carry.
- **Viewer gets no telemetry**: nothing publishes events/topology/latched alarms to MQTT; the granted policy's publish permission is unused.
- **Provisioning**: no PSK/SYSTEM_ID/mesh credentials exchanged; SSID pattern `SEMPREIOT-<ID>` exists only in UI text; `DeviceApService` is static (not injectable, tests hit a real HTTP server); web build cannot provision (mixed content).
- **Misc**: `SerialNotifier` opens `devices.first` (no VID/PID filter); `_safrMinFrame = 32` vs v3 minimum 34; `iot_password` plaintext in Drift; `register_provider.dart` has a stray `print`; `CLAUDE.md` describes AppSync/GraphQL and go_router which the code does not use; `CentralCredentialsService.reset()` is invoked on every `disconnect()`, forcing a fresh Cognito login on each reconnect.
