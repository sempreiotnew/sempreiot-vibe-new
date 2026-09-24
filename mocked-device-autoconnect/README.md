# mocked-device-autoconnect

Mock of the ESP32 (esp-mesh-lite) provisioning SoftAP. The real device exposes
this HTTP server at `http://192.168.4.1` while unprovisioned; this mock runs on
your machine so the app's provisioning wizard can be developed without hardware.

**`server.js` is the protocol spec for the real firmware.** Keep the endpoint
shapes in sync when porting.

## Run

```bash
npm install
npm start                       # defaults: success path, port 8080
JOIN_RESULT=fail npm start      # mesh join fails
JOIN_RESULT=drop npm start      # AP goes silent right after /provision ACK
SIGNATURE=other npm start       # any QR with a different signature gets 403
```

Point the Flutter app at the mock:

```bash
flutter run --dart-define=APP_MODE=app --dart-define=DEVICE_AP_URL=http://<your-mac-lan-ip>:8080
```

(On a simulator, `http://localhost:8080` works. On a physical phone use your
Mac's LAN IP; both must be on the same Wi-Fi.)

## Protocol

State machine: `idle → identified → stored → connecting → connected | failed`

| Endpoint | Request | Response |
|---|---|---|
| `GET /info` | — | `{deviceId, model, firmwareVersion, provisionState}` |
| `POST /identify` | `{deviceId, signature}` | `200 {ok:true}` or `403 {ok:false, error:"signature_mismatch"}` |
| `POST /provision` | `{centralId, networkReady}` | `202 {ok:true}`, `409` if not identified, `400` if no centralId |
| `GET /status` | — | `{state, detail}` |
| `POST /reset` | — | dev-only helper, resets to `idle` |

Behavior after `/provision`:

- `networkReady: false` → state goes straight to `stored` (config saved for a
  future network; the wizard treats this as success).
- `networkReady: true` → `connecting` for `JOIN_DELAY_MS`, then `connected`
  (JOIN_RESULT=success) or `failed` (JOIN_RESULT=fail).
- `JOIN_RESULT=drop` → the ACK is sent, then the server stops answering
  entirely — simulating the SoftAP channel-switch that kicks the phone off the
  device network. The wizard should treat this as "provisioned, confirm on your
  central".

## Env vars

| Var | Default | Meaning |
|---|---|---|
| `DEVICE_ID` | `dev-001` | id expected in `/identify` |
| `SIGNATURE` | `abc123` | signature expected in `/identify` |
| `JOIN_RESULT` | `success` | `success` \| `fail` \| `drop` |
| `JOIN_DELAY_MS` | `4000` | time spent in `connecting` |
| `PORT` | `8080` | real device uses 80 |

QR payload format: `{"deviceId":"dev-001","signature":"abc123"}`

## Web (Flutter Web) caveats

Provisioning from the browser works in development, but the real firmware must
send CORS headers (`Access-Control-Allow-Origin: *` + handle OPTIONS
preflight) like this mock does, or the browser blocks the requests.

Also note: a **production web app served over https cannot call
http://192.168.4.1** — browsers block it as mixed content. Web provisioning
only works when the app itself is served over http (dev) or if the device ever
serves https. Phones/tablets are the primary provisioning path.
