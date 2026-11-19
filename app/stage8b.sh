#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  deploy|test) mode="$1" ;;
  *) printf 'Usage: bash stage8b.sh deploy|test\n' >&2; exit 2 ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
ids="$(terraform output -json workload_instance_ids)"
agent_a="$(jq -er '."agent-a"' <<< "$ids")"
agent_b="$(jq -er '."agent-b"' <<< "$ids")"
tools="$(jq -er '.tools' <<< "$ids")"

for instance in "$agent_a" "$agent_b" "$tools"; do
  if [[ ! "$instance" =~ ^i-[0-9a-f]{17}$ ]]; then
    printf 'Invalid EC2 instance ID: %s\n' "$instance" >&2
    exit 2
  fi
done
if [[ "$agent_a" == "$agent_b" || "$agent_a" == "$tools" || "$agent_b" == "$tools" ]]; then
  printf 'Expected three distinct EC2 instances.\n' >&2
  exit 2
fi

ssm() {
  aws ssm "$@" --region eu-central-1 --no-cli-pager
}

send() {
  local payload="$1"
  shift
  ssm send-command --document-name AWS-RunShellScript \
    --instance-ids "$@" --parameters "$payload" \
    --query 'Command.CommandId' --output text
}

wait_for_result() {
  local cmd_id="$1"
  local instance="$2"
  local deadline=$((SECONDS + 300))
  local invocation=null status
  printf 'SSM %s on %s\n' "$cmd_id" "$instance"
  while (( SECONDS < deadline )); do
    invocation="$(ssm list-command-invocations --command-id "$cmd_id" \
      --instance-id "$instance" --query 'CommandInvocations[0]' --output json)"
    status="$(jq -r '.Status // "Pending"' <<< "$invocation")"
    case "$status" in
      Pending|InProgress|Delayed|Cancelling) sleep 4 ;;
      *)
        ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance" \
          --query '{Status:Status,Details:StatusDetails,Output:StandardOutputContent,Error:StandardErrorContent}' \
          --output json | jq -r '.Status, .Details, .Output, .Error'
        [[ "$status" == Success ]]
        return
        ;;
    esac
  done
  printf 'SSM command %s on %s still %s after 300 seconds. Check list-command-invocations before retrying.\n' \
    "$cmd_id" "$instance" "$(jq -r '.StatusDetails // "pending registration"' <<< "$invocation")" >&2
  return 1
}

configure_service() {
  local instance="$1"
  local service="$2"
  local address="$3"
  local port="$4"
  local launch_args="$5"
  local unit payload cmd_id
  unit="$(cat <<UNIT
[Unit]
Description=FortiGate AI lab $service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/python3 -u /opt/fgt-ai-lab/lab.py $launch_args
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
)"
  payload="$(jq -nc --arg unit "$unit" --arg service "$service" --arg address "$address" --arg port "$port" '
    {commands: [
      "set -eu",
      ("cat > /etc/systemd/system/" + $service + ".service <<\u0027UNIT\u0027\n" + $unit + "\nUNIT"),
      "systemctl daemon-reload",
      ("systemctl enable " + $service),
      ("systemctl restart " + $service),
      ("for attempt in $(seq 1 15); do if /usr/bin/python3 -c \u0027import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 1).close()\u0027 " + $address + " " + $port + " 2>/dev/null; then exit 0; fi; sleep 1; done"),
      ("journalctl -u " + $service + " -n 30 --no-pager >&2"),
      "exit 1"
    ]}')"
  cmd_id="$(send "$payload" "$instance")"
  wait_for_result "$cmd_id" "$instance"
}

if [[ "$mode" == deploy ]]; then
  encoded="$(base64 -w0 "$script_dir/lab.py")"
  payload="$(jq -nc --arg encoded "$encoded" '
    {commands: [
      "set -eu",
      "install -d -m 0755 /opt/fgt-ai-lab",
      "umask 022",
      "stage_file=$(mktemp /opt/fgt-ai-lab/lab.py.XXXXXX)",
      ("printf %s \u0027" + $encoded + "\u0027 | base64 -d > \"$stage_file\""),
      "chmod 0644 \"$stage_file\"",
      "/usr/bin/python3 \"$stage_file\" --help >/dev/null",
      "mv -f \"$stage_file\" /opt/fgt-ai-lab/lab.py"
    ]}')"
  cmd_id="$(send "$payload" "$agent_a" "$agent_b" "$tools")"
  for instance in "$agent_a" "$agent_b" "$tools"; do
    wait_for_result "$cmd_id" "$instance"
  done

  configure_service "$tools" fgt-ai-tools 10.77.30.10 8082 \
    "tools --bind 10.77.30.10"
  configure_service "$agent_b" fgt-ai-agent-b 10.77.20.10 8081 \
    "agent-b --bind 10.77.20.10 --public-url http://10.77.20.10:8081 --mcp-url http://10.77.30.10:8082/mcp --mode mock"
else
  payload="$(jq -nc '{commands: [
    "set -eu",
    "/usr/bin/python3 -u /opt/fgt-ai-lab/lab.py agent-a --agent-url http://10.77.20.10:8081 --mode mock"
  ]}')"
  cmd_id="$(send "$payload" "$agent_a")"
  wait_for_result "$cmd_id" "$agent_a"
fi
