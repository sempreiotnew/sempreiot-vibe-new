#!/usr/bin/env node
// Register a new central from the command line.
//
//   cd lambda/central && node register.mjs <centralId> "<name>"
//   e.g. node register.mjs central-004 "Central Bloco B"
//
// Runs the same handler the local runner (run.mjs) serves on port 3001:
// Cognito machine user + permanent password, Identity Pool identity, IoT
// policy Central_<centralId>, row in the DynamoDB `Device` table. Prints the
// FACTORY JSON the tablet needs (README "flutter run ... --dart-define=FACTORY").
//
// Credentials: the static key in .env when it works; otherwise the shell's
// `aws login` session (aws configure export-credentials). Refuses to touch a
// centralId that already has a Cognito user, so nothing is overwritten.
//
// The FACTORY JSON (with the password, shown once) is also saved to
// ~/.sempreiot/centrals/<centralId>.factory.json — outside the repository,
// next to the signing key (docs/ota/signing-key.md). Never commit it.
import "dotenv/config";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { STSClient, GetCallerIdentityCommand } from "@aws-sdk/client-sts";
import { credentialsFromEnv } from "./credentials.mjs";

const [centralId, ...nameParts] = process.argv.slice(2);
const name = nameParts.join(" ").trim();

if (!centralId || !name) {
  console.error('usage: node register.mjs <centralId> "<name>"');
  process.exit(2);
}
if (!/^[a-zA-Z0-9._-]+$/.test(centralId)) {
  console.error(`centralId "${centralId}" may only contain letters, digits, . _ -`);
  process.exit(2);
}

const REGION = process.env.AWS_REGION;

async function keyWorks() {
  const creds = credentialsFromEnv();
  if (!creds) return false;
  try {
    const sts = new STSClient({ region: REGION, credentials: creds });
    await sts.send(new GetCallerIdentityCommand({}));
    return true;
  } catch (err) {
    console.error(`static key in .env rejected (${err.name}); using the aws CLI session`);
    return false;
  }
}

function useCliSession() {
  let out;
  try {
    out = execFileSync("aws", ["configure", "export-credentials", "--format", "process"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    });
  } catch {
    console.error("no usable AWS credentials: run `aws login` (or fix ACCESS_KEY_ID in .env) and retry");
    process.exit(1);
  }
  const c = JSON.parse(out);
  process.env.ACCESS_KEY_ID = c.AccessKeyId;
  process.env.SECRET_ACCESS_KEY = c.SecretAccessKey;
  if (c.SessionToken) process.env.SESSION_TOKEN = c.SessionToken;
}

if (!(await keyWorks())) useCliSession();

// Import after the credentials are settled: index.mjs reads them at load.
const { handler } = await import("./index.mjs");

const result = await handler({ body: { centralId, name } });
if (result.statusCode === 409) {
  console.error(`central "${centralId}" is already registered — nothing changed`);
  process.exit(1);
}
if (result.statusCode !== 200) {
  console.error(`registration failed (${result.statusCode}): ${result.body}`);
  process.exit(1);
}

const device = JSON.parse(result.body);
const today = new Date().toISOString().slice(0, 10);
const factory = {
  info: {
    name,
    firmware_version: "1.0.0",
    subId: device.subId,
    old_subId: "",
    created_at: today,
    updated_at: today,
  },
  credentials: {
    pin: "428412",
    unlock_pin: "123456",
    root: "admin",
    password: "Teste@123",
    level_pins: { LEVEL_1: "111111", LEVEL_2: "222222", LEVEL_3: "333333", LEVEL_4: "444444" },
  },
  iot: { iot_client_id: device.cognitoUsername, iot_password: device.password },
};

const outDir = join(homedir(), ".sempreiot", "centrals");
mkdirSync(outDir, { recursive: true, mode: 0o700 });
const outFile = join(outDir, `${centralId}.factory.json`);
// One line on purpose: flutter's option parser rejects a --dart-define value
// with newlines (it falls through as the target file), so the file must be
// usable as --dart-define="FACTORY=$(cat <file>)" as it is.
writeFileSync(outFile, JSON.stringify(factory) + "\n", { mode: 0o600 });

console.log(`\nRegistered ${centralId} ("${name}")`);
console.log(`  cognito user : ${device.cognitoUsername}`);
console.log(`  subId        : ${device.subId}`);
console.log(`  identityId   : ${device.identityId}`);
console.log(`  IoT policy   : Central_${centralId}`);
console.log(`  DynamoDB     : ${process.env.DYNAMO_TABLE}`);
console.log(`\nThe password is shown ONCE here and saved in ${outFile}\n`);
console.log("FACTORY define for the tablet (PINs are the bench defaults — change them for a customer):\n");
console.log(`  --dart-define='FACTORY=${JSON.stringify(factory)}'`);
