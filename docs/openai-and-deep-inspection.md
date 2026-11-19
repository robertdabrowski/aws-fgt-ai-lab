# OpenAI and FortiGate Deep Inspection

Complete the [mock test](../README.md#3-verify-ssm-and-run-the-mock-test) first. Run the application in OpenAI mode with TLS decryption disabled to establish a baseline.

| Flow | FortiGate policies | Traffic |
|---|---|---|
| Agent A → Agent B | 701 | Agent Card and A2A message over TCP/8081 |
| Agent B → MCP server | 702 | MCP initialize, tools/list, and tools/call over TCP/8082 |
| Agents → OpenAI | 703 and 704 | `POST /v1/responses` over TCP/443 |
| Workloads → AWS SSM | 703, 704, and 707 | Systems Manager and its messaging endpoints over TCP/443 |

## Run the agents with OpenAI

Use a dedicated OpenAI API project key and a model that the project can use with the Responses API and function calling. Use the same model in both sessions. The examples propose `gpt-5-mini`. Select another supported model if your project requires it.

**CloudShell, Agent B window**

```bash
agent_b_id="$(terraform output -json workload_instance_ids | jq -er '."agent-b"')" &&
aws ssm start-session --region eu-central-1 --target "$agent_b_id"
```

**Inside the Agent B SSM session.** Confirm `ip -4 -br addr` shows `10.77.20.10`, then run:

```bash
bash -c '
  read -rsp "OpenAI API key: " OPENAI_API_KEY
  printf "\n"
  [ -n "$OPENAI_API_KEY" ] || exit 1
  read -rp "OpenAI model [gpt-5-mini]: " OPENAI_MODEL
  OPENAI_MODEL="${OPENAI_MODEL:-gpt-5-mini}"
  export OPENAI_API_KEY OPENAI_MODEL

  sudo systemctl stop fgt-ai-agent-b.service || exit 1
  trap "sudo systemctl start fgt-ai-agent-b.service" EXIT
  /usr/bin/python3 -u /opt/fgt-ai-lab/lab.py agent-b \
    --bind 10.77.20.10 \
    --public-url http://10.77.20.10:8081 \
    --mcp-url http://10.77.30.10:8082/mcp \
    --mode openai
'
```

Leave B running after it reports that it is listening on `10.77.20.10:8081`.

**CloudShell, Agent A window**

```bash
agent_a_id="$(terraform output -json workload_instance_ids | jq -er '."agent-a"')" &&
aws ssm start-session --region eu-central-1 --target "$agent_a_id"
```

**Inside the Agent A SSM session.** Confirm `ip -4 -br addr` shows `10.77.10.10`, then run:

```bash
bash -c '
  read -rsp "OpenAI API key: " OPENAI_API_KEY
  printf "\n"
  [ -n "$OPENAI_API_KEY" ] || exit 1
  read -rp "OpenAI model [gpt-5-mini]: " OPENAI_MODEL
  OPENAI_MODEL="${OPENAI_MODEL:-gpt-5-mini}"
  export OPENAI_API_KEY OPENAI_MODEL

  /usr/bin/python3 -u /opt/fgt-ai-lab/lab.py agent-a \
    --agent-url http://10.77.20.10:8081 \
    --mode openai
'
```

Agent B sends a Responses API request, calls the MCP tool, and sends a second Responses API request with its result. Agent A sends a third request and prints an `Agent A [openai]:` summary of the synthetic incident `LAB-1042`. If Agent A reports HTTP 502, check Agent B's terminal.

Stop B with `Ctrl+C` to start the mock service again. After an interrupted session, verify from a new session on B:

```bash
systemctl is-active fgt-ai-agent-b.service ||
  sudo systemctl start fgt-ai-agent-b.service
```

## Application Control and TLS decryption

1. In the FortiGate GUI, attach an **Application Control** profile to policies 701–704. Start with relevant signatures set to **Monitor**. For TCP/443, start with certificate inspection if you want metadata visibility before testing payload inspection. Available detections depend on the active signatures and entitlements.
2. For the Deep Inspection test, clone the **deep-inspection** SSL/SSH profile. In its SSL exemptions, add a **wildcard FQDN** address object for `*.amazonaws.com`. Match it against the TLS server name to keep AWS TLS traffic such as SSM outside decryption on policy 704. This is a TLS inspection exemption, while the forwarding policy still uses `dstaddr "all"`. Ensure `api.openai.com` is outside the exemptions.
3. Export the **public CA certificate** selected in the SSL/SSH profile from the current FortiGate. On your workstation, convert it to PEM if needed:

```bash
openssl x509 -in Fortinet_CA_SSL.cer -out fortigate-lab-ca.pem 2>/dev/null ||
  openssl x509 -inform DER -in Fortinet_CA_SSL.cer -out fortigate-lab-ca.pem
```

4. On Agent B, use `cat > "$HOME/fortigate-lab-ca.pem" <<'EOF'`, paste the PEM content, then type `EOF` on its own line. In the same Agent B session, create and export the combined trust bundle.

```bash
openssl x509 -in "$HOME/fortigate-lab-ca.pem" -noout -subject -issuer &&
cat /etc/pki/tls/certs/ca-bundle.crt "$HOME/fortigate-lab-ca.pem" \
  > "$HOME/fgt-lab-ca-bundle.pem" &&
export SSL_CERT_FILE="$HOME/fgt-lab-ca-bundle.pem"
```

5. Attach the custom profile to **704 / LAB-HTTPS-B**. Leave the Agent A and tools profiles at baseline for this comparison. Check that fresh SSM sessions can still open to B. If SSM traffic is intercepted, revert policy 704 to the baseline profile in the FortiGate GUI and verify the exemptions before retrying.
6. From Agent B, verify OpenAI TLS without sending an API key. Keep validation enabled.

```bash
curl -4 --http1.1 --noproxy '*' -sv --connect-timeout 5 --max-time 15 \
  --cacert "$SSL_CERT_FILE" https://api.openai.com/v1/models -o /dev/null
```

The inspected session should show a Fortinet-managed issuer, successful certificate verification, and HTTP 401. A public CA on the OpenAI session indicates that it was not decrypted. Check the matched policy and profile exemptions. Repeat the OpenAI application test in the B shell that exports `SSL_CERT_FILE`. If you open a new SSM session to the same B instance, export the variable again.

Review traffic in **Forward Traffic** and signatures in **Security Events → Application Control**. Deep Inspection makes decrypted request contents available to FortiGate inspection engines. Keep the API key out of diagnostic exports and use only the lab's synthetic data.

## References

- [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses/create)
- [Fortinet guidance on domain exemptions in Deep SSL Inspection](https://community.fortinet.com/fortigate-3/technical-tip-exempting-applications-domains-websites-from-deep-ssl-inspection-93711)
