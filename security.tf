resource "aws_security_group" "lab" {
  for_each = local.subnet_cidrs

  vpc_id = aws_vpc.lab.id
  name   = "aws-fgt-ai-lab-${each.key}"
  tags   = { Name = "aws-fgt-ai-lab-${each.key}" }
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each = { ssh = 22, https = 443 }

  security_group_id = aws_security_group.lab["wan"].id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_ingress_rule" "inspection" {
  for_each = local.workload_ips

  security_group_id = aws_security_group.lab[local.workload_ports[each.key]].id
  ip_protocol       = "-1"
  cidr_ipv4         = "${each.value}/32"
}

resource "aws_vpc_security_group_egress_rule" "fortigate" {
  for_each = local.fgt_ports

  security_group_id = aws_security_group.lab[each.key].id
  ip_protocol       = "-1"
  cidr_ipv4         = each.key == "wan" ? "0.0.0.0/0" : aws_vpc.lab.cidr_block
}

locals {
  app_flows = {
    a2a = { from = "agent-a", to = "agent-b", port = 8081 }
    mcp = { from = "agent-b", to = "tools", port = 8082 }
  }
}

# Routed traffic retains the original workload source IP.
resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each = local.app_flows

  security_group_id = aws_security_group.lab[each.value.to].id
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${local.workload_ips[each.value.from]}/32"
}

resource "aws_vpc_security_group_egress_rule" "app" {
  for_each = local.app_flows

  security_group_id = aws_security_group.lab[each.value.from].id
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${local.workload_ips[each.value.to]}/32"
}

resource "aws_vpc_security_group_egress_rule" "workload_https" {
  for_each = local.workload_ips

  security_group_id = aws_security_group.lab[each.key].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
