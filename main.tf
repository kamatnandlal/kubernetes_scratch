provider "google" {
  project = var.project_id
  region  = var.region
}

# Generate SSH key pair
resource "tls_private_key" "k8s_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save private key locally
resource "local_file" "private_key" {
  content         = tls_private_key.k8s_ssh.private_key_openssh
  filename        = "${path.module}/k8s_ssh_key"
  file_permission = "0600"
}

# Save public key locally
resource "local_file" "public_key" {
  content         = tls_private_key.k8s_ssh.public_key_openssh
  filename        = "${path.module}/k8s_ssh_key.pub"
  file_permission = "0644"
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
    ssh-keys = "${var.ssh_user}:${tls_private_key.k8s_ssh.public_key_openssh}"
  }

  provisioner "remote-exec" {
    inline = [
      # System preparation
      "sudo apt-get update -y",
      "sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release jq",
      
      # Configure container runtime (containerd)
      "sudo mkdir -p /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get update -y",
      "sudo apt-get install -y containerd.io",
      "sudo mkdir -p /etc/containerd",
      "sudo containerd config default | sudo tee /etc/containerd/config.toml",
      "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",
      "sudo systemctl restart containerd",
      
      # Install Kubernetes components
      "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
      "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update -y",
      "sudo apt-get install -y kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl",
      
      # Configure system for Kubernetes
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^/#/' /etc/fstab",
      "sudo modprobe br_netfilter",
      "echo '1' | sudo tee /proc/sys/net/ipv4/ip_forward",
      "echo 'br_netfilter' | sudo tee /etc/modules-load.d/k8s.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/k8s.conf",
      "sudo sysctl --system",
      
      # Initialize cluster with kubelet workaround
      "sudo systemctl daemon-reload",
      "sudo systemctl enable kubelet",
      "sudo systemctl start kubelet || echo 'Kubelet start failed (may be normal during initialization)'",
      
      # Initialize cluster with retry
      "max_retries=5",
      "count=0",
      "until sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=${google_compute_instance.master.network_interface.0.network_ip} --ignore-preflight-errors=all && break || [ $count -eq $max_retries ]; do",
      "  echo 'Cluster initialization attempt $((count+1)) failed. Retrying in 30 seconds...'",
      "  sleep 30",
      "  sudo systemctl restart kubelet",
      "  count=$((count+1))",
      "done",
      
      # Configure kubectl properly
      "mkdir -p $HOME/.kube",
      "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      "echo 'export KUBECONFIG=$HOME/.kube/config' >> $HOME/.bashrc",
      "source $HOME/.bashrc",
      
      # Install network plugin
      "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml",
      
      # Verify node status
      "until kubectl get nodes | grep -q 'Ready'; do sleep 5; done",
      
      # Create join command file
      "kubeadm token create --print-join-command > /tmp/join_command.sh",
      "chmod +x /tmp/join_command.sh",
      
      # Clone repo and apply manifests
      "git clone https://github.com/${var.github_username}/${var.github_repo}.git /tmp/k8s-demo || echo 'Git clone failed (non-critical)'",
      "kubectl apply -f /tmp/k8s-demo/${var.github_manifest_path} || echo 'Manifest apply failed (non-critical)'"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = tls_private_key.k8s_ssh.private_key_openssh
      timeout     = "20m"
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
    ssh-keys = "${var.ssh_user}:${tls_private_key.k8s_ssh.public_key_openssh}"
  }

  provisioner "remote-exec" {
    inline = [
      # System preparation (including jq)
      "sudo apt-get update -y",
      "sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release jq",
      
      # Configure container runtime
      "sudo mkdir -p /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get update -y",
      "sudo apt-get install -y containerd.io",
      "sudo mkdir -p /etc/containerd",
      "sudo containerd config default | sudo tee /etc/containerd/config.toml",
      "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",
      "sudo systemctl restart containerd",
      
      # Install Kubernetes components
      "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
      "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update -y",
      "sudo apt-get install -y kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl",
      
      # Configure system for Kubernetes
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^/#/' /etc/fstab",
      "sudo modprobe br_netfilter",
      "echo '1' | sudo tee /proc/sys/net/ipv4/ip_forward",
      "echo 'br_netfilter' | sudo tee /etc/modules-load.d/k8s.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/k8s.conf",
      "sudo sysctl --system",
      
      # Prepare kubelet
      "sudo systemctl daemon-reload",
      "sudo systemctl enable kubelet",
      "sudo systemctl start kubelet || echo 'Kubelet start failed (may be normal during initialization)'"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = tls_private_key.k8s_ssh.private_key_openssh
      timeout     = "15m"
    }
  }

  # Worker join command
  provisioner "remote-exec" {
    inline = [
      # Wait for master API to be ready
      "until nc -zv ${google_compute_instance.master.network_interface.0.network_ip} 6443; do sleep 10; done",
      
      # Copy join command from master
      "ssh -i /tmp/k8s_ssh_key -o StrictHostKeyChecking=no ${var.ssh_user}@${google_compute_instance.master.network_interface.0.access_config.0.nat_ip} 'cat /tmp/join_command.sh' > /tmp/join_command.sh",
      "chmod +x /tmp/join_command.sh",
      
      # Join cluster with retry
      "max_retries=5",
      "count=0",
      "until sudo /tmp/join_command.sh --ignore-preflight-errors=all && break || [ $count -eq $max_retries ]; do",
      "  echo 'Join attempt $((count+1)) failed. Retrying in 30 seconds...'",
      "  sleep 30",
      "  sudo systemctl restart kubelet",
      "  count=$((count+1))",
      "done"
    ]

    connection {
      type        = "ssh"
      host        = self.network_interface[0].access_config[0].nat_ip
      user        = var.ssh_user
      private_key = tls_private_key.k8s_ssh.private_key_openssh
      timeout     = "15m"
    }
  }

  depends_on = [google_compute_instance.master]
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
  value       = google_compute_instance.master.network_interface.0.access_config.0.nat_ip
  description = "Public IP address of the master node"
}

output "worker_public_ip" {
  value       = google_compute_instance.worker.network_interface.0.access_config.0.nat_ip
  description = "Public IP address of the worker node"
}

output "kubeconfig_command" {
  value       = "ssh -i ${path.module}/k8s_ssh_key ${var.ssh_user}@${google_compute_instance.master.network_interface.0.access_config.0.nat_ip} 'cat ~/.kube/config' > kubeconfig.yaml"
  description = "Command to retrieve kubeconfig"
}

output "ssh_key_path" {
  value       = "${path.module}/k8s_ssh_key"
  description = "Path to the generated SSH private key"
}

output "ssh_public_key" {
  value       = tls_private_key.k8s_ssh.public_key_openssh
  description = "SSH public key for accessing nodes"
}
