import dotenv from "dotenv";
dotenv.config();

import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminInitiateAuthCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import {
  CognitoIdentityClient,
  GetIdCommand,
} from "@aws-sdk/client-cognito-identity";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { createAndAttachPolicy } from "./policies.mjs";

const credentials = {
  accessKeyId: process.env.ACCESS_KEY_ID,
  secretAccessKey: process.env.SECRET_ACCESS_KEY,
};

const cognito = new CognitoIdentityProviderClient({
  region: process.env.AWS_REGION,
  credentials,
});

const cognitoIdentity = new CognitoIdentityClient({
  region: process.env.AWS_REGION,
  credentials,
});

const ddb = DynamoDBDocumentClient.from(
  new DynamoDBClient({ region: process.env.AWS_REGION, credentials })
);

const USER_POOL_ID = process.env.COGNITO_USER_POOL_ID;
const CLIENT_ID = process.env.COGNITO_CLIENT_ID;
const IDENTITY_POOL_ID = process.env.COGNITO_IDENTITY_POOL_ID;
const ACCOUNT_ID = process.env.AWS_ACCOUNT_ID;
const TABLE = process.env.DYNAMO_TABLE;
const REGION = process.env.AWS_REGION;

import { randomInt } from "crypto";

function generatePassword(length = 20) {
  const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  const lower = "abcdefghijklmnopqrstuvwxyz";
  const digits = "0123456789";
  const special = "!@#$%^&*()-_=+";
  const all = upper + lower + digits + special;

  // Guarantee at least one of each required character class
  const required = [
    upper[randomInt(upper.length)],
    lower[randomInt(lower.length)],
    digits[randomInt(digits.length)],
    special[randomInt(special.length)],
  ];

  const rest = Array.from({ length: length - required.length }, () =>
    all[randomInt(all.length)]
  );

  // Shuffle required + rest together so required chars aren't always at the front
  const combined = [...required, ...rest];
  for (let i = combined.length - 1; i > 0; i--) {
    const j = randomInt(i + 1);
    [combined[i], combined[j]] = [combined[j], combined[i]];
  }

  return combined.join("");
}

export async function handler(event) {
  const body =
    typeof event.body === "string" ? JSON.parse(event.body) : event.body;

  const { centralId, name } = body || {};

  if (!centralId) {
    return {
      statusCode: 400,
      body: JSON.stringify({ error: "centralId is required" }),
    };
  }

  const deviceName = name || centralId;
  // Email-formatted username required by the user pool's username policy.
  // Spaces and special chars are not allowed in Cognito usernames — replace with dashes.
  const safeId = centralId.trim().replace(/[^a-zA-Z0-9._-]/g, "-");
  const cognitoUsername = `${safeId}@sempreiot.com`;

  const password = generatePassword();

  // --- 1. Create Cognito User Pool user ---
  let subId;
  try {
    const createResult = await cognito.send(
      new AdminCreateUserCommand({
        UserPoolId: USER_POOL_ID,
        Username: cognitoUsername,
        MessageAction: "SUPPRESS", // skip verification email/SMS
      })
    );

    const subAttr = createResult.User.Attributes.find(
      (a) => a.Name === "sub"
    );
    subId = subAttr.Value;
  } catch (err) {
    if (err.name === "UsernameExistsException") {
      return {
        statusCode: 409,
        body: JSON.stringify({ error: "Central already registered", centralId }),
      };
    }
    throw err;
  }

  // Force CONFIRMED status — no verification flow required
  await cognito.send(
    new AdminSetUserPasswordCommand({
      UserPoolId: USER_POOL_ID,
      Username: cognitoUsername,
      Password: password,
      Permanent: true,
    })
  );

  // --- 2. Sign in as central to resolve Identity Pool identity ---
  const authResult = await cognito.send(
    new AdminInitiateAuthCommand({
      AuthFlow: "ADMIN_USER_PASSWORD_AUTH",
      UserPoolId: USER_POOL_ID,
      ClientId: CLIENT_ID,
      AuthParameters: {
        USERNAME: cognitoUsername,
        PASSWORD: password,
      },
    })
  );

  const idToken = authResult.AuthenticationResult.IdToken;

  const idResult = await cognitoIdentity.send(
    new GetIdCommand({
      AccountId: ACCOUNT_ID,
      IdentityPoolId: IDENTITY_POOL_ID,
      Logins: {
        [`cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`]: idToken,
      },
    })
  );

  const identityId = idResult.IdentityId;

  // --- 3. Create IoT policy and attach to this identity ---
  await createAndAttachPolicy(centralId, identityId);

  // --- 4. Store in DynamoDB ---
  const createdAt = new Date().toISOString();
  const device = { subId, identityId, name: deviceName, createdAt };

  await ddb.send(
    new PutCommand({
      TableName: TABLE,
      Item: device,
    })
  );

  return {
    statusCode: 200,
    body: JSON.stringify({ ...device, cognitoUsername, password }),
  };
}
