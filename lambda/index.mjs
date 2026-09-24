import dotenv from "dotenv";
dotenv.config();

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
} from "@aws-sdk/lib-dynamodb";

import { attachPolicy } from "./policies.mjs" 

const client = new DynamoDBClient({
  region: process.env.AWS_REGION,
  credentials : {
    accessKeyId : process.env.ACCESS_KEY_ID,
    secretAccessKey : process.env.SECRET_ACCESS_KEY
  }
});

const ddb = DynamoDBDocumentClient.from(client);

const TABLE = process.env.DYNAMO_TABLE;
const Permission = {
  READ: "1",
  WRITE: "2",
};

// ✅ proper ESM export
export async function handler(event) {
  const body =
    typeof event.body === "string" ? JSON.parse(event.body) : event.body;

    const method = event.httpMethod;
    console.log(`Method: ${method}`); // "GET", "POST", etc.


  const { subId, email, phone } = body || {};
  
  if(method === "GET"){
    if (!subId) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "subId is required" }),
      };
    }
    
    const result = await ddb.send(
      new GetCommand({
        TableName: TABLE,
        Key: { subId },
      })
    );
  
    if (result.Item) {
      console.log("User Already CREATED")
      return {
        statusCode: 200,
        body: JSON.stringify(result.Item),
      };
    }
    return {
      statusCode: 404,
      body: JSON.stringify({ error: "User not found" }),
    };
  
  }

  if(method === "POST"){
    const result = await ddb.send(
      new GetCommand({
        TableName: TABLE,
        Key: { subId },
      })
    );

    if(result.Item){
      return {
        statusCode: 200,
        body: JSON.stringify(result.Item),
      };
    }

    const policyResult = await attachPolicy(subId);

      if(policyResult.statusCode == 200){
        const newUser = {
          subId,
          email,
          createdAt: new Date().toISOString(),
        };
      
        await ddb.send(
          new PutCommand({
            TableName: TABLE,
            Item: newUser,
          })
        );
      
        return {
          statusCode: 200,
          body: JSON.stringify(newUser),
        };
      } else {
        return {
          statusCode: 400,
          body: JSON.stringify(policyResult.body),
        }
      }
  }   

  function teste{}
  
    // const command = new QueryCommand({
    //   TableName: TABLE,
    //   IndexName: "email-index",
    //   KeyConditionExpression: "email = :email",
    //   ExpressionAttributeValues: {
    //     ":email": email,
    //   },
    // })
    // const result = await ddb.send(command);

    // if(result.Items.length > 0){
    //   return {
    //     statusCode: 400,
    //     body: JSON.stringify({ error: "User already exists" }),
    //   };
    // } else {
      
    // }
  
}