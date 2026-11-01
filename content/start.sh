#!/bin/sh
# Start Wallabag, replacing the upstream's built-in admin account.
#
# The official image provisions itself: with the default SQLite driver it runs
# `wallabag:install --env=prod -n` when the database file is missing, and that
# non-interactive install creates a `wallabag`/`wallabag` super-admin. That
# account must never survive into a shipped deployment.
#
# This wrapper performs the same provisioning steps in the same order, then
# creates the operator's own account from the deployment parameters, retires
# the built-in one, and finally starts the services the image would have
# started.
#
# It performs no network probing and does not gate startup on health.
set -eu

ADMIN_USER="${WALLABAG_ADMIN_USER:-}"
ADMIN_MAIL="${WALLABAG_ADMIN_MAIL:-}"
ADMIN_PASS="${WALLABAG_ADMIN_PASS:-}"

fail() {
    echo "[wallabag] refusing to start: $1" >&2
    exit 1
}

[ -n "$ADMIN_USER" ] || fail "WALLABAG_ADMIN_USER must be set"
[ -n "$ADMIN_MAIL" ] || fail "WALLABAG_ADMIN_MAIL must be set"
[ -n "$ADMIN_PASS" ] || fail "WALLABAG_ADMIN_PASS must be set"

case "$ADMIN_USER" in
    *[!A-Za-z0-9_.@-]*) fail "WALLABAG_ADMIN_USER may only contain letters, digits and _ . @ -" ;;
esac
case "$ADMIN_MAIL" in
    *@*.*) ;;
    *) fail "WALLABAG_ADMIN_MAIL must look like an email address" ;;
esac
[ "${#ADMIN_PASS}" -ge 12 ] || fail "WALLABAG_ADMIN_PASS must be at least 12 characters"

cd /var/www/wallabag

SQLITE_DB_DIR=/var/www/wallabag/data/db
SQLITE_DB_FILEPATH="$SQLITE_DB_DIR/wallabag.sqlite"

# Same substitutions the image entrypoint performs.
envsubst < /etc/wallabag/parameters.template.yml > app/config/parameters.yml
envsubst < /etc/wallabag/php-wallabag.template.ini > /etc/php82/conf.d/50_wallabag.ini

if [ ! -f "$SQLITE_DB_FILEPATH" ]; then
    mkdir -p "$SQLITE_DB_DIR"
    chown nobody: "$SQLITE_DB_DIR"
fi

if [ ! -s "$SQLITE_DB_FILEPATH" ]; then
    echo "[wallabag] provisioning the SQLite database ..."
    su -c "php bin/console wallabag:install --env=prod -n" -s /bin/sh nobody \
        || fail "database provisioning failed"
fi

# Create the operator account. fos:user:create fails when the user exists, in
# which case the credential is rotated instead.
if su -c "php bin/console fos:user:create '$ADMIN_USER' '$ADMIN_MAIL' '$ADMIN_PASS' --super-admin --env=prod" -s /bin/sh nobody 2>/dev/null; then
    echo "[wallabag] administrator account created."
else
    echo "[wallabag] administrator exists, rotating its credential."
    su -c "php bin/console fos:user:change-password '$ADMIN_USER' --password='$ADMIN_PASS' --env=prod" -s /bin/sh nobody \
        || fail "could not set the administrator credential"
fi

# Retire the built-in account left behind by the non-interactive install.
su -c "php bin/console fos:user:deactivate wallabag --env=prod" -s /bin/sh nobody 2>/dev/null || true

# Clear the cache as the image would, then start the services it supervises.
rm -f -r /var/www/wallabag/var/cache
echo "[wallabag] starting services ..."
exec s6-svscan /etc/s6/
