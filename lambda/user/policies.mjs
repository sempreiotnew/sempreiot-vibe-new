import {IoTClient, AttachPolicyCommand} from "@aws-sdk/client-iot"

  const iot = new IoTClient({ region: process.env.AWS_REGION,
    credentials : {
        accessKeyId : process.env.ACCESS_KEY_ID,
        secretAccessKey : process.env.SECRET_ACCESS_KEY
    }
  });
  const POLICY_NAME = process.env.IOT_POLICY_NAME;

  export async function attachPolicy(id){
    // const identityId =  `${process.env.AWS_REGION}:${subId}`
    const identityId =  id;

    if (!identityId) {
      return { statusCode: 400, body: "Missing identityId" };
    }

    console.log(POLICY_NAME)
    console.log(identityId)

    try {
      await iot.send(new AttachPolicyCommand({
        policyName: POLICY_NAME,
        target: identityId,
      }));

      return { statusCode: 200, body: JSON.stringify({ attached: true }) };
    } catch (error) {
      // AlreadyExistsException is fine — policy already attached
      if (error.name === "ResourceAlreadyExistsException") {
        return { statusCode: 200, body: JSON.stringify({ attached: true }) };
      }
      console.error("AttachPolicy error:", error.message);
      return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
    }
  }