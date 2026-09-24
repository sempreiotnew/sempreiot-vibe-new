/**
 * Provisioning crypto — pocs/POC-BRIEF.md §5 / docs/others/system-blueprint-v1.md.
 *
 * Shared by server.js (decrypt what the app sends) and gen-vectors.js /
 * test.js (encrypt exactly what the app should send), so both the Node
 * mock and the Dart app are checked against the same byte-for-byte vectors
 * (test/provisioning/prov_crypto_test.dart loads vectors.json).
 */

const crypto = require('crypto');

const HKDF_INFO = 'siot-prov-v1';

/** proof = hex(HMAC-SHA256(key = pop, msg = nonce)) */
function computeProof(pop, nonceHex) {
  return crypto
    .createHmac('sha256', Buffer.from(pop, 'utf8'))
    .update(Buffer.from(nonceHex, 'hex'))
    .digest('hex');
}

/** key = HKDF-SHA256(ikm = pop, salt = nonce, info = "siot-prov-v1", L = 16) */
function deriveKey(pop, nonceHex) {
  const salt = Buffer.from(nonceHex, 'hex');
  return Buffer.from(
    crypto.hkdfSync('sha256', Buffer.from(pop, 'utf8'), salt, HKDF_INFO, 16)
  );
}

/**
 * envelope = base64(nonce2(12) ‖ AES-128-CCM(key, nonce2, aad=id, code_json) ‖ tag(16))
 */
function encryptEnvelope({ pop, nonceHex, nonce2Hex, id, codeJson }) {
  const key = deriveKey(pop, nonceHex);
  const nonce2 = Buffer.from(nonce2Hex, 'hex');
  const plaintext = Buffer.from(JSON.stringify(codeJson), 'utf8');

  const cipher = crypto.createCipheriv('aes-128-ccm', key, nonce2, {
    authTagLength: 16,
  });
  cipher.setAAD(Buffer.from(id, 'utf8'), { plaintextLength: plaintext.length });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();

  return Buffer.concat([nonce2, ciphertext, tag]).toString('base64');
}

/** Inverse of encryptEnvelope; throws on a bad tag / malformed envelope. */
function decryptEnvelope({ pop, nonceHex, id, envelopeB64 }) {
  const raw = Buffer.from(envelopeB64, 'base64');
  if (raw.length < 12 + 16) throw new Error('envelope too short');

  const nonce2 = raw.subarray(0, 12);
  const tag = raw.subarray(raw.length - 16);
  const ciphertext = raw.subarray(12, raw.length - 16);

  const key = deriveKey(pop, nonceHex);
  const decipher = crypto.createDecipheriv('aes-128-ccm', key, nonce2, {
    authTagLength: 16,
  });
  decipher.setAuthTag(tag);
  decipher.setAAD(Buffer.from(id, 'utf8'), { plaintextLength: ciphertext.length });
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return JSON.parse(plaintext.toString('utf8'));
}

module.exports = { HKDF_INFO, computeProof, deriveKey, encryptEnvelope, decryptEnvelope };
