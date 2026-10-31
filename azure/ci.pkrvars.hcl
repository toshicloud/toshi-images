# Values for `packer validate` only: no Azure account is needed and nothing
# is created. build-linux-pool-host.sh validate passes this file; the
# script fills the base image variables from linux-pool-host/versions.env.
subscription_id        = "00000000-0000-0000-0000-000000000000"
gallery_resource_group = "ci"
gallery_name           = "ci"
location               = "westeurope"
image_version          = "0.0.1"
toshi_version          = "ci"
# The script passes an empty file of its own; this keeps a direct
# `packer validate -var-file` working too.
agent_tarball = "/dev/null"
