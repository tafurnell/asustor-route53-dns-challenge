#!/bin/sh
# Wrapper around the venv's certbot. Always run certbot through this script (by hand and from cron)
# so it uses this folder's AWS credentials and keeps its config, work and log files here.
#
#   ./certbot.sh certonly --dns-route53 -d nas.mydomain.com ...
#   ./certbot.sh renew
#   ./certbot.sh certificates

BASE="$(cd "$(dirname "$0")" && pwd)"

# certbot-dns-route53 uses boto3, which reads credentials from this file.
export AWS_SHARED_CREDENTIALS_FILE="$BASE/aws-credentials"
export AWS_PROFILE="${AWS_PROFILE:-default}"

exec "$BASE/venv/bin/certbot" \
  --config-dir "$BASE/etc" \
  --work-dir   "$BASE/work" \
  --logs-dir   "$BASE/logs" \
  "$@"
