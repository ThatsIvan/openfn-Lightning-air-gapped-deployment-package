#!/usr/bin/env bash
# 04-create-admin.sh : create the first superuser (full admin) account
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Create admin user ==="
echo ""

cd "${BUNDLE_DIR}"

# Check web is running
if ! docker compose ps web --format '{{.Health}}' 2>/dev/null | grep -q healthy; then
  echo "FAIL: web service is not healthy. Run 03-start.sh first."
  exit 1
fi

# Prompt for credentials
read -rp "Admin email: " ADMIN_EMAIL
if [ -z "${ADMIN_EMAIL}" ]; then
  echo "FAIL: email cannot be empty."
  exit 1
fi

while true; do
  read -rsp "Admin password (min 10 chars): " ADMIN_PASSWORD
  echo ""
  if [ ${#ADMIN_PASSWORD} -lt 10 ]; then
    echo "Password must be at least 10 characters. Try again."
    continue
  fi
  read -rsp "Confirm password: " ADMIN_PASSWORD_CONFIRM
  echo ""
  if [ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]; then
    echo "Passwords do not match. Try again."
    continue
  fi
  break
done

echo ""
echo "Creating superuser..."

# setup_user pops :role from the map; if role == :superuser,
# it calls Accounts.register_superuser which uses
# superuser_registration_changeset → put_change(:role, :superuser).
# Use rpc (not eval) to run against the live BEAM node which has Repo started.
# Inline credentials since rpc can't see env vars passed via docker exec -e.
docker compose exec -T web /app/bin/lightning rpc "
    result = Lightning.Setup.setup_user(%{
      role: :superuser,
      email: \"${ADMIN_EMAIL}\",
      first_name: \"Admin\",
      last_name: \"User\",
      password: \"${ADMIN_PASSWORD}\"
    })
    case result do
      {:ok, _, _} ->
        IO.puts(\"SUCCESS: Superuser created.\")
      {:ok, :ok} ->
        IO.puts(\"SUCCESS: Superuser created.\")
      {:error, reason} ->
        IO.puts(\"FAIL: #{inspect(reason)}\")
      other ->
        IO.puts(\"Unexpected result: #{inspect(other)}\")
    end
  "

echo ""
echo "==========================="
echo " Admin user created"
echo "==========================="
echo ""
echo "Log in at: http://$(grep URL_HOST .env 2>/dev/null | cut -d= -f2 || echo 'localhost'):$(grep LIGHTNING_PORT .env 2>/dev/null | cut -d= -f2 || echo '4000')"
