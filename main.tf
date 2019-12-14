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

variable "db_admin_username" {
  type = string
}
variable "db_admin_password" {
  type = string
}

variable "db_username" {
  type = string
}
variable "db_password" {
  type = string
}

variable "smtp_username" {
  type = string
}
variable "smtp_password" {
  type = string
}

variable "crypto_master_salt" {
  type = string
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

resource "aws_s3_bucket" "issues" {
  bucket = "org.fidata.issues"
  versioning {
    enabled = true
  }
}

resource "aws_s3_bucket_object" "issues" {
  bucket = aws_s3_bucket.issues.id
  key    = "issues.zip"
  source = "build/issues.zip"
  etag = filemd5("build/issues.zip")
  storage_class = "ONEZONE_IA"
}

# RDS Database

resource "aws_db_instance" "issues" {
  storage_type         = "gp2"
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "11.5"
  instance_class       = "db.t3.micro"
  name                 = "bugtracker"
  username             = var.db_admin_username
  password             = var.db_admin_password
  # parameter_group_name = "default.postgres11"
  port = 5432
  db_subnet_group_name = data.terraform_remote_state.fidata_org.outputs.fidata_db_subnet_group_name
  vpc_security_group_ids = [
    data.terraform_remote_state.fidata_org.outputs.default_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.ICMP_private_security_group_id,
    data.terraform_remote_state.fidata_org.outputs.PostgreSQL_private_security_group_id,
  ]
  multi_az = false
  maintenance_window = "Sat:01:00-Sat:03:00"
  skip_final_snapshot = true # TODO
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

# Elastic Beanstalk

resource "aws_elastic_beanstalk_application" "issues" {
  name        = "issues"
#  appversion_lifecycle {
#    service_role          = data.terraform_remote_state.fidata_org.outputs.elastic_beanstalk_service_role_arn
#    max_count             = 24
#    delete_source_from_s3 = true
#  }
}

resource "aws_elastic_beanstalk_application_version" "issues" {
  name        = "issues-${aws_s3_bucket_object.issues.version_id}"
  application = aws_elastic_beanstalk_application.issues.name
  bucket      = aws_s3_bucket.issues.id
  key         = aws_s3_bucket_object.issues.id
}

resource "aws_elastic_beanstalk_environment" "issues" {
  name                   = "issues"
  application            = aws_elastic_beanstalk_application.issues.name
  tier                   = "WebServer"
  solution_stack_name    = "64bit Amazon Linux 2018.03 v2.9.1 running PHP 7.3"
  version_label          = aws_elastic_beanstalk_application_version.issues.name

  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = data.terraform_remote_state.fidata_org.outputs.fidata_vpc_id
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = data.terraform_remote_state.fidata_org.outputs.fidata_subnet_id
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "SecurityGroups"
    value     = join(",", [
      data.terraform_remote_state.fidata_org.outputs.default_security_group_id,
      data.terraform_remote_state.fidata_org.outputs.ICMP_security_group_id,
      data.terraform_remote_state.fidata_org.outputs.HTTP_S_security_group_id,
      # data.terraform_remote_state.fidata_org.outputs.SSH_private_security_group_id,
      data.terraform_remote_state.fidata_org.outputs.SSH_security_group_id,
    ])
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = data.terraform_remote_state.fidata_org.outputs.elastic_beanstalk_web_server_instance_profile_name
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "SingleInstance"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = data.terraform_remote_state.fidata_org.outputs.elastic_beanstalk_service_role_arn
  }

  setting {
    namespace = "aws:elasticbeanstalk:healthreporting:system"
    name      = "SystemType"
    value     = "enhanced" # required for managed updates
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
    value     = "t3a.micro"
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeType"
    value     = "standard"
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeSize"
    value     = 8
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "EC2KeyName"
    value     = data.terraform_remote_state.fidata_org.outputs.fidata_main_key_name
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

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "RDS_ENGINE"
    value     = aws_db_instance.issues.engine
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "RDS_HOSTNAME"
    value     = aws_db_instance.issues.address
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "RDS_PORT"
    value     = aws_db_instance.issues.port
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "RDS_DB_NAME"
    value     = aws_db_instance.issues.name
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "RDS_USERNAME"
    value     = var.db_username
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "RDS_PASSWORD"
    value     = var.db_password
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "REGION"
    value     = "eu-west-1" # TODO
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "FILE_SYSTEM_ID"
    value     = aws_efs_mount_target.attachments.file_system_id
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "MOUNT_DIRECTORY"
    value     = "/mnt/attachments"
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "SMTP_USERNAME"
    value     = var.smtp_username
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "SMTP_PASSWORD"
    value     = var.smtp_password
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "CRYPTO_MASTER_SALT"
    value     = var.crypto_master_salt
  }

  setting {
    namespace = "aws:elasticbeanstalk:container:php:phpini"
    name      = "zlib.output_compression"
    value     = "On"
  }

  setting {
    namespace = "aws:elasticbeanstalk:container:php:phpini"
    name      = "display_errors"
    value     = "On" # TODO
  }

  # cname_prefix = "org.fidata"
}

output "issues_ip" {
  value = aws_elastic_beanstalk_environment.issues.endpoint_url
}

# DNS

resource "cloudflare_record" "issues" {
  zone_id = data.terraform_remote_state.fidata_org.outputs.fidata_org_zone_id
  name = "issues"
  type = "CNAME"
  value = aws_elastic_beanstalk_environment.issues.cname
  proxied = true
}
