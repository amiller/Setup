terraform {
  backend "s3" {
    bucket = "aztec-terraform"
    key    = "setup/setup-mpc-server"
    region = "eu-west-2"
  }
}

data "terraform_remote_state" "setup_iac" {
  backend = "s3"
  config = {
    bucket = "aztec-terraform"
    key    = "setup/setup-iac"
    region = "eu-west-2"
  }
}

provider "aws" {
  profile = "default"
  region  = "eu-west-2"
}

resource "aws_service_discovery_service" "setup_mpc_server" {
  name = "setup-mpc-server"

  health_check_custom_config {
    failure_threshold = 1
  }

  dns_config {
    namespace_id = "${data.terraform_remote_state.setup_iac.outputs.local_service_discovery_id}"

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

# Create EC2 instances in each AZ.
resource "aws_instance" "container_instance_az1" {
  ami                    = "ami-010624faf51b049d3"
  instance_type          = "m5.xlarge"
  subnet_id              = "${data.terraform_remote_state.setup_iac.outputs.subnet_az1_private_id}"
  vpc_security_group_ids = ["${data.terraform_remote_state.setup_iac.outputs.security_group_private_id}"]
  iam_instance_profile   = "${data.terraform_remote_state.setup_iac.outputs.ecs_instance_profile_name}"
  key_name               = "${data.terraform_remote_state.setup_iac.outputs.ecs_instance_key_pair_name}"
  availability_zone      = "eu-west-2a"

  user_data = <<USER_DATA
#!/bin/bash
echo ECS_CLUSTER=${data.terraform_remote_state.setup_iac.outputs.ecs_cluster_name} >> /etc/ecs/ecs.config
USER_DATA

  tags = {
    Name = "setup-container-instance-az1"
  }
}

resource "aws_instance" "container_instance_az2" {
  ami                    = "ami-010624faf51b049d3"
  instance_type          = "m5.xlarge"
  subnet_id              = "${data.terraform_remote_state.setup_iac.outputs.subnet_az2_private_id}"
  vpc_security_group_ids = ["${data.terraform_remote_state.setup_iac.outputs.security_group_private_id}"]
  iam_instance_profile   = "${data.terraform_remote_state.setup_iac.outputs.ecs_instance_profile_name}"
  key_name               = "${data.terraform_remote_state.setup_iac.outputs.ecs_instance_key_pair_name}"
  availability_zone      = "eu-west-2b"

  user_data = <<USER_DATA
#!/bin/bash
echo ECS_CLUSTER=${data.terraform_remote_state.setup_iac.outputs.ecs_cluster_name} >> /etc/ecs/ecs.config
USER_DATA

  tags = {
    Name = "setup-container-instance-az2"
  }
}

# Configure an EFS filesystem for holding transcripts and state data, mountable in each AZ.
resource "aws_efs_file_system" "setup_data_store" {
  creation_token = "setup-data-store"

  tags = {
    Name = "setup-data-store"
  }

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
}

resource "aws_efs_mount_target" "private_az1" {
  file_system_id  = "${aws_efs_file_system.setup_data_store.id}"
  subnet_id       = "${data.terraform_remote_state.setup_iac.outputs.subnet_az1_private_id}"
  security_groups = ["${data.terraform_remote_state.setup_iac.outputs.security_group_private_id}"]
}

resource "aws_efs_mount_target" "private_az2" {
  file_system_id  = "${aws_efs_file_system.setup_data_store.id}"
  subnet_id       = "${data.terraform_remote_state.setup_iac.outputs.subnet_az2_private_id}"
  security_groups = ["${data.terraform_remote_state.setup_iac.outputs.security_group_private_id}"]
}

# Define task definition and service.
resource "aws_ecs_task_definition" "setup_mpc_server" {
  family                   = "setup-mpc-server"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = "${data.terraform_remote_state.setup_iac.outputs.ecs_task_execution_role_arn}"

  volume {
    name = "efs-data-store"
    docker_volume_configuration {
      scope         = "shared"
      autoprovision = true
      driver        = "local"
      driver_opts = {
        type   = "nfs"
        device = "${aws_efs_file_system.setup_data_store.dns_name}:/"
        o      = "addr=${aws_efs_file_system.setup_data_store.dns_name},nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"
      }
    }
  }

  container_definitions = <<DEFINITIONS
[
  {
    "name": "setup-mpc-server",
    "image": "278380418400.dkr.ecr.eu-west-2.amazonaws.com/setup-mpc-server:latest",
    "essential": true,
    "memoryReservation": 256,
    "portMappings": [
      {
        "containerPort": 80
      }
    ],
    "environment": [
      {
        "name": "NODE_ENV",
        "value": "production"
      }
    ],
    "mountPoints": [
      {
        "containerPath": "/usr/src/setup-mpc-server/store",
        "sourceVolume": "efs-data-store"
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/fargate/service/setup-mpc-server",
        "awslogs-region": "eu-west-2",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
DEFINITIONS
}

data "aws_ecs_task_definition" "setup_mpc_server" {
  task_definition = "${aws_ecs_task_definition.setup_mpc_server.family}"
}

resource "aws_ecs_service" "setup_mpc_server" {
  name          = "setup-mpc-server"
  cluster       = "${data.terraform_remote_state.setup_iac.outputs.ecs_cluster_id}"
  launch_type   = "EC2"
  desired_count = "1"

  network_configuration {
    subnets = [
      "${data.terraform_remote_state.setup_iac.outputs.subnet_az1_private_id}",
      "${data.terraform_remote_state.setup_iac.outputs.subnet_az2_private_id}"
    ]
    security_groups = ["${data.terraform_remote_state.setup_iac.outputs.security_group_private_id}"]
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.setup_mpc_server.arn}"
    container_name   = "setup-mpc-server"
    container_port   = 80
  }

  service_registries {
    registry_arn = "${aws_service_discovery_service.setup_mpc_server.arn}"
  }

  task_definition = "${aws_ecs_task_definition.setup_mpc_server.family}:${max("${aws_ecs_task_definition.setup_mpc_server.revision}", "${data.aws_ecs_task_definition.setup_mpc_server.revision}")}"
}

# Logs
resource "aws_cloudwatch_log_group" "setup_mpc_server_logs" {
  name              = "/fargate/service/setup-mpc-server"
  retention_in_days = "14"
}

# Configure ALB to route /api to server.
resource "aws_alb_target_group" "setup_mpc_server" {
  name        = "setup-mpc-server"
  port        = "80"
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${data.terraform_remote_state.setup_iac.outputs.vpc_id}"

  health_check {
    path    = "/api"
    matcher = "200"
  }

  tags = {
    name = "setup-mpc-server"
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = "${data.terraform_remote_state.setup_iac.outputs.alb_listener_arn}"
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.setup_mpc_server.arn}"
  }

  condition {
    field  = "path-pattern"
    values = ["/api/*"]
  }
}
