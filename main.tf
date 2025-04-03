provider "google" {
  project = var.project_id
  region  = var.region
}

# Create GCS bucket for demo.yml
resource "google_storage_bucket" "k8s_demo_bucket" {
  name          = "${var.project_id}-k8s-demo-bucket"
  location      = var.region
  force_destroy = true
}

# Upload demo.yml to the bucket
resource "google_storage_bucket_object" "demo_manifest" {
  name   = "demo.yml"
  bucket = google_storage_bucket.k8s_demo_bucket.name
  source = var.demo_manifest_path
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

# Firewall rules (previous rules remain the same)
# ... [previous firewall rules remain unchanged] ...

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

    access_config {
      // Ephemeral public IP
    }
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
      # Install Google Cloud SDK to access GCS
      "echo \"deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main\" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list",
      "sudo apt-get install -y apt-transport-https ca-certificates gnupg",
      "curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -",
      "sudo apt-get update && sudo apt-get install -y google-cloud-sdk",
      # Authenticate with the service account
      "echo '${base64decode(google_service_account_key.k8s_key.private_key)}' > /tmp/service-account.json",
      "gcloud auth activate-service-account --key-file=/tmp/service-account.json",
      # Apply demo.yml from GCS
      "gsutil cp gs://${google_storage_bucket.k8s_demo_bucket.name}/demo.yml /tmp/demo.yml",
      "kubectl apply -f /tmp/demo.yml"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = file(var.ssh_priv_key_path)
    }
  }
}

# Worker node (previous worker node configuration remains the same)
# ... [previous worker node configuration remains unchanged] ...

# Service account for accessing GCS
resource "google_service_account" "k8s_service_account" {
  account_id   = "k8s-gcs-access"
  display_name = "Service Account for Kubernetes GCS Access"
}

# Grant storage admin role to the service account
resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.k8s_service_account.email}"
}

# Create service account key
resource "google_service_account_key" "k8s_key" {
  service_account_id = google_service_account.k8s_service_account.name
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
  description = "Path to the public SSH key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_priv_key_path" {
  description = "Path to the private SSH key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "demo_manifest_path" {
  description = "Path to the demo.yml file to be applied to the cluster"
  type        = string
  default     = "./demo.yml"
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

output "demo_manifest_bucket" {
  value = google_storage_bucket.k8s_demo_bucket.name
}
