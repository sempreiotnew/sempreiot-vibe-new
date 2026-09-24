import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
  import {
    DynamoDBDocumentClient,
    GetCommand,
    PutCommand,
  } from "@aws-sdk/lib-dynamodb";
  import {
    CognitoIdentityProviderClient,
    ListUsersCommand,
  } from "@aws-sdk/client-cognito-identity-provider";

  import { attachPolicy } from "./policies.mjs";

  const credentials = {
    accessKeyId: process.env.ACCESS_KEY_ID,
    secretAccessKey: process.env.SECRET_ACCESS_KEY,
  };

  const client = new DynamoDBClient({ region: process.env.AWS_REGION, credentials });
  const ddb = DynamoDBDocumentClient.from(client);
  const cognito = new CognitoIdentityProviderClient({ region: process.env.AWS_REGION, credentials });

  const TABLE = process.env.DYNAMO_TABLE;
  const USER_POOL_ID = process.env.USER_POOL_ID;

  export async function handler(event) {
    const method = event.httpMethod || event.requestContext?.http?.method || "POST";
    const path = event.path || event.rawPath || "";

    if (method === "GET" && path.includes("check-email")) {
      return handleCheckEmail(event);
    }

    return handleRegisterUser(event);
  }

  // async function handleCheckEmail(event) {
  //   const { email, phone } = event.queryStringParameters || {};

  //   if (!email && !phone) {
  //     return {
  //       statusCode: 400,
  //       body: JSON.stringify({ error: "email or phone is required" }),
  //     };
  //   }

  //   const filter = email
  //     ? `email = "${email}"`
  //     : `phone_number = "${phone}"`;

  //   const result = await cognito.send(
  //     new ListUsersCommand({
  //       UserPoolId: USER_POOL_ID,
  //       Filter: filter,
  //       Limit: 1,
  //     })
  //   );

  //   const user = result.Users?.[0];
  //   const exists = !!user;
  //   const confirmed = exists && user.UserStatus === "CONFIRMED";

  //   return {
  //     statusCode: 200,
  //     headers: { "Content-Type": "application/json" },
  //     body: JSON.stringify({ exists, confirmed }),
  //   };
  // }
  async function handleCheckEmail(event) {
    const { email, phone } = event.queryStringParameters || {};

    if (!email && !phone) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "email or phone is required" }),
      };
    }

    const filter = email
      ? `email = "${email}"`
      : `phone_number = "${phone}"`;

    const result = await cognito.send(
      new ListUsersCommand({
        UserPoolId: USER_POOL_ID,
        Filter: filter,
        Limit: 5,
      })
    );

    const users = result.Users || [];
    // CONFIRMED = local password user, EXTERNAL_PROVIDER = Google/Apple
    const hasLocalUser = users.some(u => u.UserStatus === "CONFIRMED");
    const confirmed = users.some(
      u => u.UserStatus === "CONFIRMED" || u.UserStatus === "EXTERNAL_PROVIDER"
    );

    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        exists: users.length > 0,
        confirmed,
        hasLocalUser,
      }),
    };
  }

  // async function handleRegisterUser(event) {
  //   const body =
  //     typeof event.body === "string" ? JSON.parse(event.body) : event.body;

  //   const { subId, identityId, email } = body || {};

  //   if (!subId) {
  //     return {
  //       statusCode: 400,
  //       body: JSON.stringify({ error: "subId is required" }),
  //     };
  //   }

  //   const result = await ddb.send(
  //     new GetCommand({ TableName: TABLE, Key: { subId } })
  //   );

  //   if (result.Item) {
  //     console.log("User Already CREATED");
  //     return { statusCode: 200, body: JSON.stringify(result.Item) };
  //   }

  //   const policyResult = await attachPolicy(identityId);

  //   if (policyResult.statusCode == 200) {
  //     const newUser = {
  //       subId,
  //       email,
  //       createdAt: new Date().toISOString(),
  //     };

  //     await ddb.send(new PutCommand({ TableName: TABLE, Item: newUser }));

  //     return { statusCode: 200, body: JSON.stringify(newUser) };
  //   } else {
  //     return { statusCode: 400, body: JSON.stringify(policyResult.body) };
  //   }
  // }

  async function handleRegisterUser(event) {
    const body =
      typeof event.body === "string" ? JSON.parse(event.body) : event.body;

    const { subId, identityId, email } = body || {};

    if (!subId) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "subId is required" }),
      };
    }

    const result = await ddb.send(
      new GetCommand({ TableName: TABLE, Key: { subId } })
    );

    if (result.Item) {
      console.log("User Already CREATED");
      return { statusCode: 200, body: JSON.stringify(result.Item) };
    }

    // Block if this email already belongs to a confirmed local (non-federated) user
    if (email) {
      const emailCheck = await cognito.send(
        new ListUsersCommand({
          UserPoolId: USER_POOL_ID,
          Filter: `email = "${email}"`,
          Limit: 5,
        })
      );

      const hasConflict = emailCheck.Users?.some((u) => {
        if (u.UserStatus !== "CONFIRMED") return false;
        const sub = u.Attributes?.find((a) => a.Name === "sub")?.Value;
        return sub && sub !== subId;
      });

      if (hasConflict) {
        return {
          statusCode: 409,
          body: JSON.stringify({ error: "email_already_registered" }),
        };
      }
    }

    const policyResult = await attachPolicy(identityId);

    if (policyResult.statusCode == 200) {
      const newUser = {
        subId,
        identityId,
        email,
        createdAt: new Date().toISOString(),
      };

      await ddb.send(new PutCommand({ TableName: TABLE, Item: newUser }));

      return { statusCode: 200, body: JSON.stringify(newUser) };
    } else {
      return {
        statusCode: 400,
        body: JSON.stringify(policyResult.body),
      };
    }
  }