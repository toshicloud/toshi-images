# Builds the Windows Server 2025 AMI a cloud pool launches:
#
#   AWS_REGION=<the pool's region> aws/build-windows-2025.sh
#
# The script makes the certificate of the build instance's WinRM listener,
# passes it in the two winrm_certificate variables and runs Packer so that
# it trusts that certificate: `packer build` on its own does not connect.
# Credentials come from the environment or the AWS profile, as for the AWS CLI.
# Nothing here names an account: the base image is found by Amazon's owner
# alias and a name filter.

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    # One release: required_plugins takes a version constraint and no
    # checksum, and packer init checks the download against that release's
    # SHA256SUMS (.github/workflows/README.md).
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.3"
    }
  }
}

variable "region" {
  type        = string
  description = "The region of the cloud pool. An AMI is regional: build one per region."
}

variable "toshi_version" {
  type        = string
  description = "The Toshi version the image is built from (git describe); the toshi:version tag."
  validation {
    condition     = length(var.toshi_version) > 0
    error_message = "Pass -var toshi_version=\"$(git describe --tags --always --dirty)\"."
  }
}

variable "guest_version" {
  type        = string
  default     = "none"
  description = "The toshi:guest-version tag. A cloud pool instance runs no toshi-guest, so the default is none."
}

variable "instance_type" {
  type        = string
  default     = "c7i.2xlarge"
  description = "The temporary build instance."
}

variable "root_volume_gib" {
  type        = number
  default     = 64
  description = "The root volume, and so the image's snapshot. A pool starts every instance with a 64 GiB root disk; EC2 refuses a larger snapshot."
  validation {
    condition     = var.root_volume_gib >= 40 && var.root_volume_gib <= 64
    error_message = "The root_volume_gib must be from 40 to 64: a cloud pool's root disk is 64 GiB."
  }
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "A public subnet for the build instance. Empty: the default VPC."
}

variable "winrm_certificate_pfx" {
  type        = string
  sensitive   = true
  description = "The key and certificate of the build instance's WinRM listener: a PKCS #12 file in base64, made for one build by build-windows-2025.sh."
  validation {
    condition     = length(var.winrm_certificate_pfx) > 0
    error_message = "Build with aws/build-windows-2025.sh, which makes the certificate."
  }
}

variable "winrm_certificate_password" {
  type        = string
  sensitive   = true
  description = "The password of winrm_certificate_pfx, letters and digits only."
  validation {
    condition     = can(regex("^[0-9A-Za-z]+$", var.winrm_certificate_password))
    error_message = "The winrm_certificate_password must be letters and digits only: it is written into a quoted PowerShell string."
  }
}

variable "source_ami_name" {
  type        = string
  default     = "Windows_Server-2025-English-Full-Base-*"
  description = "Name filter for Amazon's licence-included Windows Server 2025 base image; the newest match is used."
}

locals {
  built      = timestamp()
  ami_name   = "toshi-windows-2025-${formatdate("YYYYMMDD-hhmmss", local.built)}"
  root       = abspath(path.root)
  config_dir = "${local.root}/../windows-2025"
  provision  = "& C:/toshi/config/aws-provision.ps1 -Step"
  toolset_from = [
    "${local.config_dir}/versions.env",
    "${local.config_dir}/SHA256SUMS",
    "${local.config_dir}/tools.ps1",
    "${local.config_dir}/runner-images.ps1",
    "${local.config_dir}/devdrive.ps1",
    "${local.config_dir}/vendor/runner-images/Configure-System.ps1",
    "${local.config_dir}/vendor/runner-images/Configure-WindowsDefender.ps1",
    "${local.config_dir}/vendor/runner-images/PathHelpers.ps1",
    "${local.root}/windows-2025/provision.ps1",
  ]
  # One hash over everything that decides what the image carries.
  toolset = sha256(join("\n", [for f in local.toolset_from : sha256(file(f))]))
  tags = {
    Name                  = local.ami_name
    "toshi:image"         = "windows-2025"
    "toshi:version"       = var.toshi_version
    "toshi:guest-version" = var.guest_version
    "toshi:toolset"       = local.toolset
    "toshi:built"         = local.built
  }
}

source "amazon-ebs" "windows-2025" {
  region        = var.region
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  source_ami_filter {
    filters = {
      name                = var.source_ami_name
      architecture        = "x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ami_name        = local.ami_name
  ami_description = "Toshi cloud pool image: Windows Server 2025 with the toolsets of windows-2025 (${var.toshi_version})"
  imds_support    = "v2.0"

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # The root volume is the whole image. The pool gives every instance a
  # fresh, empty work volume and formats it when it prepares the instance.
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_gib
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # WinRM over HTTPS as Administrator, with the password EC2 generates for
  # the temporary key pair. Packer checks the listener's certificate
  # (winrm_insecure = false): the user data installs the one
  # build-windows-2025.sh made for this build, and the script adds that
  # certificate to the roots Packer trusts. It is issued for the public DNS
  # names of the region's instances, so Packer connects by that name and
  # not by address. The temporary security group admits only the address
  # Packer runs from.
  user_data = templatefile("${local.root}/windows-2025/winrm-userdata.txt", {
    pfx      = var.winrm_certificate_pfx
    password = var.winrm_certificate_password
  })
  communicator                              = "winrm"
  ssh_interface                             = "public_dns"
  winrm_username                            = "Administrator"
  winrm_use_ssl                             = true
  winrm_insecure                            = false
  winrm_timeout                             = "20m"
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  # The seal step closes WinRM and shuts Windows down itself, so Packer only
  # waits for the instance to stop. No Sysprep runs: see docs/cloud-pools.md.
  disable_stop_instance = true

  # A snapshot of the whole system volume can take longer than the default
  # ten minutes of waiting.
  aws_polling {
    delay_seconds = 15
    max_attempts  = 160
  }

  tags          = local.tags
  snapshot_tags = local.tags
  run_tags = {
    Name = "toshi-windows-2025-build"
  }
  run_volume_tags = {
    Name = "toshi-windows-2025-build"
  }
}

build {
  sources = ["source.amazon-ebs.windows-2025"]

  provisioner "powershell" {
    inline = ["New-Item -ItemType Directory -Force -Path C:/toshi/config | Out-Null"]
  }

  # The local image's provisioning, unchanged, and the wrapper that runs it.
  provisioner "file" {
    source      = "${local.config_dir}/"
    destination = "C:/toshi/config/"
  }

  provisioner "file" {
    source      = "${local.root}/windows-2025/provision.ps1"
    destination = "C:/toshi/config/aws-provision.ps1"
  }

  # Installers need a full logon token and more memory than a WinRM shell
  # allows, so the long steps run as a scheduled task of Administrator.
  provisioner "powershell" {
    elevated_user     = "Administrator"
    elevated_password = build.Password
    inline            = ["${local.provision} tools"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    elevated_user     = "Administrator"
    elevated_password = build.Password
    inline            = ["${local.provision} devdrive"]
  }

  provisioner "powershell" {
    elevated_user     = "Administrator"
    elevated_password = build.Password
    inline            = ["${local.provision} settle"]
  }

  provisioner "powershell" {
    inline = ["${local.provision} seal"]
  }

  post-processor "manifest" {
    output     = "${local.root}/windows-2025-ami.json"
    strip_path = true
    custom_data = {
      region        = var.region
      toshi_version = var.toshi_version
      toolset       = local.toolset
      built         = local.built
    }
  }
}
