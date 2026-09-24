import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { randomUUID } from "crypto";

const region = process.env.AWS_REGION ?? "us-east-1";
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));

const TABLE = process.env.CENTRAL_ACCESS_TABLE;

// Triggered by IoT Rule on topic: +/access
// IoT Rule SQL: SELECT *, topic(1) as centralIdentityId FROM '+/access'
//
// The relationship between a user and a central is a single row keyed by
// (centralIdentityId, userSubId) — like a social-media connection, not a log
// of requests. A second request from the same user just re-evaluates the
// current relationship instead of creating a duplicate row.
export async function handler(event) {
  const { centralIdentityId, userSubId, userIdentityId } = event;

  if (!centralIdentityId || !userSubId || !userIdentityId) {
    console.error("Missing required fields:", JSON.stringify(event));
    return;
  }

  const existing = await ddb.send(
    new GetCommand({ TableName: TABLE, Key: { centralIdentityId, userSubId } })
  );
  const currentStatus = existing.Item?.status;

  if (currentStatus === "PENDING" || currentStatus === "ACCEPTED") {
    console.log(`Ignored — ${userSubId} already ${currentStatus} on ${centralIdentityId}`);
    return;
  }
  if (currentStatus === "BLOCKED") {
    console.log(`Ignored — ${userSubId} is BLOCKED on ${centralIdentityId}`);
    return;
  }

  // Use client-supplied requestId (so the central can resolve without a REST roundtrip)
  // falling back to a server-generated UUID for backwards-compatibility.
  const requestId = (typeof event.requestId === "string" && event.requestId.length > 0)
    ? event.requestId
    : randomUUID();

  const now = new Date().toISOString();

  try {
    await ddb.send(
      new PutCommand({
        TableName: TABLE,
        Item: {
          centralIdentityId,
          userSubId,
          userIdentityId,
          status: "PENDING",
          requestId,
          requestedAt: now,
          updatedAt: now,
        },
        // Guards against a race with a concurrent request/resolve flipping the
        // status between our GetItem above and this PutItem.
        ConditionExpression:
          "attribute_not_exists(centralIdentityId) OR (#s <> :pending AND #s <> :accepted AND #s <> :blocked)",
        ExpressionAttributeNames: { "#s": "status" },
        ExpressionAttributeValues: {
          ":pending": "PENDING",
          ":accepted": "ACCEPTED",
          ":blocked": "BLOCKED",
        },
      })
    );
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") {
      console.log("Duplicate/raced request — ignored");
      return;
    }
    throw err;
  }

  // Presence (online/offline) needs no per-relationship grant: the shared
  // SempreIoTCognitoPolicy allows every authenticated user to subscribe to
  // any central's will topic via `topicfilter/*/will`. (In IoT policy
  // resources only `*` is a wildcard — MQTT's `+`/`#` are literal there,
  // which is what sank every earlier wildcard attempt.)

  console.log(`Stored access request: ${userSubId} → ${centralIdentityId} (requestId: ${requestId})`);
}
