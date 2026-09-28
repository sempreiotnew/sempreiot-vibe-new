flutter run -d chrome --web-port 52901 --dart-define=APP_MODE=central


flutter run \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"},"access":{"subId":"sub-9f3a21bc"}}'


Or for a release build:

flutter build apk \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"},"access":{"subId":"sub-9f3a21bc"}}'


  flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"},"access":[{"subId":"sub-9f3a21bc","role":"OWNER","pin":"123123"},{"subId":"sub-8f3a21bc","role":"ADMIN","pin":"123123"}]}'


  flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"}}'


flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"name":"Central Nome","firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"},"access":[{"subId":"sub-9f3a21bc","role":"OWNER","pin":"123123"},{"subId":"sub-8f3a21bc","role":"ADMIN","pin":"123123"}],"iot":{"iot_client_id":"central@sempreiot.com","iot_password":"Teste@123"}}'



  flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"name":"Central Nome","firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"},"access":[{"subId":"sub-9f3a21bc","role":"OWNER","pin":"123123"},{"subId":"sub-8f3a21bc","role":"ADMIN","pin":"123123"}],"iot":{"iot_client_id":"central-002@sempreiot.com","iot_password":"$y3XYZv8H)Dw@O+(7+Sy"}}'


flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"name":"Central Nome","firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","root":"admin","password":"Teste@123"},"iot":{"iot_client_id":"central-003@sempreiot.com","iot_password":"$y3XYZv8H)Dw@O+(7+Sy"}}'

  ---
Step 1 — CloudShell: DynamoDB tables

aws dynamodb create-table \
  --table-name AccessRequest \
  --attribute-definitions \
    AttributeName=requestId,AttributeType=S \
    AttributeName=centralIdentityId,AttributeType=S \
    AttributeName=userSubId,AttributeType=S \
  --key-schema AttributeName=requestId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[
    {"IndexName":"centralIdentityId-index","KeySchema":[{"AttributeName":"centralIdentityId","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}},
    {"IndexName":"userSubId-index","KeySchema":[{"AttributeName":"userSubId","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}
  ]' \
  --region us-east-1

aws dynamodb create-table \
  --table-name CentralAccess \
  --attribute-definitions \
    AttributeName=centralIdentityId,AttributeType=S \
    AttributeName=userSubId,AttributeType=S \
  --key-schema \
    AttributeName=centralIdentityId,KeyType=HASH \
    AttributeName=userSubId,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[
    {"IndexName":"userSubId-index","KeySchema":[{"AttributeName":"userSubId","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}
  ]' \
  --region us-east-1

---
Step 2 — CloudShell: IAM role for Lambdas

cat > /tmp/lambda-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role \
  --role-name SempreIoTLambdaRole \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam attach-role-policy \
  --role-name SempreIoTLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > /tmp/lambda-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem","dynamodb:GetItem","dynamodb:UpdateItem","dynamodb:Query"],
      "Resource": [
        "arn:aws:dynamodb:us-east-1:644439356850:table/AccessRequest",
        "arn:aws:dynamodb:us-east-1:644439356850:table/AccessRequest/index/*",
        "arn:aws:dynamodb:us-east-1:644439356850:table/CentralAccess",
        "arn:aws:dynamodb:us-east-1:644439356850:table/CentralAccess/index/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["iot:AttachPolicy"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["iot:Publish"],
      "Resource": "arn:aws:iot:us-east-1:644439356850:topic/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name SempreIoTLambdaRole \
  --policy-name SempreIoTLambdaPolicy \
  --policy-document file:///tmp/lambda-policy.json

---
Step 3 — Local terminal: deploy both Lambdas

# access-request
cd /Users/tallesrocha/Desktop/sempreiot-vibe-new/lambda/access-request
npm install --omit=dev
zip -r function.zip .
aws lambda create-function \
  --function-name sempreiot-access-request \
  --runtime nodejs20.x \
  --role arn:aws:iam::644439356850:role/SempreIoTLambdaRole \
  --handler index.handler \
  --zip-file fileb://function.zip \
  --environment 'Variables={AWS_REGION=us-east-1,ACCESS_REQUEST_TABLE=AccessRequest}' \
  --region us-east-1

# access-resolve
cd /Users/tallesrocha/Desktop/sempreiot-vibe-new/lambda/access-resolve
npm install --omit=dev
zip -r function.zip .
aws lambda create-function \
  --function-name sempreiot-access-resolve \
  --runtime nodejs20.x \
  --role arn:aws:iam::644439356850:role/SempreIoTLambdaRole \
  --handler index.handler \
  --zip-file fileb://function.zip \
  --environment 'Variables={AWS_REGION=us-east-1,ACCESS_REQUEST_TABLE=AccessRequest,CENTRAL_ACCESS_TABLE=CentralAccess,IOT_ENDPOINT=iot.sempreiot.com}' \
  --region us-east-1

# Function URL for access-resolve (Flutter app will call this)
aws lambda create-function-url-config \
  --function-name sempreiot-access-resolve \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST"],"AllowHeaders":["content-type"]}' \
  --region us-east-1

---
Step 4 — CloudShell: IoT Rule (run after Step 3)

cat > /tmp/iot-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"iot.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role \
  --role-name SempreIoTRuleRole \
  --assume-role-policy-document file:///tmp/iot-trust.json

cat > /tmp/iot-rule-policy.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"lambda:InvokeFunction","Resource":"arn:aws:lambda:us-east-1:644439356850:function:sempreiot-access-request"}]}
EOF

aws iam put-role-policy \
  --role-name SempreIoTRuleRole \
  --policy-name InvokeLambdaPolicy \
  --policy-document file:///tmp/iot-rule-policy.json

aws iot create-topic-rule \
  --rule-name SempreIoTAccessRequestRule \
  --topic-rule-payload '{
    "sql": "SELECT *, topic(1) as centralIdentityId FROM '"'"'+/access'"'"'",
    "actions": [{"lambda":{"functionArn":"arn:aws:lambda:us-east-1:644439356850:function:sempreiot-access-request"}}],
    "ruleDisabled": false
  }' \
  --region us-east-1

aws lambda add-permission \
  --function-name sempreiot-access-request \
  --statement-id IoTRuleInvocation \
  --action lambda:InvokeFunction \
  --principal iot.amazonaws.com \
  --source-arn arn:aws:iot:us-east-1:644439356850:rule/SempreIoTAccessRequestRule \
  --region us-east-1

---
Run Steps 1 and 2 in CloudShell now, then Step 3 locally, then Step 4 in CloudShell. The Function URL from Step 3 is what the Flutter app will call for accept/reject.


https://jjroyhm75j4uvqbh5vpd2hohcy0eqlat.lambda-url.us-east-1.on.aws/
da66b910-3b57-4a9b-b311-758bac70a7d8

czbtuf62d0


eyJwYXlsb2FkIjoie1wiY29udGV4dERhdGFcIjp7XCJEZXZpY2VJZFwiOlwiNmE5N2M1MjUtNjc0NC00NGQ4LWFiYWItOTdkZWQ0OWZjMjA5OjIwMjYtMDYtMzBUMjE6MDg6MDcuNTYxWlwiLFwiRGV2aWNlTmFtZVwiOlwibWFjT1NcIixcIkNsaWVudFRpbWV6b25lXCI6XCItMDM6MDBcIixcIkFwcGxpY2F0aW9uTmFtZVwiOlwic2VtcHJlaW90X2NlbnRyYWxfYXBwXCIsXCJBcHBsaWNhdGlvblZlcnNpb25cIjpcIjEuMC4wKDEpXCIsXCJEZXZpY2VMYW5ndWFnZVwiOlwiZW4tVVNcIixcIkRldmljZU9zUmVsZWFzZVZlcnNpb25cIjpcIkNocm9tZS8xNDkuMC4wLjBcIixcIlNjcmVlbkhlaWdodFBpeGVsc1wiOlwiMTA4MFwiLFwiU2NyZWVuV2lkdGhQaXhlbHNcIjpcIjI1NjBcIn0sXCJ1c2VybmFtZVwiOlwidGVzdGVAY2VudHJhbC5jb21cIixcInVzZXJQb29sSWRcIjpcInVzLWVhc3QtMV90Nm1UYlZjcUJcIixcInRpbWVzdGFtcFwiOlwiMTc4Mjg1MzcxMDY0N1wifSIsInNpZ25hdHVyZSI6ImFnODlNcXBYT05ydzNRS2NIUmp1U0htSmZoWUtVa2I4bllNNzRZZ0xxdnc9IiwidmVyc2lvbiI6IkZMVVRURVIyMDIzMDMwNiJ9



curl -X POST https://api.sempreiot.com/access/resolve \
  -H "Authorization: Bearer eyJraWQiOiJjeU80amtnMmpKRDF3KzIzajZPZmtIQTV0U3RJWllFcU1jZkFpMG5xckVvPSIsImFsZyI6IlJTMjU2In0.eyJzdWIiOiJjNGQ4NTRhOC1jMGExLTcwNGYtMzY1My04NzZmYzg4NzlhM2IiLCJlbWFpbF92ZXJpZmllZCI6ZmFsc2UsImlzcyI6Imh0dHBzOi8vY29nbml0by1pZHAudXMtZWFzdC0xLmFtYXpvbmF3cy5jb20vdXMtZWFzdC0xX3Q2bVRiVmNxQiIsInBob25lX251bWJlcl92ZXJpZmllZCI6dHJ1ZSwiY29nbml0bzp1c2VybmFtZSI6ImM0ZDg1NGE4LWMwYTEtNzA0Zi0zNjUzLTg3NmZjODg3OWEzYiIsIm9yaWdpbl9qdGkiOiI1MTlhYzRkMC00MjYyLTRhNjAtOWMyMS0xNTQzOTI2ZDJhN2IiLCJhdWQiOiI2a3IwbXQ4YWduOG43ZjExNnIya2wxaWY2OSIsImV2ZW50X2lkIjoiMzdhYzY0YWMtNDk5Yi00NDNhLTkwYjctOWM1YmU3Yzc4NzQ1IiwidG9rZW5fdXNlIjoiaWQiLCJhdXRoX3RpbWUiOjE3ODI4NTM5NTgsIm5hbWUiOiJUYWxsZXMiLCJwaG9uZV9udW1iZXIiOiIrNTUxMTk4ODExMDQxMiIsImV4cCI6MTc4Mjg1NzU1OCwiaWF0IjoxNzgyODUzOTU4LCJqdGkiOiJmYmRlZmIzOS1hYWE1LTRlNmItODQ1Yy1jZWRkYzRjOWZiNWQiLCJlbWFpbCI6IjU1MTE5ODgxMTA0MTJAcGhvbmUuc2VtcHJlaW90In0.hv9rQpV7aCdB7VOPuXJzpqVmMrQ0uwg5Tuceit_RP0DLEKMAO8V17lo5BlsgQjGX1G0P_vmEKdZxcOxQb1rk9DzQ2nIYGYaukokQDVGs7SIVKNw77ryuj9Q2CXMxPglFYXrUllZzJPvfQnogrfE3XUAzdwCdk9TwnJoutmrW_t4tyFxK-HR4FRw7od9gxKOTwqULvTxyTXHBtMISnlZ3HmNdfHd6kv_H8OmvRMhSocXoVrx6pvttHpJVxeJfCBTP9sKmKs5Smr34epbaxPUDYTvG6C2q4tVDOenQsLmRQZSHAPjleKLYEtQmcYczm6Fryy9W1B9rGjJ8gIZRg6Q-OQ" \
  -H "Content-Type: application/json" \
  -d '{
    "requestId": "da66b910-3b57-4a9b-b311-758bac70a7d8",
    "decision": "ACCEPTED",
    "centralId": "central-002"
  }'


  aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 6kr0mt8agn8n7f116r2kl1if69 \
  --auth-parameters USERNAME=5511988110412@phone.sempreiot,PASSWORD=Teste@123 \
  --region us-east-1 \
  --query 'AuthenticationResult.IdToken' \
  --output text; 



curl -X POST https://api.sempreiot.com/access/resolve \
  -H "Authorization: Bearer eyJraWQiOiJjeU80amtnMmpKRDF3KzIzajZPZmtIQTV0U3RJWllFcU1jZkFpMG5xckVvPSIsImFsZyI6IlJTMjU2In0.eyJzdWIiOiJjNGQ4NTRhOC1jMGExLTcwNGYtMzY1My04NzZmYzg4NzlhM2IiLCJlbWFpbF92ZXJpZmllZCI6ZmFsc2UsImlzcyI6Imh0dHBzOi8vY29nbml0by1pZHAudXMtZWFzdC0xLmFtYXpvbmF3cy5jb20vdXMtZWFzdC0xX3Q2bVRiVmNxQiIsInBob25lX251bWJlcl92ZXJpZmllZCI6dHJ1ZSwiY29nbml0bzp1c2VybmFtZSI6ImM0ZDg1NGE4LWMwYTEtNzA0Zi0zNjUzLTg3NmZjODg3OWEzYiIsIm9yaWdpbl9qdGkiOiI1MTlhYzRkMC00MjYyLTRhNjAtOWMyMS0xNTQzOTI2ZDJhN2IiLCJhdWQiOiI2a3IwbXQ4YWduOG43ZjExNnIya2wxaWY2OSIsImV2ZW50X2lkIjoiMzdhYzY0YWMtNDk5Yi00NDNhLTkwYjctOWM1YmU3Yzc4NzQ1IiwidG9rZW5fdXNlIjoiaWQiLCJhdXRoX3RpbWUiOjE3ODI4NTM5NTgsIm5hbWUiOiJUYWxsZXMiLCJwaG9uZV9udW1iZXIiOiIrNTUxMTk4ODExMDQxMiIsImV4cCI6MTc4Mjg1NzU1OCwiaWF0IjoxNzgyODUzOTU4LCJqdGkiOiJmYmRlZmIzOS1hYWE1LTRlNmItODQ1Yy1jZWRkYzRjOWZiNWQiLCJlbWFpbCI6IjU1MTE5ODgxMTA0MTJAcGhvbmUuc2VtcHJlaW90In0.hv9rQpV7aCdB7VOPuXJzpqVmMrQ0uwg5Tuceit_RP0DLEKMAO8V17lo5BlsgQjGX1G0P_vmEKdZxcOxQb1rk9DzQ2nIYGYaukokQDVGs7SIVKNw77ryuj9Q2CXMxPglFYXrUllZzJPvfQnogrfE3XUAzdwCdk9TwnJoutmrW_t4tyFxK-HR4FRw7od9gxKOTwqULvTxyTXHBtMISnlZ3HmNdfHd6kv_H8OmvRMhSocXoVrx6pvttHpJVxeJfCBTP9sKmKs5Smr34epbaxPUDYTvG6C2q4tVDOenQsLmRQZSHAPjleKLYEtQmcYczm6Fryy9W1B9rGjJ8gIZRg6Q-OQ" \
  -H "Content-Type: application/json" \
  -d '{
    "requestId": "da66b910-3b57-4a9b-b311-758bac70a7d8",
    "decision": "ACCEPTED",
    "centralId": "central-002"
  }'


  curl -X POST http://localhost:3001 \
  -H "Content-Type: application/json" \
  -d '{"centralId":"central-004","name":"Central Teste"}'


## Config the CALLBACK COGNITO
aws cognito-idp update-user-pool-client \
  --user-pool-id us-east-1_t6mTbVcqB \
  --client-id 6kr0mt8agn8n7f116r2kl1if69 \
  --region us-east-1 \
  --allowed-o-auth-flows code \
  --allowed-o-auth-flows-user-pool-client \
  --allowed-o-auth-scopes openid email \
  --supported-identity-providers Google SignInWithApple \
  --callback-urls "sempreiotcentral://callback" "http://localhost:52901/" \
  --logout-urls "sempreiotcentral://callback" "http://localhost:52901/" \
  --no-generate-secret


  aws cognito-idp update-user-pool-client \
  --user-pool-id us-east-1_t6mTbVcqB \
  --client-id 6kr0mt8agn8n7f116r2kl1if69 \
  --region us-east-1 \
  --explicit-auth-flows \
    ALLOW_USER_SRP_AUTH \
    ALLOW_REFRESH_TOKEN_AUTH \
    ALLOW_USER_PASSWORD_AUTH \
    ALLOW_ADMIN_USER_PASSWORD_AUTH


us-east-1:960b9435-b271-c27e-0781-73fe64baa097/access
    {
  "userSubId": "test-user-sub-001",
  "userIdentityId": "us-east-1:fake-identity-for-test",
  "masterPin": "428412"
}

flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"name":"Central Nome","firmware_version":"1.0.0","hash":"a1b2c3","old_hash":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","unlock_pin":"731942","root":"admin","password":"Teste@123","level_pins":{"LEVEL_1":"111111","LEVEL_2":"222222","LEVEL_3":"333333","LEVEL_4":"444444"}},"iot":{"iot_client_id":"central-003@sempreiot.com","iot_password":"$y3XYZv8H)Dw@O+(7+Sy"}}'



  flutter run -d 98cc396d \
  --dart-define=APP_MODE=central \
  --dart-define='FACTORY={"info":{"name":"Central Nome","firmware_version":"1.0.0","subId":"84b824d8-6041-701c-70a1-ba40bb4f0ab4","old_subId":"","created_at":"2026-06-25","updated_at":"2026-06-25"},"credentials":{"pin":"428412","unlock_pin":"123456","root":"admin","password":"Teste@123","level_pins":{"LEVEL_1":"111111","LEVEL_2":"222222","LEVEL_3":"333333","LEVEL_4":"444444"}},"iot":{"iot_client_id":"central-003@sempreiot.com","iot_password":"$y3XYZv8H)Dw@O+(7+Sy"}}'


  flutter run -d 00008140-00047D183A53801C --dart-define=APP_MODE=app --dart-define=DEVICE_AP_URL=http://10.0.0.130:8080