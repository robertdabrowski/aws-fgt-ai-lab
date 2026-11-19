data "aws_ssm_parameter" "al2023" {
  count = var.workload_ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "workload_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workload" {
  name_prefix        = "aws-fgt-ai-lab-"
  assume_role_policy = data.aws_iam_policy_document.workload_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.workload.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload" {
  name_prefix = "aws-fgt-ai-lab-"
  role        = aws_iam_role.workload.name
}

resource "aws_instance" "workload" {
  for_each = local.workload_ips

  ami                         = var.workload_ami_id != null ? var.workload_ami_id : data.aws_ssm_parameter.al2023[0].value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.lab[each.key].id
  private_ip                  = each.value
  vpc_security_group_ids      = [aws_security_group.lab[each.key].id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.workload.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    delete_on_termination = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_route.workload_default,
    aws_route.workload_east_west,
    aws_vpc_security_group_egress_rule.workload_https,
  ]

  tags = { Name = "aws-fgt-ai-lab-${each.key}" }
}

output "workload_instance_ids" {
  value = { for role, instance in aws_instance.workload : role => instance.id }
}
