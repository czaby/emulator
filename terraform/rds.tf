# Aurora MySQL Serverless v2 cluster with one db.serverless instance.
# The master password is generated and is not written to outputs or files
# in this repository.

resource "random_password" "db" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "aws_rds_cluster" "demo" {
  cluster_identifier     = var.db_cluster_identifier
  engine                 = "aurora-mysql"
  engine_mode            = "provisioned"
  database_name          = var.db_name
  master_username        = var.db_username
  master_password        = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.demo.name
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true
  skip_final_snapshot    = true
  apply_immediately      = true
  deletion_protection    = false

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 1
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "aws_rds_cluster_instance" "demo" {
  identifier         = "${var.db_cluster_identifier}-1"
  cluster_identifier = aws_rds_cluster.demo.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.demo.engine
  engine_version     = aws_rds_cluster.demo.engine_version

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
