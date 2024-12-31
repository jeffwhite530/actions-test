packer {
  required_plugins {
    ansible = {
      version = "~> 1"
      source  = "github.com/hashicorp/ansible"
    }
    docker = {
      version = ">= 0.0.7"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "base_image" {
  default = "debian:bookworm"
}

variable "slurm_version_tag" {
  default = "24-11-0-1"
}

variable "ansible_host" {
  default = "default"
}

variable "image_name" {
  #default = "slurm"
  default = "docker-registry.jealwh.local:5000/slurm"
}

locals {
  slurm_source_url = "https://github.com/SchedMD/slurm/archive/refs/tags/slurm-${var.slurm_version_tag}.tar.gz"
}

source "docker" "base_image" {
  image  = var.base_image
  commit = true
  pull   = true
  #changes = [
  #  "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]"
  #]
  run_command = [ "-d", "-i", "-t", "--name", var.ansible_host, "{{.Image}}", "/bin/bash" ]
}

build {
  name = "slurm"
  sources = ["source.docker.base_image"]

  # Install Python before running Ansible
  provisioner "shell" {
    inline = [
      "apt-get update",
      "apt-get install -y python3"
    ]
  }

  provisioner "ansible" {
    playbook_file = "../ansible/build-slurm-image.yaml"
    user          = "root"
    extra_arguments = [
      "--extra-vars",
      <<EOT
      slurm_source_url=${local.slurm_source_url} 
      ansible_host=${var.ansible_host} 
      ansible_connection=docker 
      EOT
    ]
  }

  post-processors {
    post-processor "docker-tag" {
      repository = var.image_name
      tags       = [var.slurm_version_tag]
    }

    post-processor "docker-push" {
      keep_input_artifact = true
    }
  }
}
