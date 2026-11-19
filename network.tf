locals {
  subnet_cidrs = {
    wan              = "10.77.1.0/24"
    inspection       = "10.77.2.0/24"
    inspection-b     = "10.77.3.0/24"
    inspection-tools = "10.77.4.0/24"
    agent-a          = "10.77.10.0/24"
    agent-b          = "10.77.20.0/24"
    tools            = "10.77.30.0/24"
  }

  workload_ports = {
    agent-a = "inspection"
    agent-b = "inspection-b"
    tools   = "inspection-tools"
  }

  workload_ips = {
    for role in keys(local.workload_ports) : role => cidrhost(local.subnet_cidrs[role], 10)
  }

  east_west_routes = {
    for pair in setproduct(keys(local.workload_ports), keys(local.workload_ports)) :
    "${pair[0]}-to-${pair[1]}" => {
      source      = pair[0]
      destination = pair[1]
    } if pair[0] != pair[1]
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.77.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "aws-fgt-ai-lab" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "aws-fgt-ai-lab-igw" }
}

resource "aws_subnet" "lab" {
  for_each = local.subnet_cidrs

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = each.value
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = false

  tags = { Name = "aws-fgt-ai-lab-${each.key}" }
}

resource "aws_route_table" "lab" {
  for_each = local.subnet_cidrs

  vpc_id = aws_vpc.lab.id
  tags   = { Name = "aws-fgt-ai-lab-rt-${each.key}" }
}

resource "aws_route_table_association" "lab" {
  for_each = local.subnet_cidrs

  subnet_id      = aws_subnet.lab[each.key].id
  route_table_id = aws_route_table.lab[each.key].id
}

resource "aws_route" "wan_default" {
  route_table_id         = aws_route_table.lab["wan"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route" "workload_default" {
  for_each = local.workload_ports

  route_table_id         = aws_route_table.lab[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.fgt[each.value].id

  depends_on = [aws_instance.fgt]
}

resource "aws_route" "workload_east_west" {
  for_each = local.east_west_routes

  route_table_id         = aws_route_table.lab[each.value.source].id
  destination_cidr_block = local.subnet_cidrs[each.value.destination]
  network_interface_id   = aws_network_interface.fgt[local.workload_ports[each.value.source]].id

  depends_on = [aws_instance.fgt]
}
