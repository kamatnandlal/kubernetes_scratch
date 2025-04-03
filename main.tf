provider "google" {
  project = var.project_id
  region  = var.region
}

# Create VPC network
resource "google_compute_network" "k8s_network" {
  name                    = "k8s-network"
  auto_create_subnetworks = false
}

# Create subnet
resource "google_compute_subnetwork" "k8s_subnet" {
  name          = "k8s-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.k8s_network.id
}

# Firewall rules
resource "google_compute_firewall" "k8s_internal" {
  name    = "k8s-internal"
  network = google_compute_network.k8s_network.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/24"]
}

resource "google_compute_firewall" "k8s_ssh" {
  name    = "k8s-ssh"
  network = google_compute_network.k8s_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "k8s_api" {
  name    = "k8s-api"
  network = google_compute_network.k8s_network.name

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  target_tags   = ["master"]
  source_ranges = ["0.0.0.0/0"]
}

# Master node
resource "google_compute_instance" "master" {
  name         = "k8s-master"
  machine_type = "n2-standard-2"
  zone         = "${var.region}-a"
  tags         = ["master"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.k8s_subnet.self_link
    access_config {} # Ephemeral public IP
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_pub_key_path)}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl",
      "sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update",
      "sudo apt-get install -y kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl",
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^/#/' /etc/fstab",
      "sudo modprobe br_netfilter",
      "echo '1' | sudo tee /proc/sys/net/ipv4/ip_forward",
      "sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=${google_compute_instance.master.network_interface.0.network_ip}",
      "mkdir -p $HOME/.kube",
      "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml",
      "sudo apt-get install -y git",
      "git clone https://github.com/${var.github_username}/${var.github_repo}.git /tmp/k8s-demo",
      "kubectl apply -f /tmp/k8s-demo/${var.github_manifest_path}"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = file(var.ssh_priv_key_path)
    }
  }
}

# Worker node
resource "google_compute_instance" "worker" {
  name         = "k8s-worker"
  machine_type = "n2-standard-2"
  zone         = "${var.region}-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.k8s_subnet.self_link
    access_config {} # Ephemeral public IP
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_pub_key_path)}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl",
      "sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update",
      "sudo apt-get install -y kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl",
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^/#/' /etc/fstab",
      "sudo modprobe br_netfilter",
      "echo '1' | sudo tee /proc/sys/net/ipv4/ip_forward"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = file(var.ssh_priv_key_path)
    }
  }

  provisioner "remote-exec" {
    inline = [
      "until curl -k https://${google_compute_instance.master.network_interface.0.network_ip}:6443; do sleep 5; done",
      "sudo kubeadm join ${google_compute_instance.master.network_interface.0.network_ip}:6443 --token ${local.join_token} --discovery-token-ca-cert-hash ${local.discovery_token_ca_cert_hash}"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = file(var.ssh_priv_key_path)
    }
  }

  depends_on = [google_compute_instance.master]
}

# Get join token and cert hash from master
data "external" "join_info" {
  program = ["bash", "-c", <<EOT
    ssh -i ${var.ssh_priv_key_path} -o StrictHostKeyChecking=no ${var.ssh_user}@${google_compute_instance.master.network_interface.0.access_config.0.nat_ip} \
    "kubeadm token create --print-join-command" | awk '{print \"{\\\"token\\\": \\\"\" $3 \"\\\", \\\"hash\\\": \\\"\" $5 \"\\\"}\"}' | jq .
  EOT
  ]
}

locals {
  join_token                  = data.external.join_info.result.token
  discovery_token_ca_cert_hash = data.external.join_info.result.hash
}

# Variables
variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region to deploy to"
  type        = string
  default     = "us-central1"
}

variable "ssh_user" {
  description = "SSH user name"
  type        = string
  default     = "ubuntu"
}

variable "ssh_pub_key_path" {
  description = "Absolute path to the public SSH key"
  type        = string
  default     = "/home/nandlalkamat5/.ssh/id_rsa.pub"  # CHANGE THIS TO YOUR ACTUAL PATH
}

variable "ssh_priv_key_path" {
  description = "Absolute path to the private SSH key"
  type        = string
  default     = "/home/nandlalkamat5/.ssh/id_rsa"      # CHANGE THIS TO YOUR ACTUAL PATH
}

variable "github_username" {
  description = "GitHub username or organization name"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "github_manifest_path" {
  description = "Path to the demo.yml file in the repository"
  type        = string
  default     = "demo.yml"
}

variable "github_branch" {
  description = "GitHub branch name"
  type        = string
  default     = "main"
}

output "master_public_ip" {
  value = google_compute_instance.master.network_interface.0.access_config.0.nat_ip
}

output "worker_public_ip" {
  value = google_compute_instance.worker.network_interface.0.access_config.0.nat_ip
}

output "kubeconfig_command" {
  value = "ssh -i ${var.ssh_priv_key_path} ${var.ssh_user}@${google_compute_instance.master.network_interface.0.access_config.0.nat_ip} 'cat ~/.kube/config' > kubeconfig.yaml"
}
