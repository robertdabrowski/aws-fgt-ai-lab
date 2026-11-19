output "vpc_id" {
  value = aws_vpc.lab.id
}

output "igw_id" {
  value = aws_internet_gateway.lab.id
}

output "subnet_ids" {
  value = { for name, subnet in aws_subnet.lab : name => subnet.id }
}

output "fgt_instance_id" {
  value = aws_instance.fgt.id
}

output "fgt_public_ip" {
  value = aws_eip.fgt.public_ip
}

output "fgt_eni_ids" {
  value = { for name, eni in aws_network_interface.fgt : name => eni.id }
}
