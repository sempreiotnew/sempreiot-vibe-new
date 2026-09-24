/**
 * Mock ESP32 provisioning device (esp-mesh-lite).
 *
 * Simulates the SoftAP HTTP server that a real device exposes at
 * http://192.168.4.1 while waiting to be provisioned. This file is the
 * protocol spec for the real firmware — keep endpoint shapes in sync with
 * docs/others/system-blueprint-v1.md §9.3 and pocs/POC-BRIEF.md §5.
 *
 * State machine:
 *   idle → identified → stored → joining → online | failed
 *
 * Env config:
 *   DEVICE_ID      device id printed on the QR sticker      (default: dev-001)
 *   POP            per-unit secret printed on the sticker   (default: abc123POP)
 *   MAC            device MAC printed on the sticker        (default: 5A:46:52:00:00:09)
 *   MODEL          model string (board sticker starts with SIOT-BOARD)
 *                                                            (default: SIOT-SENSOR-01)
 *   ROLE           node | board                              (default: node)
 *   JOIN_RESULT    stored | online | failed | drop            (default: online)
 *                  stored = config saved, never joins (central's network not
 *                           up yet); drop = stop answering after /provision
 *                  ACK, simulating the SoftAP channel switch kicking the
 *                  phone off the network — result is still "stored", never
 *                  "assumed"
 *   JOIN_DELAY_MS  time spent "joining" before the result    (default: 4000)
 *   PORT           listen port (real device uses 80)         (default: 8080)
 */

const crypto = require('crypto');
const express = require('express');
const { computeProof, decryptEnvelope: decrypt } = require('./crypto-helpers');

const DEVICE_ID = process.env.DEVICE_ID || 'dev-001';
const POP = process.env.POP || 'abc123POP';
const MAC = process.env.MAC || '5A:46:52:00:00:09';
const MODEL = process.env.MODEL || 'SIOT-SENSOR-01';
const ROLE = process.env.ROLE === 'board' ? 'board' : 'node';
const PORT = Number(process.env.PORT || 8080);
const FW = '1.0.0';

// Mutable so /reset can override them between wizard runs.
let joinResult = process.env.JOIN_RESULT || 'online'; // stored | online | failed | drop
let joinDelayMs = Number(process.env.JOIN_DELAY_MS || 4000);

const state = {
  // idle | identified | stored | joining | online | failed
  provisionState: 'idle',
  detail: null,
  code: null, // decrypted installation code JSON
  name: null,
  zone: null,
  enrolled: null, // board only: last /enroll body
  lastNonceHex: null, // most recent GET /info nonce, consumed by /identify
  dropped: false, // when true (JOIN_RESULT=drop) the device goes silent
};

const app = express();
app.use(express.json());

app.use((req, res, next) => {
  if (state.dropped && req.path !== '/reset') {
    // Simulate the AP going away: never answer, let the client time out.
    console.log(`[drop] ${req.method} ${req.path} — ignoring (AP "gone")`);
    return; // no response at all
  }
  console.log(
    `${new Date().toISOString()} ${req.method} ${req.path}`,
    Object.keys(req.body || {}).length ? JSON.stringify(req.body) : ''
  );
  // CORS for Flutter web development (the real device doesn't need this).
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

app.get('/info', (_req, res) => {
  const nonce = crypto.randomBytes(16);
  state.lastNonceHex = nonce.toString('hex');
  res.json({
    id: DEVICE_ID,
    mac: MAC,
    model: MODEL,
    fw: FW,
    state: state.provisionState,
    nonce: state.lastNonceHex,
  });
});

app.post('/identify', (req, res) => {
  const { id, proof } = req.body || {};
  const expected = state.lastNonceHex ? computeProof(POP, state.lastNonceHex) : null;

  if (id !== DEVICE_ID || !expected || proof !== expected) {
    console.log(`  -> 403 proof_mismatch (got id=${id})`);
    return res.status(403).json({ ok: false, error: 'proof_mismatch' });
  }
  state.provisionState = 'identified';
  console.log('  -> identified OK');
  res.json({ ok: true });
});

app.post('/provision', (req, res) => {
  const { envelope, name, zone, epoch } = req.body || {};
  if (state.provisionState === 'idle') {
    return res.status(409).json({ ok: false, error: 'not_identified' });
  }

  let codeJson;
  try {
    codeJson = decrypt({
      pop: POP,
      nonceHex: state.lastNonceHex,
      id: DEVICE_ID,
      envelopeB64: envelope,
    });
  } catch (e) {
    console.log(`  -> 400 bad_envelope (${e.message})`);
    return res.status(400).json({ ok: false, error: 'bad_envelope' });
  }

  state.code = codeJson;
  state.name = name || null;
  state.zone = zone || null;
  console.log(
    `  -> provision name=${name} zone=${zone} epoch=${epoch} ` +
      `system_id=${codeJson.system_id} (joinResult=${joinResult})`
  );

  res.status(202).json({ ok: true });

  // The code is stored regardless of what happens next — spec: "on success
  // store the JSON code" before any mesh-join attempt.
  state.provisionState = 'stored';
  state.detail = null;

  if (joinResult === 'stored') {
    state.detail = 'config_stored_for_future_network';
    return;
  }

  if (joinResult === 'drop') {
    // ACK was sent; now the AP channel-switches and the phone is kicked off.
    setTimeout(() => {
      state.dropped = true;
      console.log('[drop] AP is now silent — client requests will time out');
    }, 500);
    return;
  }

  state.provisionState = 'joining';
  setTimeout(() => {
    if (joinResult === 'failed') {
      state.provisionState = 'failed';
      state.detail = 'mesh_join_timeout';
    } else {
      state.provisionState = 'online';
      state.detail = null;
    }
    console.log(`  -> mesh join result: ${state.provisionState}`);
  }, joinDelayMs);
});

app.post('/enroll', (req, res) => {
  if (ROLE !== 'board') {
    return res.status(404).json({ ok: false, error: 'not_a_board' });
  }
  const list = Array.isArray(req.body) ? req.body : [];
  state.enrolled = list;
  console.log(`  -> enroll count=${list.length}`);
  res.json({ ok: true, count: list.length });
});

app.get('/status', (_req, res) => {
  res.json({ state: state.provisionState, detail: state.detail });
});

// Dev helper (not part of the firmware contract): reset state between runs.
// Optional body: {joinResult: "stored"|"online"|"failed"|"drop", joinDelayMs: 1000}
app.post('/reset', (req, res) => {
  state.provisionState = 'idle';
  state.detail = null;
  state.code = null;
  state.name = null;
  state.zone = null;
  state.enrolled = null;
  state.lastNonceHex = null;
  state.dropped = false;
  const { joinResult: jr, joinDelayMs: jd } = req.body || {};
  if (jr) joinResult = jr;
  if (jd) joinDelayMs = Number(jd);
  console.log(`  -> state reset (joinResult=${joinResult} joinDelayMs=${joinDelayMs})`);
  res.json({ ok: true });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Mock device listening on 0.0.0.0:${PORT}`);
  console.log(`  DEVICE_ID=${DEVICE_ID} MAC=${MAC} MODEL=${MODEL} ROLE=${ROLE}`);
  console.log(`  joinResult=${joinResult} joinDelayMs=${joinDelayMs}`);
  console.log(`  Sticker QR: {"id":"${DEVICE_ID}","mac":"${MAC}","pop":"${POP}"}`);
});
