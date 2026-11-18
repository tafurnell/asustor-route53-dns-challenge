#!/bin/sh
# Certbot deploy hook: installs a newly issued or renewed certificate as ADM's active web certificate
# and restarts ADM's web server. Certbot runs this automatically, setting RENEWED_LINEAGE to the
# cert's live folder, e.g. /volume1/system/letsencrypt/etc/live/nas.mydomain.com
#
# To run it by hand (e.g. after first issuing the cert):
#   RENEWED_LINEAGE=/volume1/system/letsencrypt/etc/live/nas.mydomain.com ./adm-deploy.sh
set -e

SOURCE="${RENEWED_LINEAGE:?Set RENEWED_LINEAGE or run this via certbot --deploy-hook}"
CERTDIR=/usr/builtin/etc/certificate          # ADM 4.x/5.x active certificate folder
BACKUP="$CERTDIR/ssl_before_letsencrypt"

for f in privkey.pem fullchain.pem; do
  [ -f "$SOURCE/$f" ] || { echo "ERROR: $SOURCE/$f not found" >&2; exit 1; }
done
[ -d "$CERTDIR" ] || { echo "ERROR: ADM certificate folder $CERTDIR not found" >&2; exit 1; }

# One-time backup of whatever ADM was using before, so it can be restored.
if [ ! -d "$BACKUP" ]; then
  mkdir -p "$BACKUP"
  cp -p "$CERTDIR"/ssl.* "$CERTDIR"/certificate.json "$BACKUP"/ 2>/dev/null || true
fi

# Write each file next to the old one, keeping the old one's owner/permissions, then swap it in.
install_file() { # $1 = target name, remaining args = source files to concatenate
  target="$CERTDIR/$1"; shift
  [ -f "$target" ] && cp -p "$target" "$target.new"
  cat "$@" > "$target.new"
  mv -f "$target.new" "$target"
}
install_file ssl.key "$SOURCE/privkey.pem"
install_file ssl.crt "$SOURCE/fullchain.pem"
install_file ssl.pem "$SOURCE/privkey.pem" "$SOURCE/fullchain.pem"

# Tell ADM to use the custom certificate rather than its built-in default one.
if [ -f "$CERTDIR/certificate.json" ]; then
  sed -i 's/"default"[[:space:]]*:[[:space:]]*true/"default": false/' "$CERTDIR/certificate.json"
fi

# Restart ADM's web server.
for s in /etc/init.d/S*lighttpd; do
  [ -x "$s" ] && "$s" restart
done

echo "Installed certificate from $SOURCE into $CERTDIR"
