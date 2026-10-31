# The AMI a Linux cloud pool's host boots: Ubuntu 24.04 with the Toshi
# agent, its unit (installed, not enabled), QEMU, passt, OVMF, nftables
# and the guest image ubuntu-24.04 in the agent's image directory. The
# pool's user data writes /etc/toshi/enrollment-token and
# /etc/toshi/agent.toml and enables the unit.
#
# Run it with build-linux-pool-host.sh, which fetches and checks the agent
# archive this template uploads.

packer {
  required_version = ">= 1.11.0"
  # required_plugins takes a version constraint and no checksum.
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.3"
    }
  }
}

variable "region" {
  type        = string
  description = "The AWS region the AMI is built in."
}

variable "toshi_version" {
  type        = string
  description = "The version of this repository the AMI is built from, for its tags."
  validation {
    condition     = length(var.toshi_version) > 0
    error_message = "The toshi_version variable must not be empty."
  }
}

variable "agent_tarball" {
  type        = string
  description = "The agent archive named in linux-pool-host/versions.env, already checked against its SHA-256."
}

variable "instance_type" {
  type    = string
  default = "c7i.large"
}

variable "root_volume_gib" {
  type        = number
  default     = 30
  description = "The AMI's root volume. A pool's launch can make it larger, and cloud-init grows the file system."
  validation {
    condition     = var.root_volume_gib >= 16 && var.root_volume_gib <= 64
    error_message = "The root_volume_gib variable must be between 16 and 64."
  }
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "The subnet of the build instance; empty is the default VPC."
}

variable "share_with" {
  type        = string
  default     = ""
  description = "Comma-separated AWS account ids that may launch the AMI."
}

locals {
  built    = timestamp()
  ami_name = "toshi-linux-pool-host-${formatdate("YYYYMMDD-hhmmss", local.built)}"
  root     = abspath(path.root)
  config   = "${local.root}/../linux-pool-host"
  versions = file("${local.config}/versions.env")
  pin      = { for k in ["UBUNTU_SERIAL", "UBUNTU_AMI_OWNER", "TOSHI_AGENT_VERSION", "TOSHI_AGENT_ASSET", "GUEST_VERSION"] : k => regex("(?m)^${k}=(\\S+)$", local.versions)[0] }
  accounts = compact([for a in split(",", var.share_with) : trimspace(a)])
  tags = {
    Name                  = local.ami_name
    "toshi:image"         = "linux-pool-host"
    "toshi:version"       = var.toshi_version
    "toshi:agent-version" = local.pin.TOSHI_AGENT_VERSION
    "toshi:guest-version" = local.pin.GUEST_VERSION
    "toshi:ubuntu-serial" = local.pin.UBUNTU_SERIAL
    "toshi:built"         = local.built
  }
}

source "amazon-ebs" "linux-pool-host" {
  region        = var.region
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  # One exact image: the serial is pinned, so no newest-match drift.
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-${local.pin.UBUNTU_SERIAL}"
      architecture        = "x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = [local.pin.UBUNTU_AMI_OWNER]
    most_recent = false
  }

  ami_name        = local.ami_name
  ami_description = "Toshi Linux pool host, agent ${local.pin.TOSHI_AGENT_VERSION}, guest ubuntu-24.04 ${local.pin.GUEST_VERSION}"
  ami_users       = local.accounts
  snapshot_users  = local.accounts
  imds_support    = "v2.0"
  ena_support     = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  communicator                              = "ssh"
  ssh_username                              = "ubuntu"
  ssh_timeout                               = "10m"
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  aws_polling {
    delay_seconds = 15
    max_attempts  = 160
  }

  tags          = local.tags
  snapshot_tags = local.tags
  run_tags = {
    Name = "toshi-linux-pool-host-build"
  }
  run_volume_tags = {
    Name = "toshi-linux-pool-host-build"
  }
}

build {
  sources = ["source.amazon-ebs.linux-pool-host"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/toshi"]
  }

  provisioner "file" {
    sources = [
      "${local.config}/provision.sh",
      "${local.config}/versions.env",
      "${local.root}/../install.sh",
    ]
    destination = "/tmp/toshi/"
  }

  provisioner "file" {
    source      = var.agent_tarball
    destination = "/tmp/toshi/${local.pin.TOSHI_AGENT_ASSET}"
  }

  provisioner "shell" {
    inline = [
      "sudo bash /tmp/toshi/provision.sh build /tmp/toshi",
      "sudo bash /tmp/toshi/provision.sh seal /tmp/toshi",
    ]
  }

  post-processor "manifest" {
    output     = "${local.root}/linux-pool-host-ami.json"
    strip_path = true
    custom_data = {
      region        = var.region
      toshi_version = var.toshi_version
      agent_version = local.pin.TOSHI_AGENT_VERSION
      guest_version = local.pin.GUEST_VERSION
      ubuntu_serial = local.pin.UBUNTU_SERIAL
      built         = local.built
    }
  }
}
