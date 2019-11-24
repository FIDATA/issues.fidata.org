# SPDX-FileCopyrightText: ©  Basil Peace
# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = "~> 0.12"
  backend "artifactory" {
    url     = "https://fidata.jfrog.io/fidata"
    repo    = "terraform-state"
    subpath = "issues.fidata.org"
  }
}

# Providers

provider "aws" {
  version = "~> 2.36"
  region = "eu-west-1"
}

provider "cloudflare" {
  version = "~> 2.1"
}

# Remote State

data "terraform_remote_state" "fidata_org" {
  backend = "artifactory"
  config = {
    url      = "https://fidata.jfrog.io/fidata"
    repo     = "terraform-state"
    subpath  = "fidata.org"
  }
}

# CodeCommit repository
resource "aws_codecommit_repository" "issues_fidata_org" {
  repository_name = "issues.fidata.org"
  default_branch = "master"
}

# RDS Database

resource "aws_db_instance" "issues" {
  storage_type         = "gp2"
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "11.5"
  instance_class       = "db.t3.micro"
  name                 = "mantis"
  username             = "postgres"
  password             = "foobarbaz"
  # parameter_group_name = "default.postgres11"
  port = 5432
  db_subnet_group_name = data.terraform_remote_state.fidata_org.outputs.fidata_db_subnet_group_name
  vpc_security_group_ids = [
    data.terraform_remote_state.fidata_org.outputs.default_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.ICMP_private_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.PostgreSQL_private_security_group_id,
  ]
  skip_final_snapshot = true # TODO
}
output "issues_db_address" {
  value = aws_db_instance.issues.address
}
output "issues_db_port" {
  value = aws_db_instance.issues.port
}

# EFS for attachments

resource "aws_efs_file_system" "attachments" {
  creation_token = "issues-attachments"
  performance_mode = "generalPurpose"
  throughput_mode = "bursting"
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
}

resource "aws_efs_mount_target" "attachments" {
  file_system_id = aws_efs_file_system.attachments.id
  subnet_id      = data.terraform_remote_state.fidata_org.outputs.fidata_subnet_id
  security_groups = [
    data.terraform_remote_state.fidata_org.outputs.default_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.ICMP_private_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.NFS_private_security_group_id,
  ]
}
output "attachments_efs_address" {
  value = aws_efs_mount_target.attachments.dns_name
}

# Source AMI

data "aws_ami" "UbuntuServer" {
  owners   = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  most_recent = true
}

# EC2 Instance

resource "aws_instance" "issues" {
  ami = data.aws_ami.UbuntuServer.id
  subnet_id = data.terraform_remote_state.fidata_org.outputs.fidata_subnet_id
  instance_type = "t2.micro"
  root_block_device {
    volume_type = "standard"
    volume_size = 8
  }
  vpc_security_group_ids = [
    data.terraform_remote_state.fidata_org.outputs.default_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.ICMP_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.HTTP_S_security_group_id,
    # data.terraform_remote_state.fidata_org.outputs.SSH_private_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.SSH_security_group_id,
  ]
  key_name = "fidata-main"
  tags = {
    Name = "FIDATA Issues"
  }
  lifecycle {
    create_before_destroy = true
  }
}

output "issues_ip" {
  value = aws_eip.issues.public_ip
}

resource "aws_elastic_beanstalk_environment" "default" {
  name                   = module.label.id
  application            = var.elastic_beanstalk_application_name
  description            = var.description
  tier                   = var.tier
  solution_stack_name    = var.solution_stack_name
  wait_for_ready_timeout = var.wait_for_ready_timeout
  version_label          = var.version_label
  tags                   = local.tags

  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = data.terraform_remote_state.fidata_org.outputs.fidata_vpc_id
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "AssociatePublicIpAddress"
    value     = var.associate_public_ip_address
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = data.terraform_remote_state.fidata_org.outputs.fidata_subnet_id
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "SecurityGroups"
    value     = [
      data.terraform_remote_state.fidata_org.outputs.default_security_group_id,
      data.terraform_remote_state.fidata_org.outputs.ICMP_security_group_id,
      data.terraform_remote_state.fidata_org.outputs.HTTP_S_security_group_id,
      # data.terraform_remote_state.fidata_org.outputs.SSH_private_security_group_id,
      data.terraform_remote_state.fidata_org.outputs.SSH_security_group_id,
    ]
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.ec2.name
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "SingleInstance"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = aws_iam_role.service.name
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "BASE_HOST"
    value     = var.name
  }

  setting {
    namespace = "aws:elasticbeanstalk:healthreporting:system"
    name      = "SystemType"
    value     = 'basic'
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "RollingUpdateEnabled"
    value     = false
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "RollingUpdateType"
    value     = "Immutable"
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "MinInstancesInService"
    value     = 1
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "DeploymentPolicy"
    value     = "Immutable"
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = "t2.micro"
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "EC2KeyName"
    value     = data.terraform_remote_state.fidata_org.outputs.fidata_main_key_name
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeSize"
    value     = 8
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeType"
    value     = "standard"
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSizeType"
    value     = "Fixed"
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSize"
    value     = "1"
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions"
    name      = "ManagedActionsEnabled"
    value     = true
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions"
    name      = "PreferredStartTime"
    value     = "Sat:01:00"
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions:platformupdate"
    name      = "UpdateLevel"
    value     = "patch"
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions:platformupdate"
    name      = "InstanceRefreshEnabled"
    value     = false # TODO
  }

  ###=========================== Autoscale trigger ========================== ###

//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "MeasureName"
//    value     = var.autoscale_measure_name
//  }

//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "Statistic"
//    value     = var.autoscale_statistic
//  }
//
//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "Unit"
//    value     = var.autoscale_unit
//  }
//
//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "LowerThreshold"
//    value     = var.autoscale_lower_bound
//  }
//
//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "LowerBreachScaleIncrement"
//    value     = var.autoscale_lower_increment
//  }
//
//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "UpperThreshold"
//    value     = var.autoscale_upper_bound
//  }
//
//  setting {
//    namespace = "aws:autoscaling:trigger"
//    name      = "UpperBreachScaleIncrement"
//    value     = var.autoscale_upper_increment
//  }

  ###=========================== Logging ========================== ###

//  setting {
//    namespace = "aws:elasticbeanstalk:hostmanager"
//    name      = "LogPublicationControl"
//    value     = var.enable_log_publication_control ? "true" : "false" TODO
//  }

//  setting {
//    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
//    name      = "StreamLogs"
//    value     = var.enable_stream_logs ? "true" : "false"
//  }

//  setting {
//    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
//    name      = "DeleteOnTerminate"
//    value     = var.logs_delete_on_terminate ? "true" : "false"
//  }
//
//  setting {
//    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
//    name      = "RetentionInDays"
//    value     = var.logs_retention_in_days
//  }
//
//  setting {
//    namespace = "aws:elasticbeanstalk:cloudwatch:logs:health"
//    name      = "HealthStreamingEnabled"
//    value     = var.health_streaming_enabled ? "true" : "false"
//  }
//
//  setting {
//    namespace = "aws:elasticbeanstalk:cloudwatch:logs:health"
//    name      = "DeleteOnTerminate"
//    value     = var.health_streaming_delete_on_terminate ? "true" : "false"
//  }
//
//  setting {
//    namespace = "aws:elasticbeanstalk:cloudwatch:logs:health"
//    name      = "RetentionInDays"
//    value     = var.health_streaming_retention_in_days
//  }

  // Add environment variables if provided
  dynamic "setting" {
    for_each = var.cd
    content {
      namespace = "aws:elasticbeanstalk:application:environment"
      name      = setting.key
      value     = setting.value
    }
  }
}

# Elastic IP

resource "aws_eip" "issues" {
  instance = aws_instance.issues.id
  vpc = true
}

# DNS

resource "cloudflare_record" "issues" {
  zone_id = data.terraform_remote_state.fidata_org.outputs.fidata_org_zone_id
  name = "issues"
  type = "A"
  value = aws_eip.issues.public_ip
  proxied = true
}
