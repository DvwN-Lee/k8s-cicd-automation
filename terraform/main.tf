# Data sources
data "cloudstack_zone" "zone" {
  filter {
    name  = "name"
    value = var.zone_name
  }
}

# SSH Key Pair
resource "cloudstack_ssh_keypair" "k8s_key" {
  name       = var.ssh_key_name
  public_key = var.ssh_public_key
}

# Isolated Network
resource "cloudstack_network" "k8s_network" {
  name             = var.network_name
  display_text     = "Kubernetes Cluster Network"
  cidr             = var.network_cidr
  gateway          = var.network_gateway
  network_offering = var.network_offering
  zone             = data.cloudstack_zone.zone.name
}

# Egress rule to allow all outbound traffic
resource "cloudstack_egress_firewall" "allow_all_outbound" {
  network_id = cloudstack_network.k8s_network.id

  rule {
    cidr_list = ["0.0.0.0/0"]
    protocol  = "all"
  }
}

# Master Node (Medium: 2 CPU, 4GB RAM - Control Plane 전용)
resource "cloudstack_instance" "master" {
  name             = var.master_name
  display_name     = var.master_name
  service_offering = var.master_offering
  template         = var.template_name
  zone             = data.cloudstack_zone.zone.name
  network_id       = cloudstack_network.k8s_network.id
  keypair          = cloudstack_ssh_keypair.k8s_key.name
  root_disk_size   = var.root_disk_size

  depends_on = [cloudstack_network.k8s_network]
}

# Worker Nodes (w1: Large 4CPU/8GB for GitLab, w2: Medium 2CPU/4GB)
resource "cloudstack_instance" "workers" {
  count = length(var.worker_names)

  name             = var.worker_names[count.index]
  display_name     = var.worker_names[count.index]
  service_offering = var.worker_offerings[count.index]
  template         = var.template_name
  zone             = data.cloudstack_zone.zone.name
  network_id       = cloudstack_network.k8s_network.id
  keypair          = cloudstack_ssh_keypair.k8s_key.name
  root_disk_size   = var.root_disk_size

  depends_on = [cloudstack_network.k8s_network]
}

# Public IP for Port Forwarding
resource "cloudstack_ipaddress" "public_ip" {
  network_id = cloudstack_network.k8s_network.id
  zone       = data.cloudstack_zone.zone.name
}

# Firewall Rules for Public IP
# Note: 모든 방화벽 규칙(2222, 6443, 30080, 30022, 30880, 30500, 30800)은
# CloudStack 콘솔에서 직접 관리됨 (Terraform import 미지원으로 인해)

# Port Forwarding Rules

# SSH to Master (2222 -> 22)
resource "cloudstack_port_forward" "ssh_master" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 22
    public_port        = 2222
    virtual_machine_id = cloudstack_instance.master.id
  }

}

# Jenkins (30880 NodePort on Worker 1)
resource "cloudstack_port_forward" "jenkins" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 30880
    public_port        = 30880
    virtual_machine_id = cloudstack_instance.workers[0].id
  }

}

# GitLab HTTP (30080 NodePort on Worker 1)
resource "cloudstack_port_forward" "gitlab_http" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 30080
    public_port        = 30080
    virtual_machine_id = cloudstack_instance.workers[0].id
  }

}

# GitLab SSH (30022 NodePort on Worker 1)
resource "cloudstack_port_forward" "gitlab_ssh" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 30022
    public_port        = 30022
    virtual_machine_id = cloudstack_instance.workers[0].id
  }

}

# Docker Registry (30500 NodePort on Worker 1)
resource "cloudstack_port_forward" "registry" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 30500
    public_port        = 30500
    virtual_machine_id = cloudstack_instance.workers[0].id
  }

}

# Kubernetes API (6443)
resource "cloudstack_port_forward" "k8s_api" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 6443
    public_port        = 6443
    virtual_machine_id = cloudstack_instance.master.id
  }

}

# TestApp (30800 NodePort on Worker 2 - App Node)
resource "cloudstack_port_forward" "testapp" {
  ip_address_id = cloudstack_ipaddress.public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 30800
    public_port        = 30800
    virtual_machine_id = cloudstack_instance.workers[1].id
  }

}
