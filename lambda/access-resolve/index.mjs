import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  UpdateCommand,
  QueryCommand,
} from "@aws-sdk/lib-dynamodb";
import {
  IoTClient,
  CreatePolicyCommand,
  AttachPolicyCommand,
  DetachPolicyCommand,
  ListTargetsForPolicyCommand,
} from "@aws-sdk/client-iot";
import { IoTDataPlaneClient, PublishCommand } from "@aws-sdk/client-iot-data-plane";

const region = process.env.AWS_REGION ?? "us-east-1";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const iot = new IoTClient({ region });
const iotData = new IoTDataPlaneClient({
  region,
  endpoint: `https://${process.env.IOT_ENDPOINT}`,
});

const TABLE = process.env.CENTRAL_ACCESS_TABLE;

export async function handler(event) {
  // event.httpMethod is the API Gateway v1 (REST API) shape. This is an
  // HTTP API (v2), whose payload puts it under requestContext.http.method
  // instead — event.httpMethod is always undefined here, so this used to
  // silently default to "POST" for every GET request too.
  const method = event.httpMethod || event.requestContext?.http?.method || "POST";

  if (method === "GET") return handleList(event);
  if (method === "POST") {
    const body = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
    return handleAction(body || {});
  }

  return { statusCode: 405, body: JSON.stringify({ error: "Method not allowed" }) };
}

// GET ?centralIdentityId=... → every relationship row for a central
//     (pending / accepted / rejected / blocked — the app buckets them)
// GET ?userSubId=...         → every relationship row for a user
async function handleList(event) {
  const { centralIdentityId, userSubId } = event.queryStringParameters || {};

  if (!centralIdentityId && !userSubId) {
    return {
      statusCode: 400,
      body: JSON.stringify({ error: "centralIdentityId or userSubId required" }),
    };
  }

  const result = centralIdentityId
    ? await ddb.send(
        new QueryCommand({
          TableName: TABLE,
          KeyConditionExpression: "centralIdentityId = :cid",
          ExpressionAttributeValues: { ":cid": centralIdentityId },
        })
      )
    : await ddb.send(
        new QueryCommand({
          TableName: TABLE,
          IndexName: "userSubId-index",
          KeyConditionExpression: "userSubId = :uid",
          ExpressionAttributeValues: { ":uid": userSubId },
        })
      );

  return { statusCode: 200, body: JSON.stringify(result.Items) };
}

// POST { action, centralIdentityId, userSubId, centralId, ... }
// action: 'RESOLVE' (default) | 'LEVEL_CHANGE' | 'BLOCK' | 'UNBLOCK'
async function handleAction(body) {
  const action = body.action || "RESOLVE";

  switch (action) {
    case "RESOLVE":
      return handleResolve(body);
    case "LEVEL_CHANGE":
      return handleLevelChange(body);
    case "BLOCK":
      return handleBlock(body);
    case "UNBLOCK":
      return handleUnblock(body);
    default:
      return { statusCode: 400, body: JSON.stringify({ error: `Unknown action: ${action}` }) };
  }
}

async function getRelation(centralIdentityId, userSubId) {
  const result = await ddb.send(
    new GetCommand({ TableName: TABLE, Key: { centralIdentityId, userSubId } })
  );
  return result.Item ?? null;
}

// { action: 'RESOLVE', centralIdentityId, userSubId, decision: ACCEPTED|REJECTED, centralId }
async function handleResolve(body) {
  const { centralIdentityId, userSubId, decision, centralId } = body;

  if (!centralIdentityId || !userSubId || !["ACCEPTED", "REJECTED"].includes(decision) || !centralId) {
    return {
      statusCode: 400,
      body: JSON.stringify({
        error: "centralIdentityId, userSubId, decision (ACCEPTED|REJECTED), and centralId required",
      }),
    };
  }

  const relation = await getRelation(centralIdentityId, userSubId);
  if (!relation) {
    return { statusCode: 404, body: JSON.stringify({ error: "Request not found" }) };
  }
  if (relation.status !== "PENDING") {
    return { statusCode: 409, body: JSON.stringify({ error: "Request already resolved" }) };
  }

  const resolvedAt = new Date().toISOString();

  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { centralIdentityId, userSubId },
      UpdateExpression: decision === "ACCEPTED"
        ? "SET #s = :status, #l = :level, resolvedAt = :resolvedAt, updatedAt = :resolvedAt"
        : "SET #s = :status, resolvedAt = :resolvedAt, updatedAt = :resolvedAt",
      ExpressionAttributeNames: decision === "ACCEPTED"
        ? { "#s": "status", "#l": "level" }
        : { "#s": "status" },
      ExpressionAttributeValues: decision === "ACCEPTED"
        ? { ":status": decision, ":level": "LEVEL_1", ":resolvedAt": resolvedAt }
        : { ":status": decision, ":resolvedAt": resolvedAt },
    })
  );

  if (decision === "ACCEPTED") {
    await grantUserCentralAccess(centralId, centralIdentityId, userSubId, relation.userIdentityId);
  }

  await publishToUser(relation.userIdentityId, {
    decision,
    centralIdentityId,
    level: decision === "ACCEPTED" ? "LEVEL_1" : undefined,
    resolvedAt,
  });

  return { statusCode: 200, body: JSON.stringify({ decision, resolvedAt }) };
}

// { action: 'LEVEL_CHANGE', centralIdentityId, userSubId, level, centralId, masterRemoval? }
// PIN correctness for the target level — and root+senha for MASTER
// operations — is verified locally on the central device before this call.
// TODO: also verify the caller's JWT sub is this central's machine user so
// a regular user token can't drive these mutations directly.
async function handleLevelChange(body) {
  const { centralIdentityId, userSubId, level } = body;
  const validLevels = ["LEVEL_1", "LEVEL_2", "LEVEL_3", "LEVEL_4", "MASTER"];

  if (!centralIdentityId || !userSubId || !validLevels.includes(level)) {
    return {
      statusCode: 400,
      body: JSON.stringify({ error: `centralIdentityId, userSubId, and level (${validLevels.join("|")}) required` }),
    };
  }

  const relation = await getRelation(centralIdentityId, userSubId);
  if (!relation) {
    return { statusCode: 404, body: JSON.stringify({ error: "Relationship not found" }) };
  }
  if (relation.status !== "ACCEPTED") {
    return { statusCode: 409, body: JSON.stringify({ error: "User does not have accepted access" }) };
  }

  // MASTER is unique per central: refuse a second grant.
  if (level === "MASTER") {
    const rows = await ddb.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "centralIdentityId = :cid",
        ExpressionAttributeValues: { ":cid": centralIdentityId },
      })
    );
    const otherMaster = (rows.Items ?? []).find(
      (r) => r.level === "MASTER" && r.status === "ACCEPTED" && r.userSubId !== userSubId
    );
    if (otherMaster) {
      return { statusCode: 409, body: JSON.stringify({ error: "Central already has a MASTER user" }) };
    }
  }

  // MASTER cannot be kicked or silently demoted: touching a MASTER relation
  // requires the explicit masterRemoval flag, which the central only sends
  // after verifying the root + senha ownership credentials locally.
  if (relation.level === "MASTER" && level !== "MASTER" && body.masterRemoval !== true) {
    return {
      statusCode: 403,
      body: JSON.stringify({ error: "MASTER can only be demoted with root authorization (masterRemoval)" }),
    };
  }

  const updatedAt = new Date().toISOString();

  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { centralIdentityId, userSubId },
      UpdateExpression: "SET #l = :level, updatedAt = :updatedAt",
      ExpressionAttributeNames: { "#l": "level" },
      ExpressionAttributeValues: { ":level": level, ":updatedAt": updatedAt },
    })
  );

  await publishToUser(relation.userIdentityId, {
    decision: "LEVEL_CHANGED",
    centralIdentityId,
    level,
    resolvedAt: updatedAt,
  });

  return { statusCode: 200, body: JSON.stringify({ level, updatedAt }) };
}

// { action: 'BLOCK', centralIdentityId, userSubId, centralId }
async function handleBlock(body) {
  const { centralIdentityId, userSubId, centralId } = body;

  if (!centralIdentityId || !userSubId) {
    return { statusCode: 400, body: JSON.stringify({ error: "centralIdentityId and userSubId required" }) };
  }

  const relation = await getRelation(centralIdentityId, userSubId);
  if (!relation) {
    return { statusCode: 404, body: JSON.stringify({ error: "Relationship not found" }) };
  }

  // MASTER cannot be kicked. The only path out is a root-authorized
  // demotion (LEVEL_CHANGE with masterRemoval), after which a block works.
  if (relation.level === "MASTER") {
    return { statusCode: 403, body: JSON.stringify({ error: "MASTER user cannot be blocked — demote first with root authorization" }) };
  }

  // Revoke live MQTT access immediately if they had a full-access grant.
  if (relation.status === "ACCEPTED" && centralId) {
    await revokeUserCentralAccess(centralId, userSubId);
  }

  const resolvedAt = new Date().toISOString();

  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { centralIdentityId, userSubId },
      UpdateExpression: "SET #s = :status, updatedAt = :resolvedAt REMOVE #l",
      ExpressionAttributeNames: { "#s": "status", "#l": "level" },
      ExpressionAttributeValues: { ":status": "BLOCKED", ":resolvedAt": resolvedAt },
    })
  );

  await publishToUser(relation.userIdentityId, {
    decision: "BLOCKED",
    centralIdentityId,
    resolvedAt,
  });

  return { statusCode: 200, body: JSON.stringify({ status: "BLOCKED", resolvedAt }) };
}

// { action: 'UNBLOCK', centralIdentityId, userSubId }
// Flips back to REJECTED — allowed to request again, but not auto-reconnected.
async function handleUnblock(body) {
  const { centralIdentityId, userSubId } = body;

  if (!centralIdentityId || !userSubId) {
    return { statusCode: 400, body: JSON.stringify({ error: "centralIdentityId and userSubId required" }) };
  }

  const relation = await getRelation(centralIdentityId, userSubId);
  if (!relation || relation.status !== "BLOCKED") {
    return { statusCode: 409, body: JSON.stringify({ error: "User is not blocked" }) };
  }

  const resolvedAt = new Date().toISOString();

  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { centralIdentityId, userSubId },
      UpdateExpression: "SET #s = :status, updatedAt = :resolvedAt",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: { ":status": "REJECTED", ":resolvedAt": resolvedAt },
    })
  );

  await publishToUser(relation.userIdentityId, {
    decision: "REJECTED",
    centralIdentityId,
    resolvedAt,
  });

  return { statusCode: 200, body: JSON.stringify({ status: "REJECTED", resolvedAt }) };
}

async function publishToUser(userIdentityId, payload) {
  await iotData.send(
    new PublishCommand({
      topic: `${userIdentityId}/access-response`,
      payload: JSON.stringify(payload),
      qos: 1,
    })
  );
}

// Creates a dedicated IoT policy for this user-central pair and attaches it.
// Policy name: Access_{centralId}_{userSubId}
// Grants subscribe + receive on all central topics + publish to send commands.
async function grantUserCentralAccess(centralId, centralIdentityId, userSubId, userIdentityId) {
  const policyName = `Access_${centralId}_${userSubId}`;
  const base = `arn:aws:iot:${region}:${process.env.AWS_ACCOUNT_ID}`;

  const policyDocument = JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: ["iot:Subscribe"],
        Resource: [
          `${base}:topicfilter/${centralIdentityId}`,
          `${base}:topicfilter/${centralIdentityId}/*`,
        ],
      },
      {
        Effect: "Allow",
        Action: ["iot:Receive"],
        Resource: [
          `${base}:topic/${centralIdentityId}`,
          `${base}:topic/${centralIdentityId}/*`,
        ],
      },
      {
        Effect: "Allow",
        Action: "iot:Publish",
        Resource: `${base}:topic/${centralIdentityId}`,
      },
    ],
  });

  try {
    await iot.send(new CreatePolicyCommand({ policyName, policyDocument }));
  } catch (err) {
    if (err.name !== "ResourceAlreadyExistsException") throw err;
  }

  await iot.send(new AttachPolicyCommand({ policyName, target: userIdentityId }));

  console.log(`IoT policy ${policyName} created and attached to ${userIdentityId}`);
}

// Detaches the full-access policy created by grantUserCentralAccess. The
// policy resource itself is left in place (harmless once detached) — only
// the attachment to this user's identity is removed.
async function revokeUserCentralAccess(centralId, userSubId) {
  const policyName = `Access_${centralId}_${userSubId}`;

  const attached = await iot
    .send(new ListTargetsForPolicyCommand({ policyName }))
    .catch((err) => {
      if (err.name === "ResourceNotFoundException") return { targets: [] };
      throw err;
    });

  for (const target of attached.targets ?? []) {
    await iot.send(new DetachPolicyCommand({ policyName, target })).catch((err) => {
      if (err.name !== "ResourceNotFoundException") throw err;
    });
  }

  console.log(`IoT policy ${policyName} detached from all targets`);
}
