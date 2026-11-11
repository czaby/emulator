#!/bin/sh
# Wait until AWS Emulator's health route returns HTTP 200 / "ok".
# See https://docs.aws.amazon.com/emulator/latest/userguide/point-sdk-to-emulator.html
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-https://127.0.0.1:9297}"
CA_BUNDLE="${AWS_CA_BUNDLE:-}"
# In GitLab CI the certificate is issued for 127.0.0.1, so hostname
# verification cannot succeed against the service alias. -k is used only
# when no CA bundle is given (or INSECURE=1).
INSECURE="${INSECURE:-0}"
RETRIES="${RETRIES:-60}"

URL="${ENDPOINT}/__admin/health"

i=0
while [ "$i" -lt "$RETRIES" ]; do
  if [ -n "$CA_BUNDLE" ] && [ "$INSECURE" != "1" ]; then
    if curl -sf --cacert "$CA_BUNDLE" "$URL" | grep -qx ok; then
      echo "emulator is ready at ${ENDPOINT}"
      exit 0
    fi
  else
    if curl -skf "$URL" | grep -qx ok; then
      echo "emulator is ready at ${ENDPOINT}"
      exit 0
    fi
  fi
  i=$((i + 1))
  sleep 1
done

echo "timed out waiting for ${URL}" >&2
exit 1
