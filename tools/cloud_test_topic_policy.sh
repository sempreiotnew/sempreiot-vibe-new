#!/usr/bin/env bash
# tools/cloud_test_topic_policy.sh — let every live central publish its system tests (retained)
# on <its Identity ID>/test (docs/cloud/central-mirror.md §4.7, §7). Safe to run again: it only
# touches a Central_* policy that lacks the topic, and says what it did.
#
#   tools/cloud_test_topic_policy.sh            apply
#   tools/cloud_test_topic_policy.sh --check    only show what is there, change nothing
#
# Run it with your own AWS login (`aws login`), BEFORE a tablet gets the app build of 2026-10-14:
# that build publishes `test` right after it connects, and AWS IoT drops a client that publishes
# where its policy does not allow — the tablet then reconnects and is dropped again, for ever
# ("wifi: limited" flapping on Principal). New centrals get the topic from
# lambda/central/policies.mjs; this script is for the policies that already exist.
# Env: SIOT_RELEASE_REGION (default us-east-1).
set -euo pipefail

REGION="${SIOT_RELEASE_REGION:-us-east-1}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
[[ -z "${1:-}" || "$CHECK" -eq 1 ]] || { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 2; }
AWS=(aws --region "$REGION")
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

ACCOUNT="$("${AWS[@]}" sts get-caller-identity --query Account --output text)" \
    || { echo "ERROR: AWS credentials do not work: run 'aws login' first" >&2; exit 1; }
echo "account $ACCOUNT, region $REGION$([[ $CHECK -eq 1 ]] && echo ' — CHECK ONLY, nothing changes')"
echo "Central_* IoT policies: publish + retain on <id>/test"

for P in $("${AWS[@]}" iot list-policies --query 'policies[?starts_with(policyName, `Central_`)].policyName' --output text); do
    "${AWS[@]}" iot get-policy --policy-name "$P" --query policyDocument --output text > "$WORK/doc.json"
    if grep -q 'sub}/test"' "$WORK/doc.json"; then
        echo "   $P: present"; continue
    fi
    if [[ "$CHECK" -eq 1 ]]; then echo "   $P: MISSING"; continue; fi
    # The same grant the builder gives (lambda/central/policies.mjs): Publish AND RetainPublish —
    # a retained publish needs both — as its own statement, so nothing else of the policy moves.
    python3 - "$WORK/doc.json" "$REGION" "$ACCOUNT" <<'EOF'
import json, sys
path, region, account = sys.argv[1:]
doc = json.load(open(path))
base = f"arn:aws:iot:{region}:{account}"
sub = "${cognito-identity.amazonaws.com:sub}"
doc["Statement"].append({
    "Effect": "Allow",
    "Action": ["iot:Publish", "iot:RetainPublish"],
    "Resource": [f"{base}:topic/{sub}/test"],
})
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
echo
echo "Done. A tablet that was being dropped reconnects by itself (it retries every 5 s)."
