#! /usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

DOMAIN_NAME="hagancare.com"
PROJECT="hagancare-landing"
STAGE="prod"
REGION="ap-southeast-2"

cd "$(dirname "$0")"

echo "Deploying state buckets for ${DOMAIN_NAME}"
aws cloudformation deploy \
  --stack-name "${PROJECT}-state" \
  --template-file ./stack/state.yml \
  --no-fail-on-empty-changeset \
  --region "$REGION" \
  --parameter-overrides \
    "Stage=${STAGE}" \
    "Project=${PROJECT}"

echo
echo "Deploying HTTPS certificate in us-east-1 for ${DOMAIN_NAME}"
aws cloudformation deploy \
  --stack-name "${PROJECT}-cert" \
  --template-file ./stack/cert.yml \
  --no-fail-on-empty-changeset \
  --region us-east-1 \
  --parameter-overrides \
    "Stage=${STAGE}" \
    "Project=${PROJECT}" \
    "DomainName=${DOMAIN_NAME}"

if [[ "$?" != "0" ]]; then
  CERT_ARN="$(aws cloudformation describe-stacks \
    --region us-east-1 \
    --stack-name "${PROJECT}-cert" \
    --query 'Stacks[0].Outputs[?OutputKey==`CertArn`].OutputValue' \
    --output text \
  )"

  aws ssm put-parameter \
    --region "$REGION" \
    --name "/infra/${STAGE}/${PROJECT}/Cert" \
    --value "${CERT_ARN}" \
    --type "String" \
    --overwrite
fi

CONTENT_BUCKET="$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/infra/${STAGE}/${PROJECT}/ContentBucket" \
  --query Parameter.Value \
  --output text \
)"

echo
echo "Deploying content to ${CONTENT_BUCKET}"
aws s3 sync "./public/" "s3://$CONTENT_BUCKET" --delete
aws s3 cp "./public/index.html" "s3://$CONTENT_BUCKET/man"

echo
echo "Deploying CloudFront stack for ${DOMAIN_NAME}"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$PROJECT" \
  --template-file ./stack/distribution.yml \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "Stage=${STAGE}" \
    "Project=${PROJECT}" \
    "DomainName=${DOMAIN_NAME}" \
    "CertArn=/infra/${STAGE}/${PROJECT}/Cert" \
    "ContentBucket=/infra/${STAGE}/${PROJECT}/ContentBucket" \
    "LogsBucket=/infra/${STAGE}/${PROJECT}/LogsBucket"

CLOUDFRONT_DOMAIN="$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "${PROJECT}" \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionDomain`].OutputValue' \
  --output text \
)"

echo
echo "Deployed to ${CLOUDFRONT_DOMAIN}, you should set the CNAME for ${DOMAIN_NAME} to this"