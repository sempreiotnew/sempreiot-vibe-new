#!/usr/bin/env bash
# firmware/tools/ota_cloud_setup.sh — the cloud side of OTA through the Internet, made once
# (docs/ota/ota-internet-plan.md §4). Safe to run again: every step checks first and says what it did.
#
#   tools/ota_cloud_setup.sh            all steps
#   tools/ota_cloud_setup.sh --check    only show what is there, change nothing
#
#   1. bucket sempreiot-releases: private (public access blocked), versioning, default encryption
#   2. role CognitoAuthSigv4AwsIot (the identity pool's): read the images (s3:GetObject) of every
#      channel and of the caller's OWN centrals/<Identity ID>/ folder — never another central's
#   3. every live Central_* IoT policy: subscribe to / receive sempreiot/releases/*
#      (new centrals get it from lambda/central/policies.mjs)
#   4. the shared user policy SempreIoTCognitoPolicy: publish on */cmd/<the user's own Identity ID>
#      (an Internet update started from a phone; the central knows who asks from the topic)
#
# Run it with your own AWS login (`aws login`), BEFORE installing an app build that subscribes to
# the releases: AWS IoT drops a central that subscribes outside its policy.
# Env: SIOT_RELEASE_BUCKET, SIOT_RELEASE_REGION.
set -euo pipefail

BUCKET="${SIOT_RELEASE_BUCKET:-sempreiot-releases}"
REGION="${SIOT_RELEASE_REGION:-us-east-1}"
ROLE="CognitoAuthSigv4AwsIot"
ROLE_POLICY="SempreIoTReleasesRead"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
[[ -z "${1:-}" || "$CHECK" -eq 1 ]] || { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 2; }
AWS=(aws --region "$REGION")
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

ACCOUNT="$("${AWS[@]}" sts get-caller-identity --query Account --output text)" \
    || { echo "ERROR: AWS credentials do not work: run 'aws login' first" >&2; exit 1; }
echo "account $ACCOUNT, region $REGION$([[ $CHECK -eq 1 ]] && echo ' — CHECK ONLY, nothing changes')"
echo

# ---- 1. bucket -----------------------------------------------------------------------------------
echo "1. bucket $BUCKET"
if "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    echo "   exists"
elif [[ "$CHECK" -eq 1 ]]; then
    echo "   MISSING"
else
    if [[ "$REGION" == us-east-1 ]]; then
        "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" > /dev/null
    else
        "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" > /dev/null
    fi
    echo "   created"
fi
if [[ "$CHECK" -eq 0 ]]; then
    "${AWS[@]}" s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    "${AWS[@]}" s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
    "${AWS[@]}" s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    echo "   private, versioned, encrypted"
fi

# ---- 2. role: read the images --------------------------------------------------------------------
echo "2. role $ROLE: $ROLE_POLICY"
# The releases for everyone (one folder per channel), and a central's OWN folder only:
# ${cognito-identity.amazonaws.com:sub} is the caller's Identity ID, the name of that folder.
SELF='${cognito-identity.amazonaws.com:sub}'
cat > "$WORK/role.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadFirmwareReleases",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": [
        "arn:aws:s3:::$BUCKET/bench/*",
        "arn:aws:s3:::$BUCKET/stable/*",
        "arn:aws:s3:::$BUCKET/centrals/$SELF/*"
      ]
    }
  ]
}
EOF
if "${AWS[@]}" iam get-role-policy --role-name "$ROLE" --policy-name "$ROLE_POLICY" \
        --query PolicyDocument --output json > "$WORK/role.now.json" 2>/dev/null; then
    if python3 -c 'import json,sys; a,b=(json.load(open(p)) for p in sys.argv[1:]); sys.exit(a!=b)' \
            "$WORK/role.now.json" "$WORK/role.json"; then
        echo "   present"
    elif [[ "$CHECK" -eq 1 ]]; then
        echo "   OUT OF DATE (a central could read another central's folder)"
    else
        "${AWS[@]}" iam put-role-policy --role-name "$ROLE" --policy-name "$ROLE_POLICY" \
            --policy-document "file://$WORK/role.json"
        echo "   updated (channels + each central's own folder)"
    fi
elif [[ "$CHECK" -eq 1 ]]; then
    echo "   MISSING"
else
    "${AWS[@]}" iam put-role-policy --role-name "$ROLE" --policy-name "$ROLE_POLICY" \
        --policy-document "file://$WORK/role.json"
    echo "   added (channels + each central's own folder)"
fi

# ---- 3. central IoT policies: hear the releases --------------------------------------------------
echo "3. Central_* IoT policies: sempreiot/releases/*"
for P in $("${AWS[@]}" iot list-policies --query 'policies[?starts_with(policyName, `Central_`)].policyName' --output text); do
    "${AWS[@]}" iot get-policy --policy-name "$P" --query policyDocument --output text > "$WORK/doc.json"
    if grep -q "sempreiot/releases" "$WORK/doc.json"; then
        echo "   $P: present"; continue
    fi
    if [[ "$CHECK" -eq 1 ]]; then echo "   $P: MISSING"; continue; fi
    python3 - "$WORK/doc.json" "$REGION" "$ACCOUNT" <<'EOF'
import json, sys
path, region, account = sys.argv[1:]
doc = json.load(open(path))
base = f"arn:aws:iot:{region}:{account}"
doc["Statement"] += [
    {"Effect": "Allow", "Action": "iot:Subscribe", "Resource": [f"{base}:topicfilter/sempreiot/releases/*"]},
    {"Effect": "Allow", "Action": "iot:Receive", "Resource": [f"{base}:topic/sempreiot/releases/*"]},
]
json.dump(doc, open(path, "w"))
EOF
    # AWS keeps at most 5 versions of a policy: drop the oldest that is not the default.
    COUNT="$("${AWS[@]}" iot list-policy-versions --policy-name "$P" --query 'length(policyVersions)' --output text)"
    if [[ "$COUNT" -ge 5 ]]; then
        OLDEST="$("${AWS[@]}" iot list-policy-versions --policy-name "$P" \
            --query 'sort_by(policyVersions[?isDefaultVersion==`false`], &createDate)[0].versionId' --output text)"
        "${AWS[@]}" iot delete-policy-version --policy-name "$P" --policy-version-id "$OLDEST"
        echo "   $P: deleted old version $OLDEST (5-version limit)"
    fi
    V="$("${AWS[@]}" iot create-policy-version --policy-name "$P" --policy-document "file://$WORK/doc.json" \
        --set-as-default --query policyVersionId --output text)"
    echo "   $P: version $V is now the default"
done

# ---- 4. users: a phone's command, under its own identity ------------------------------------------
# An Internet update started from a phone (plan §5.4) goes on <central>/cmd/<the user's Identity ID>.
# The shared user policy lets each user publish ONLY under its own Identity ID there, so the central
# knows who asks from the topic. The policy lives only in AWS (lambda/user attaches it by name).
USER_POLICY="SempreIoTCognitoPolicy"
echo "4. $USER_POLICY: */cmd/<own Identity ID>"
"${AWS[@]}" iot get-policy --policy-name "$USER_POLICY" --query policyDocument --output text > "$WORK/user.json"
if grep -q '/cmd/' "$WORK/user.json"; then
    echo "   present"
elif [[ "$CHECK" -eq 1 ]]; then
    echo "   MISSING"
else
    python3 - "$WORK/user.json" "$REGION" "$ACCOUNT" <<'EOF'
import json, sys
path, region, account = sys.argv[1:]
doc = json.load(open(path))
doc["Statement"].append({
    "Effect": "Allow",
    "Action": "iot:Publish",
    "Resource": f"arn:aws:iot:{region}:{account}:topic/*/cmd/${{cognito-identity.amazonaws.com:sub}}",
})
json.dump(doc, open(path, "w"))
EOF
    COUNT="$("${AWS[@]}" iot list-policy-versions --policy-name "$USER_POLICY" --query 'length(policyVersions)' --output text)"
    if [[ "$COUNT" -ge 5 ]]; then
        OLDEST="$("${AWS[@]}" iot list-policy-versions --policy-name "$USER_POLICY" \
            --query 'sort_by(policyVersions[?isDefaultVersion==`false`], &createDate)[0].versionId' --output text)"
        "${AWS[@]}" iot delete-policy-version --policy-name "$USER_POLICY" --policy-version-id "$OLDEST"
        echo "   deleted old version $OLDEST (5-version limit)"
    fi
    V="$("${AWS[@]}" iot create-policy-version --policy-name "$USER_POLICY" --policy-document "file://$WORK/user.json" \
        --set-as-default --query policyVersionId --output text)"
    echo "   version $V is now the default"
fi

echo
echo "done. Next: firmware/tools/ota_release.sh <version> --notes \"...\""
