# Minimal networking for Aurora (subnets in two AZs) and a Fargate
# service that pulls its image with a public IP.
#
# Security groups use standalone aws_vpc_security_group_*_rule resources
# (the current AWS provider style) rather than inline ingress/egress
# blocks. Inline egress makes the provider revoke the AWS default
# allow-all egress rule, and the emulator returns InvalidPermission.NotFound
# for that RevokeSecurityGroupEgress call.

resource "aws_vpc" "demo" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "emulator-demo"
  }
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "emulator-demo"
  }
}

resource "aws_subnet" "demo" {
  count = 2

  vpc_id                  = aws_vpc.demo.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "emulator-demo-${count.index}"
  }
}

resource "aws_route_table" "demo" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }

  tags = {
    Name = "emulator-demo"
  }
}

resource "aws_route_table_association" "demo" {
  count = 2

  subnet_id      = aws_subnet.demo[count.index].id
  route_table_id = aws_route_table.demo.id
}

resource "aws_security_group" "db" {
  name        = "emulator-demo-db"
  description = "Aurora MySQL from inside the demo VPC"
  vpc_id      = aws_vpc.demo.id

  tags = {
    Name = "emulator-demo-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_mysql" {
  security_group_id = aws_security_group.db.id
  description       = "MySQL"
  cidr_ipv4         = aws_vpc.demo.cidr_block
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

resource "aws_security_group" "ecs" {
  name        = "emulator-demo-ecs"
  description = "Fargate tasks in the demo VPC"
  vpc_id      = aws_vpc.demo.id

  tags = {
    Name = "emulator-demo-ecs"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_http" {
  security_group_id = aws_security_group.ecs.id
  description       = "HTTP"
  cidr_ipv4         = aws_vpc.demo.cidr_block
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_db_subnet_group" "demo" {
  name       = "emulator-demo"
  subnet_ids = aws_subnet.demo[*].id

  tags = {
    Name = "emulator-demo"
  }
}
