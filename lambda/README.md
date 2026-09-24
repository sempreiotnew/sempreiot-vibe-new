aws iot list-attached-policies \
    --target "us-east-1:e478b4d8-90b1-70e5-4866-8281a717813b" \
    --region us-east-1


aws iot detach-policy \
    --policy-name SempreIoTCognitoPolicy \
    --target "us-east-1:960b9435-b2e5-cd1f-ede5-fdf96eec9884" \
    --region us-east-1    


aws iot list-targets-for-policy \
    --policy-name "SempreIoTCognitoPolicy" \
    --region us-east-1


    b4585478-e031-7039-3e00-919f7d6bf154
    64e80458-f0c1-7040-c380-29f426df570c 
    e478b4d8-90b1-70e5-4866-8281a717813b
    34489458-20f1-7052-2435-dfb2fc258e45
    94a8f4b8-f091-701f-ffa9-0680dc4e8382



## Allow COGNITO role with SNS
aws cognito-idp update-user-pool \
    --user-pool-id us-east-1_t6mTbVcqB \
    --region us-east-1 \
    --auto-verified-attributes email phone_number \
    --sms-configuration SnsCallerArn=arn:aws:iam::644439356850:role/CognitoSNSTrusted,ExternalId=sempreiot-sms



    auth.sempreiot.com
A
Simple
-
Yes
dsg12zrfotn1l.cloudfront.net.
-
-
No
authentication.sempreiot.com
A
Simple
-
Yes
d84l1y8p4kdic.cloudfront.net.