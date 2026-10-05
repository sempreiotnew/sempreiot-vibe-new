import { IoTClient, CreatePolicyCommand, AttachPolicyCommand } from "@aws-sdk/client-iot";

const iot = new IoTClient({
  region: process.env.AWS_REGION,
  credentials: {
    accessKeyId: process.env.ACCESS_KEY_ID,
    secretAccessKey: process.env.SECRET_ACCESS_KEY,
  },
});

const ACCOUNT_ID = process.env.AWS_ACCOUNT_ID;
const REGION = process.env.AWS_REGION;

function buildPolicyDocument() {
  const base = `arn:aws:iot:${REGION}:${ACCOUNT_ID}`;
  const sub = `\${cognito-identity.amazonaws.com:sub}`;
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: "iot:Connect",
        Resource: `${base}:client/${sub}`,
      },
      {
        // AWS IoT Core requires this extra Connect grant — conditioned on the
        // "LastWill" connect attribute — specifically to authorize connecting
        // with a Last-Will message set, on top of the plain Connect above.
        // https://docs.aws.amazon.com/iot/latest/developerguide/retained-message-policy-examples.html
        Effect: "Allow",
        Action: "iot:Connect",
        Resource: `${base}:client/${sub}`,
        Condition: {
          "ForAllValues:StringEquals": {
            "iot:ConnectAttributes": ["LastWill"],
          },
        },
      },
      {
        Effect: "Allow",
        Action: "iot:Subscribe",
        Resource: [
          `${base}:topicfilter/${sub}`,
          `${base}:topicfilter/${sub}/*`,
        ],
      },
      {
        Effect: "Allow",
        Action: "iot:Receive",
        Resource: [
          `${base}:topic/${sub}`,
          `${base}:topic/${sub}/*`,
        ],
      },
      {
        // Required for the MQTT Last-Will and the retained "online" publish
        // right after connect, on the presence topic. Both iot:Publish and
        // iot:RetainPublish are required for a *retained* publish — AWS IoT
        // Core rejects the CONNECT handshake outright if the client isn't
        // authorized to publish (retained) to its own Will topic.
        // /storage carries the retained disk-usage snapshot viewers read;
        // an unauthorized publish there gets the connection dropped.
        // /alarm carries the retained list of held alarms (the mirror,
        // docs/cloud/central-mirror.md §4.5): published always, so a user
        // who opens the app after an alarm started still gets it.
        Effect: "Allow",
        Action: ["iot:Publish", "iot:RetainPublish"],
        Resource: [
          `${base}:topic/${sub}/will`,
          `${base}:topic/${sub}/storage`,
          `${base}:topic/${sub}/alarm`,
        ],
      },
      {
        // The mirror (docs/cloud/central-mirror.md): the units, the frame
        // movements and the update run, published only while a user is
        // watching. Never retained, so no iot:RetainPublish here.
        Effect: "Allow",
        Action: "iot:Publish",
        Resource: [
          `${base}:topic/${sub}/state`,
          `${base}:topic/${sub}/frames`,
          `${base}:topic/${sub}/ota`,
          `${base}:topic/${sub}/ota/*`,
        ],
      },
    ],
  });
}

export async function createAndAttachPolicy(centralId, identityId) {
  const policyName = `Central_${centralId}`;

  try {
    await iot.send(
      new CreatePolicyCommand({
        policyName,
        policyDocument: buildPolicyDocument(),
      })
    );
    console.log(`Policy created: ${policyName}`);
  } catch (err) {
    if (err.name === "ResourceAlreadyExistsException") {
      console.log(`Policy already exists: ${policyName}`);
    } else {
      throw err;
    }
  }

  await iot.send(
    new AttachPolicyCommand({
      policyName,
      target: identityId,
    })
  );

  console.log(`Policy ${policyName} attached to ${identityId}`);
  return policyName;
}
