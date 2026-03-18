#!/bin/bash
# Creates the walg-config secret from OBC-provisioned credentials.
# Run after 01-obc.yaml is Bound.
#
# Usage:
#   export DEMO_NS=vbns-postgres-demo
#   ./postgres/pitr/02-walg-secret.sh
#
# S3_ENDPOINT: override to use the external NooBaa route instead of the
# internal service (recommended — avoids internal TLS cert issues).
# Default: https://s3-openshift-storage.apps.<your-cluster-domain>
#
#   S3_ENDPOINT=https://s3-openshift-storage.apps.ocp-dc3.demo.presales.trilio.io \
#   ./postgres/pitr/02-walg-secret.sh

set -euo pipefail

NS="${DEMO_NS:-trilio-db-demo}"
OBC_NAME="postgres-wal-archive"

echo "Reading OBC credentials from namespace: $NS"

BUCKET_NAME=$(kubectl get configmap "$OBC_NAME" -n "$NS" -o jsonpath='{.data.BUCKET_NAME}')
ACCESS_KEY=$(kubectl get secret "$OBC_NAME" -n "$NS" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(kubectl get secret "$OBC_NAME" -n "$NS" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

# Use explicit S3_ENDPOINT if set, otherwise derive from OBC ConfigMap (internal service).
# The internal service is port 443/HTTPS — using the external route is simpler for demos.
if [[ -n "${S3_ENDPOINT:-}" ]]; then
  ENDPOINT="$S3_ENDPOINT"
else
  BUCKET_HOST=$(kubectl get configmap "$OBC_NAME" -n "$NS" -o jsonpath='{.data.BUCKET_HOST}')
  BUCKET_PORT=$(kubectl get configmap "$OBC_NAME" -n "$NS" -o jsonpath='{.data.BUCKET_PORT}')
  ENDPOINT="https://${BUCKET_HOST}:${BUCKET_PORT}"
fi

echo "  Bucket   : $BUCKET_NAME"
echo "  Endpoint : $ENDPOINT"

kubectl create secret generic walg-config \
  --from-literal=WALG_S3_PREFIX="s3://${BUCKET_NAME}/postgres/wal" \
  --from-literal=AWS_ENDPOINT="${ENDPOINT}" \
  --from-literal=AWS_REGION="us-east-1" \
  --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
  --from-literal=AWS_S3_FORCE_PATH_STYLE="true" \
  -n "$NS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "walg-config secret created in namespace $NS"
