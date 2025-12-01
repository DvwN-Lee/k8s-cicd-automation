# CloudStack API 설정
variable "cloudstack_api_url" {
  description = "CloudStack API endpoint URL"
  type        = string
}

variable "cloudstack_api_key" {
  description = "CloudStack API key"
  type        = string
  sensitive   = true
}

variable "cloudstack_secret_key" {
  description = "CloudStack secret key"
  type        = string
  sensitive   = true
}

# Zone 설정
variable "zone_name" {
  description = "CloudStack zone name"
  type        = string
  default     = "DKU"
}

# Network 설정
variable "network_name" {
  description = "Isolated network name"
  type        = string
  default     = "k8s-network"
}

variable "network_offering" {
  description = "Network offering name"
  type        = string
  default     = "DefaultIsolatedNetworkOfferingWithSourceNatService"
}

variable "network_cidr" {
  description = "Network CIDR"
  type        = string
  default     = "192.168.0.0/24"
}

variable "network_gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.0.1"
}

# VM 설정
variable "template_name" {
  description = "VM template name"
  type        = string
  default     = "Ubuntu 24.04 LTS"
}

variable "master_offering" {
  description = "Service offering for master node"
  type        = string
  default     = "Medium"  # 2 CPU, 4GB RAM - Control Plane 전용
}

variable "worker_offerings" {
  description = "Service offering for each worker node"
  type        = list(string)
  default     = ["Large", "Medium"]  # w1: 4CPU/8GB (GitLab), w2: 2CPU/4GB
}

variable "disk_offering" {
  description = "Disk offering name"
  type        = string
  default     = "Custom"
}

variable "root_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 20
}

# SSH Key
variable "ssh_key_name" {
  description = "SSH key pair name"
  type        = string
  default     = "k8s-key"
}

variable "ssh_public_key" {
  description = "SSH public key content"
  type        = string
}

# VM 이름
variable "master_name" {
  description = "Master node name"
  type        = string
  default     = "k8s-m"
}

variable "worker_names" {
  description = "Worker node names"
  type        = list(string)
  default     = ["k8s-w1", "k8s-w2"]
}
