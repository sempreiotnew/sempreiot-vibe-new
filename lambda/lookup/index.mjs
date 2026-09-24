import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";

const region = process.env.AWS_REGION ?? "us-east-1";
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));

const DEVICE_TABLE = process.env.DEVICE_TABLE ?? "Device";
const USER_TABLE = process.env.USER_TABLE ?? "User";

export async function handler(event) {
  const { subId, type, identityId } = event.queryStringParameters || {};

  // Reverse lookup: identityId → central. Used by the user app to rebuild
  // its saved-centrals list from CentralAccess rows (which only store the
  // central's identityId). The Device table is small, so a filtered scan
  // beats maintaining a GSI for now.
  if (identityId) {
    const result = await ddb.send(
      new ScanCommand({
        TableName: DEVICE_TABLE,
        FilterExpression: "identityId = :iid",
        ExpressionAttributeValues: { ":iid": identityId },
      })
    );
    const item = (result.Items ?? [])[0];
    if (!item) {
      return { statusCode: 404, body: JSON.stringify({ error: "Not found" }) };
    }
    return ok({ ...item, type: "central" });
  }

  if (!subId) {
    return {
      statusCode: 400,
      body: JSON.stringify({ error: "subId is required" }),
    };
  }

  if (type === "central") {
    return lookup(DEVICE_TABLE, subId, "central");
  }

  if (type === "user") {
    return lookup(USER_TABLE, subId, "user");
  }

  // No type specified: try User first, then Device
  const userResult = await getItem(USER_TABLE, subId);
  if (userResult) {
    return ok({ ...userResult, type: "user" });
  }

  const deviceResult = await getItem(DEVICE_TABLE, subId);
  if (deviceResult) {
    return ok({ ...deviceResult, type: "central" });
  }

  return { statusCode: 404, body: JSON.stringify({ error: "Not found" }) };
}

async function lookup(table, subId, type) {
  const item = await getItem(table, subId);
  if (!item) {
    return { statusCode: 404, body: JSON.stringify({ error: "Not found" }) };
  }
  return ok({ ...item, type });
}

async function getItem(table, subId) {
  const result = await ddb.send(
    new GetCommand({ TableName: table, Key: { subId } })
  );
  return result.Item ?? null;
}

// Presence (online/offline) is no longer resolved here — clients subscribe
// to the retained will topic directly over MQTT; the shared IoT policy's
// `topicfilter/*/will` grant makes it readable by any authenticated user.

function ok(data) {
  return {
    statusCode: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data),
  };
}
