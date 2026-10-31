# The Compute Gallery image version a Linux cloud pool's host boots on
# Azure: Ubuntu 24.04 with the Toshi agent, its unit (installed, not
# enabled), QEMU, passt, OVMF, nftables and the guest image ubuntu-24.04 in
# the agent's image directory. The pool's user data writes
# /etc/toshi/enrollment-token and /etc/toshi/agent.toml and enables the
# unit.
#
# The image is Gen2, Generalized, x64 and Standard: the gallery image
# definition says so, and this template sets no security type. The build
# ends with waagent's deprovision, which takes the build's user and keys
# out of the image before Packer generalizes it.
#
# Run it with build-linux-pool-host.sh, which fetches and checks the agent
# archive this template uploads and ensures the gallery's image definition.

packer {
  required_version = ">= 1.11.0"
  # required_plugins takes a version constraint and no checksum.
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "= 2.6.5"
    }
  }
}

variable "subscription_id" {
  type        = string
  description = "The Azure subscription that holds the gallery and runs the build."
}

variable "gallery_resource_group" {
  type        = string
  description = "The resource group of the Compute Gallery that takes the image version."
}

variable "gallery_name" {
  type        = string
  description = "The name of the Compute Gallery."
}

variable "image_name" {
  type        = string
  default     = "linux-pool-host"
  description = "The gallery image definition build-linux-pool-host.sh creates or checks."
}

variable "image_version" {
  type        = string
  description = "The gallery image version, X.Y.Z."
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.image_version))
    error_message = "The image_version variable must be X.Y.Z."
  }
}

variable "location" {
  type        = string
  description = "The Azure region of the build and of the image version's single replica."
}

variable "build_resource_group_name" {
  type        = string
  default     = ""
  description = "An existing resource group to build in; empty creates a temporary one in location. The two are exclusive."
}

variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
  # Dsv5 sizes support nested virtualisation for the pool's VMs. The build
  # itself runs no VM and needs no /dev/kvm.
  description = "The build VM's size."
}

variable "os_disk_size_gb" {
  type    = number
  default = 30
  validation {
    condition     = var.os_disk_size_gb >= 16 && var.os_disk_size_gb <= 64
    error_message = "The os_disk_size_gb variable must be between 16 and 64."
  }
}

variable "use_azure_cli_auth" {
  type        = bool
  default     = true
  description = "Take the build's credential from the Azure CLI's login instead of a service principal."
}

variable "client_id" {
  type        = string
  default     = ""
  description = "The service principal's application id, when use_azure_cli_auth is false."
}

variable "client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "The service principal's secret, when use_azure_cli_auth is false."
}

variable "tenant_id" {
  type        = string
  default     = ""
  description = "The service principal's tenant, when use_azure_cli_auth is false."
}

variable "base_image_publisher" {
  type        = string
  description = "Canonical, from linux-pool-host/versions.env."
}

variable "base_image_offer" {
  type        = string
  description = "The Ubuntu 24.04 offer, from linux-pool-host/versions.env."
}

variable "base_image_sku" {
  type        = string
  description = "The Ubuntu 24.04 server SKU, from linux-pool-host/versions.env."
}

variable "base_image_version" {
  type        = string
  description = "Canonical's Azure image of the pinned serial, from linux-pool-host/versions.env."
}

variable "toshi_version" {
  type        = string
  description = "The version of this repository the image is built from, for its tags."
  validation {
    condition     = length(var.toshi_version) > 0
    error_message = "The toshi_version variable must not be empty."
  }
}

variable "agent_tarball" {
  type        = string
  description = "The agent archive named in linux-pool-host/versions.env, already checked against its SHA-256."
}

locals {
  built    = timestamp()
  root     = abspath(path.root)
  config   = "${local.root}/../linux-pool-host"
  versions = file("${local.config}/versions.env")
  pin      = { for k in ["UBUNTU_SERIAL", "TOSHI_AGENT_VERSION", "TOSHI_AGENT_ASSET", "GUEST_VERSION"] : k => regex("(?m)^${k}=(\\S+)$", local.versions)[0] }
  tags = {
    "toshi-image"         = "linux-pool-host"
    "toshi-version"       = var.toshi_version
    "toshi-agent-version" = local.pin.TOSHI_AGENT_VERSION
    "toshi-guest-version" = local.pin.GUEST_VERSION
    "toshi-ubuntu-serial" = local.pin.UBUNTU_SERIAL
  }
}

source "azure-arm" "linux-pool-host" {
  subscription_id = var.subscription_id

  # Without a service principal the plugin takes the Azure CLI's login.
  client_id          = var.use_azure_cli_auth ? null : var.client_id
  client_secret      = var.use_azure_cli_auth ? null : var.client_secret
  tenant_id          = var.use_azure_cli_auth ? null : var.tenant_id
  use_azure_cli_auth = var.use_azure_cli_auth

  # One exact base image: the version is pinned, so no newest-match drift.
  image_publisher = var.base_image_publisher
  image_offer     = var.base_image_offer
  image_sku       = var.base_image_sku
  image_version   = var.base_image_version
  os_type         = "Linux"

  # No security_type: it only takes TrustedLaunch or ConfidentialVM, and
  # the pool's contract is Standard.
  vm_size         = var.vm_size
  os_disk_size_gb = var.os_disk_size_gb

  # One of the two: the plugin refuses a location with a build resource
  # group, and needs a location without one.
  build_resource_group_name = var.build_resource_group_name != "" ? var.build_resource_group_name : null
  location                  = var.build_resource_group_name == "" ? var.location : null

  communicator = "ssh"
  ssh_username = "packer"
  ssh_timeout  = "10m"

  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group
    gallery_name         = var.gallery_name
    image_name           = var.image_name
    image_version        = var.image_version
    storage_account_type = "Standard_LRS"
    target_region {
      name = var.location
    }
  }

  azure_tags = local.tags
}

build {
  sources = ["source.azure-arm.linux-pool-host"]

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
      "sudo bash /tmp/toshi/provision.sh build azure /tmp/toshi",
      "sudo bash /tmp/toshi/provision.sh seal azure /tmp/toshi",
    ]
  }

  # The plugin's last step: remove the build's user and keys and
  # deprovision the agent, then let Packer generalize and capture the image.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline          = ["/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"]
    inline_shebang  = "/bin/sh -x"
  }

  post-processor "manifest" {
    output     = "${local.root}/linux-pool-host.json"
    strip_path = true
    custom_data = {
      subscription   = var.subscription_id
      resource_group = var.gallery_resource_group
      gallery        = var.gallery_name
      image_name     = var.image_name
      image_version  = var.image_version
      location       = var.location
      toshi_version  = var.toshi_version
      agent_version  = local.pin.TOSHI_AGENT_VERSION
      guest_version  = local.pin.GUEST_VERSION
      ubuntu_serial  = local.pin.UBUNTU_SERIAL
      built          = local.built
    }
  }
}
