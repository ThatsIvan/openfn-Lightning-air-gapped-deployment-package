#!/usr/bin/env bash
# 05-verify.sh — Definitive yes or no verification of the deployment of all services
# Checks: containers healthy, /health_check 200, worker connected, and runs a canary workflow
# end-to-end
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${BUNDLE_DIR}"

PASS=true
fail() { echo "  FAIL: $1"; PASS=false; }
ok()   { echo "  OK:   $1"; }

echo "=== Deployment verification ==="
echo ""


# 1. Container health
echo "--- 1. Container health ---"
for SVC in postgres web worker; do
  STATUS="$(docker compose ps "${SVC}" --format '{{.State}}' 2>/dev/null || true)"
  HEALTH="$(docker compose ps "${SVC}" --format '{{.Health}}' 2>/dev/null || true)"
  if [ "${STATUS}" = "running" ]; then
    if [ "${SVC}" = "worker" ]; then
      # worker has no healthcheck; check it's running
      ok "${SVC} is running"
    elif [ "${HEALTH}" = "healthy" ]; then
      ok "${SVC} is healthy"
    else
      fail "${SVC} is running but not healthy (health: ${HEALTH})"
    fi
  else
    fail "${SVC} is not running (state: ${STATUS})"
  fi
done

# migrate should have completed
MIGRATE_STATUS="$(docker compose ps -a migrate --format '{{.State}}' 2>/dev/null || true)"
if [ "${MIGRATE_STATUS}" = "exited" ]; then
  MIGRATE_EXIT="$(docker compose ps -a migrate --format '{{.ExitCode}}' 2>/dev/null || true)"
  if [ "${MIGRATE_EXIT}" = "0" ]; then
    ok "migrate completed (exit 0)"
  else
    fail "migrate exited with code ${MIGRATE_EXIT}"
  fi
else
  fail "migrate in unexpected state: ${MIGRATE_STATUS}"
fi

echo ""

# 2. Health endpoint
echo "--- 2. Health endpoint ---"
HTTP_CODE="$(curl -sf -o /dev/null -w '%{http_code}' http://localhost:${LIGHTNING_PORT:-4000}/health_check 2>/dev/null || echo "000")"
if [ "${HTTP_CODE}" = "200" ]; then
  ok "/health_check returned 200"
else
  fail "/health_check returned ${HTTP_CODE}"
fi

echo ""


# 3. Worker connected
echo "--- 3. Worker connection ---"
# Check recent worker logs for connection confirmation
if docker compose logs worker --tail=100 2>/dev/null | grep -qi "listening on\|Starting workloop\|connected"; then
  ok "Worker is connected and listening"
else
  if docker compose logs worker --tail=100 2>/dev/null | grep -qi "Starting worker\|claim"; then
    ok "Worker is running and attempting to claim work"
  else
    fail "Worker logs do not show successful connection"
    echo "       Check: docker compose logs worker --tail=100"
  fi
fi

echo ""


# 4. Canary workflow (webhook --> job --> success)
echo "--- 4. Canary workflow ---"
echo "  Creating canary workflow via Lightning rpc..."

# Create a project, webhook workflow, and trigger a run using pre-staged adaptors
# Use rpc (not eval) to run against the live BEAM node which has Repo started

CANARY_RESULT="$(docker compose exec -T web /app/bin/lightning rpc '
  alias Lightning.{Accounts, Projects, Workflows, Jobs}

  # Find the first superuser
  import Ecto.Query
  user = Lightning.Repo.one!(from u in Accounts.User, where: u.role == :superuser, limit: 1)

  # Create a canary project
  {:ok, project} = Projects.create_project(%{
    name: "canary-verification",
    project_users: [%{user_id: user.id, role: :owner}]
  }, false)

  # Create a workflow with a webhook trigger
  {:ok, workflow} = Workflows.save_workflow(%{
    name: "Canary",
    project_id: project.id
  }, user)

  {:ok, trigger} = Workflows.build_trigger(%{
    type: :webhook,
    workflow_id: workflow.id,
    enabled: true
  })

  {:ok, job} = Jobs.create_job(%{
    name: "canary-job",
    body: "fn(state => { console.log(\"canary: adaptors work offline\"); return state; })",
    adaptor: "@openfn/language-common@latest",
    workflow_id: workflow.id
  }, user)

  {:ok, _edge} = Workflows.create_edge(%{
    workflow_id: workflow.id,
    condition_type: :always,
    source_trigger: trigger,
    target_job: job,
    enabled: true
  }, user)

  # Ensure trigger is enabled
  trigger = Lightning.Repo.reload!(trigger)
  unless trigger.enabled do
    {:ok, trigger} = trigger |> Ecto.Changeset.change(%{enabled: true}) |> Lightning.Repo.update()
  end

  webhook_url = "/i/#{trigger.id}"
  IO.puts("WEBHOOK:#{webhook_url}")
' 2>/dev/null || echo "EVAL_FAILED")"

if echo "${CANARY_RESULT}" | grep -q "EVAL_FAILED"; then
  fail "Could not create canary workflow"
  echo "       This may mean no admin user exists. Run 04-create-admin.sh first."
else
  WEBHOOK_PATH="$(echo "${CANARY_RESULT}" | grep 'WEBHOOK:' | cut -d: -f2)"
  if [ -n "${WEBHOOK_PATH}" ]; then
    echo "  Triggering canary via webhook: ${WEBHOOK_PATH}"
    TRIGGER_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H 'Content-Type: application/json' \
      -d '{"canary": true, "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' \
      "http://localhost:${LIGHTNING_PORT:-4000}${WEBHOOK_PATH}" 2>/dev/null || echo "000")"

    if [ "${TRIGGER_CODE}" = "200" ] || [ "${TRIGGER_CODE}" = "204" ] || [ "${TRIGGER_CODE}" = "202" ]; then
      ok "Webhook accepted (HTTP ${TRIGGER_CODE})"

      # Wait for the run to complete
      echo "  Waiting for canary run to complete (up to 60s)..."
      WAITED=0
      CANARY_PASSED=false
      while [ $WAITED -lt 60 ]; do
        sleep 5
        WAITED=$((WAITED + 5))
        # Check worker logs for job completion (console.log output goes to
        # Lightning's run log, not Docker stdout — so look for the completion marker)
        if docker compose logs worker --tail=50 2>/dev/null | grep -q "canary-job completed"; then
          CANARY_PASSED=true
          break
        fi
      done

      if [ "${CANARY_PASSED}" = true ]; then
        ok "Canary run completed — adaptor executed offline successfully"
      else
        # Check if there was an autoinstall failure (adaptor not pre-staged)
        if docker compose logs worker --tail=50 2>/dev/null | grep -q "autoinstalling\|module not found"; then
          fail "Canary run failed — adaptor not pre-staged correctly"
          echo "       Check: docker compose logs worker --tail=50"
        else
          fail "Canary run did not complete within 60s"
          echo "       Check: docker compose logs worker --tail=50"
        fi
      fi
    else
      fail "Webhook returned HTTP ${TRIGGER_CODE}"
    fi
  else
    fail "Could not extract webhook URL from canary setup"
  fi
fi

echo ""


# Summary
echo "==========================================="
if [ "${PASS}" = true ]; then
  echo " PASS — deployment verified"
  echo ""
  echo " OpenFn Lightning is running and healthy."
  echo " The canary workflow confirms offline adaptor execution."
else
  echo " FAIL — see errors above"
  echo ""
  echo " Review the failing checks and their suggested commands."
  echo " Common issues:"
  echo "   - Secrets mismatch: regenerate with 02-generate-secrets.sh"
  echo "   - Worker not connecting: check WORKER_SECRET and keys"
  echo "   - Adaptor not found: only pre-staged adaptors work offline"
fi
echo "==========================================="

[ "${PASS}" = true ]
