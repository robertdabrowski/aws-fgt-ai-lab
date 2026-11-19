locals {
  fgt_ports = {
    wan              = { index = 0, alias = "WAN" }
    inspection       = { index = 1, alias = "Agent-A" }
    inspection-b     = { index = 2, alias = "Agent-B" }
    inspection-tools = { index = 3, alias = "MCP" }
  }
}

resource "aws_network_interface" "fgt" {
  for_each = local.fgt_ports

  subnet_id         = aws_subnet.lab[each.key].id
  private_ips       = [cidrhost(local.subnet_cidrs[each.key], 10)]
  security_groups   = [aws_security_group.lab[each.key].id]
  source_dest_check = false

  tags = { Name = "aws-fgt-ai-lab-fgt-${each.key}" }
}

resource "aws_eip" "fgt" {
  domain = "vpc"
  tags   = { Name = "aws-fgt-ai-lab-fgt" }
}

resource "aws_eip_association" "fgt" {
  allocation_id        = aws_eip.fgt.id
  network_interface_id = aws_network_interface.fgt["wan"].id

  depends_on = [aws_route.wan_default, aws_route_table_association.lab["wan"]]
}

resource "aws_instance" "fgt" {
  ami           = var.fgt_ami_id
  instance_type = "c6i.xlarge"
  key_name      = var.fgt_key_name

  cpu_options {
    core_count       = 2
    threads_per_core = 1
  }

  user_data_base64 = base64encode(templatefile("${path.module}/templates/fortigate.conf.tftpl", {
    ports          = local.fgt_ports
    subnets        = local.subnet_cidrs
    workload_ports = local.workload_ports
    dns_ip         = cidrhost(aws_vpc.lab.cidr_block, 2)
  }))

  lifecycle {
    # FortiOS consumes this interface and route configuration on first boot.
    ignore_changes = [user_data_base64]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  # Attach all four ENIs at launch so FortiOS can configure ports 1–4 during bootstrap.
  dynamic "network_interface" {
    for_each = local.fgt_ports
    content {
      device_index          = network_interface.value.index
      network_interface_id  = aws_network_interface.fgt[network_interface.key].id
      delete_on_termination = false
    }
  }

  depends_on = [
    aws_eip_association.fgt,
    aws_route_table_association.lab,
    aws_vpc_security_group_ingress_rule.admin,
    aws_vpc_security_group_ingress_rule.inspection,
    aws_vpc_security_group_egress_rule.fortigate,
  ]

  tags = { Name = "aws-fgt-ai-lab-fgt" }
}
