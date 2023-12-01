#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_OWNER=$(jq -r .event.base.repo.owner /github/workflow/event.json)
REPO_NAME=$(jq -r .event.base.repo.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
config="${$INPUT_CONFIG:-fly.toml}"
build_arg="$INPUT_BUILD_ARG"
vm_size="${INPUT_VM_SIZE:-${FLY_VM_SIZE:-shared-cpu-1x}}"
vm_memory="${INPUT_VM_MEMORY:-${FLY_VM_MEMORY:-256}}"
wait_timeout="${INPUT_WAIT_TIMEOUT:-120}"
internal_port="${INPUT_INTERNAL_PORT:-8080}"


if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true

  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl postgres detach --app "$app" "$INPUT_POSTGRES" || true
  fi

  exit 0
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Do not copy config if it was passed
  if [ -n "$INPUT_CONFIG" ]; then
    mv "$INPUT_CONFIG" fly.toml
  fi

  flyctl launch --no-deploy --copy-config --dockerignore-from-gitignore --name "$app" --region "$region" --org "$org" --vm-size "$vm_size" --vm-memory "$vm_memory" --internal-port "$internal_port"

  if [ -n "$INPUT_SECRETS" ]; then
    echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
  fi

  # Attach postgres cluster to the app if specified.
  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl postgres attach --app "$app" "$INPUT_POSTGRES" || true
  fi

  # Assign a public IPv4 address to the app.
  flyctl ips allocate-v4 --shared --app "$app"
  flyctl ips allocate-v6 --app "$app"

  flyctl deploy --config "fly.toml"
elif [ "$INPUT_UPDATE" != "false" ]; then
  flyctl deploy --config "fly.toml"
fi

# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)

echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
