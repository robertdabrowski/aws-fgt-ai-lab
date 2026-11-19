# AWS FortiGate AI Lab

Trace and inspect traffic between two AI agents, a read-only MCP tool server, and the OpenAI Responses API. Terraform builds a single-AZ AWS lab with FortiGate-VM as the inline firewall. The mock test runs without an OpenAI key.

[Instrukcja po polsku](docs/README.pl.md) · [OpenAI and Deep Inspection](docs/openai-and-deep-inspection.md)

## Topology

| Role | Workload IP | FortiGate interface | FortiGate IP |
|---|---|---|---|
| WAN | Elastic IP from Terraform | `port1` | `10.77.1.10` |
| Agent A | `10.77.10.10` | `port2` | `10.77.2.10` |
| Agent B | `10.77.20.10` | `port3` | `10.77.3.10` |
| MCP tools | `10.77.30.10` | `port4` | `10.77.4.10` |

The VPC uses `10.77.0.0/16` in `eu-central-1a`. All three workloads are private EC2 instances. Their default routes and more-specific routes to the other workload subnets target the appropriate FortiGate ENI. The VPC's built-in DNS resolver is used for DNS. The demo application implements the A2A and MCP exchanges used by this scenario.

## Prerequisites

- An AWS account with EC2, VPC and IAM provisioning permissions, including permission to pass the workload role. Your operator also needs Systems Manager Run Command and Session Manager access.
- Terraform 1.10 or newer, AWS CLI v2, Bash, and `jq`. Interactive EC2 access requires the Session Manager plugin on the machine where you run the AWS CLI. The deploy helper uses GNU `base64`, available in AWS CloudShell.
- An existing EC2 key pair in `eu-central-1`, and AWS Marketplace access to the Fortinet BYOL image. Accept its terms if AWS prompts you to do so. The default is FortiOS 8.0.2 build0251 x86_64. The FortiGate EC2 instance is a `c6i.xlarge` with two active vCPUs and 8 GiB of RAM. Choose a FortiGate-VM entitlement compatible with this configuration.
- A FortiFlex token or another compatible FortiGate-VM BYOL license. OpenAI is optional and requires a project API key and a model that supports Responses API function calling.

This is an isolated test lab. AWS charges apply while resources run. The WAN policies allow TCP/443 to any routed destination through `port1` for each of the three workload IPs.

## 1. Provision AWS

Run from the repository root in AWS CloudShell. On a local workstation, set up AWS credentials for the CLI and Terraform first.

```bash
aws sts get-caller-identity
aws ec2 describe-images --region eu-central-1 \
  --image-ids ami-0f87c9d117231cd4b \
  --query 'Images[].{AMI:ImageId,Name:Name,State:State}' --output table
cp terraform.tfvars.example terraform.tfvars
```

In `terraform.tfvars`, set `fgt_key_name` and `admin_cidr` to your EC2 key-pair name and the IPv4 range you use to access FortiGate. An individual public IPv4 address uses a `/32`. Admin ingress is separate from the workload egress policies. If the default BYOL AMI is unavailable, set `fgt_ami_id` to a compatible FortiGate-VM BYOL AMI in the same region. By default Terraform looks up the current standard Amazon Linux 2023 x86_64 image. Set `workload_ami_id` to pin a specific compatible image.

### Set up Terraform storage in AWS CloudShell

CloudShell provides 1 GB of persistent home storage per Region. From the repository root, run this block before `terraform init` to install the AWS provider under `/tmp`.

```bash
lab_tf_data_dir="$(mktemp -d /tmp/aws-fgt-ai-lab.XXXXXX)" &&
export TF_DATA_DIR="$lab_tf_data_dir"
```

Use the same `TF_DATA_DIR` for subsequent Terraform commands in this shell. In a new CloudShell session, repeat the storage setup and `terraform init` before running Terraform again. The local state file and saved plans are stored in the repository directory.

If an earlier install failed with `no space left on device` and Terraform now reports a checksum mismatch, reclaim the space used by the incomplete copy from the repository root:

```bash
rm -rf -- .terraform/providers/registry.terraform.io/hashicorp/aws/6.66.0/linux_amd64
```

Keep the committed `.terraform.lock.hcl`. Run initialization and planning:

```bash
terraform init -input=false -lockfile=readonly &&
terraform fmt -check -recursive &&
terraform validate &&
terraform plan -input=false -out=lab.tfplan &&
terraform show -no-color lab.tfplan
```

Review the saved plan. It should create one FortiGate, four FortiGate ENIs, one Elastic IP, three workload instances, and nine workload routes targeting the FortiGate.

```bash
terraform apply lab.tfplan
terraform output
```

### Verify the AWS path

```bash
fgt_id="$(terraform output -raw fgt_instance_id)" &&
aws ec2 describe-network-interfaces --region eu-central-1 \
  --filters "Name=attachment.instance-id,Values=$fgt_id" \
  --query 'sort_by(NetworkInterfaces,&Attachment.DeviceIndex)[].{Index:Attachment.DeviceIndex,IP:PrivateIpAddress,EIP:Association.PublicIp,SourceDestCheck:SourceDestCheck}' \
  --output table --no-cli-pager

vpc_id="$(terraform output -raw vpc_id)" &&
aws ec2 describe-route-tables --region eu-central-1 \
  --filters "Name=vpc-id,Values=$vpc_id" \
    'Name=tag:Name,Values=aws-fgt-ai-lab-rt-agent-a,aws-fgt-ai-lab-rt-agent-b,aws-fgt-ai-lab-rt-tools' \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[?NetworkInterfaceId!=`null`].{CIDR:DestinationCidrBlock,ENI:NetworkInterfaceId,State:State}}' \
  --output json --no-cli-pager
```

Check that indices 0–3 have source/destination checks disabled and that the Elastic IP is associated with index 0. Each workload should have three active ENI routes, one default and two /24s.

## 2. Activate and configure FortiGate

1. Open the GUI using the current `fgt_public_ip`. On the default AWS image, sign in as `admin` using the current `fgt_instance_id` as the initial password. Set your own administrator password in FortiGate.
2. Enter the FortiFlex token under **FortiGate VM License**, or upload the `.lic` file for your compatible BYOL entitlement. For FortiFlex you can also use `execute vm-license <TOKEN>` in the FortiGate CLI. Reconnect after any reboot.
3. Run `get system status` and verify that the license is valid. Run `show system interface` and `get router info routing-table all`. Expect the default route via `10.77.1.1` on `port1` and routes to the three workload /24s via `10.77.2.1`, `10.77.3.1`, and `10.77.4.1` respectively. Terraform supplies interfaces, DNS and routes as first-boot EC2 user data.
4. In VDOM `root`, paste [forward-policies.conf](fortigate/forward-policies.conf) into the FortiGate CLI. Verify that policy IDs 701, 702, 703, 704, and 707 are available on the target VM before importing. Then run `show firewall policy`. Apply the license, password, and policies on FortiGate after each rebuild.

| Policy | Ingress → egress | Flow | Destination | SNAT |
|---|---|---|---|---|
| 701 | `port2 → port3` | A2A TCP/8081 | Agent B /32 | Off |
| 702 | `port3 → port4` | MCP TCP/8082 | MCP tools /32 | Off |
| 703 | `port2 → port1` | HTTPS TCP/443 | `all` | On |
| 704 | `port3 → port1` | HTTPS TCP/443 | `all` | On |
| 707 | `port4 → port1` | HTTPS TCP/443 | `all` | On |

If the interface or route bootstrap did not apply, check `diagnose debug cloudinit show` on FortiGate. To retrieve the expected networking CLI from EC2, run the following from the project root. Inspect it and apply the needed commands to the FortiGate CLI.

```bash
fgt_id="$(terraform output -raw fgt_instance_id)" &&
aws ec2 describe-instance-attribute --region eu-central-1 \
  --instance-id "$fgt_id" --attribute userData \
  --query 'UserData.Value' --output text --no-cli-pager | base64 -d
```

Each rule matches a specific source /32 and logs traffic. SSM and OpenAI share the same HTTPS policy for each applicable source. There are no FQDN address objects in the forwarding policy set. If you imported an older script into this same VM, remove or disable its overlapping egress rules and check the order. This bundle targets a fresh FortiGate and will edit rules with matching IDs.

## 3. Verify SSM and run the mock test

```bash
lab_ids="$(terraform output -json workload_instance_ids | jq -er '[.[]] | join(",")')" &&
aws ssm describe-instance-information --region eu-central-1 \
  --filters "Key=InstanceIds,Values=$lab_ids" \
  --query 'sort_by(InstanceInformationList,&IPAddress)[].{IP:IPAddress,Instance:InstanceId,Status:PingStatus}' \
  --output table --no-cli-pager
```

Wait for all three instances to report `Online`. Then deploy the Python app through Run Command. This starts Agent B and the MCP tool server as systemd services. Agent A runs once per test.

```bash
bash app/stage8b.sh deploy
bash app/stage8b.sh test
```

Expected output includes:

```text
Agent B: payments-demo: degraded, INC LAB-1042.
Agent A [mock]: payments-demo: degraded, INC LAB-1042.
```

To see both east-west paths, start the following in the FortiGate CLI before rerunning the test in CloudShell. Use `Ctrl+C` to stop the capture.

```text
diagnose sniffer packet any 'tcp and (port 8081 or port 8082)' 4 0 l
```

A2A enters on `port2` and exits on `port3`. MCP enters on `port3` and exits on `port4`. Look for policies 701 and 702 in Forward Traffic. Both flows use cleartext HTTP in the private lab.

If a Run Command invocation is delayed or fails, use the command ID printed by the helper:

```bash
aws ssm list-command-invocations --region eu-central-1 \
  --command-id COMMAND_ID --details \
  --query 'CommandInvocations[].{Instance:InstanceId,Status:Status,Details:StatusDetails}' \
  --output table --no-cli-pager
```

Verify the license, policies 703/704/707, and the associated workload routes. If an instance is `Online` while commands remain pending, check outbound HTTPS sessions from that instance in Forward Traffic. For example, on FortiGate run `diagnose sniffer packet any 'host 10.77.20.10 and tcp port 443' 4 0 l` for Agent B.

## 4. Test the OpenAI and inspection paths

Follow [OpenAI and Deep Inspection](docs/openai-and-deep-inspection.md) to run Agent A and Agent B with an OpenAI project key, enable Application Control monitoring, and optionally inspect Agent B's TLS connections.

## 5. Tear down

Run from the directory used to deploy the lab, review the destroy plan, and apply it.

```bash
terraform plan -destroy -out=destroy.tfplan
terraform show -no-color destroy.tfplan
terraform apply destroy.tfplan
```

## References

- [FortiOS 8.0 AWS administration guide](https://fortinetweb.s3.amazonaws.com/docs.fortinet.com/v2/attachments/1486def3-3a85-11f1-b31d-02356ffb40d9/FortiOS_8.0_AWS_Administration_Guide.pdf)
- [FortiGate-VM licensing](https://docs.fortinet.com/document/fortigate/8.0.0/administration-guide/416169/vm-license)
- [AWS Systems Manager connectivity troubleshooting](https://docs.aws.amazon.com/systems-manager/latest/userguide/troubleshooting-ssm-agent.html)
- [AWS Systems Manager Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
