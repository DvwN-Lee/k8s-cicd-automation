# Public IP Address
output "public_ip" {
  description = "Public IP address for accessing services"
  value       = cloudstack_ipaddress.public_ip.ip_address
}

# Master Node Information
output "master_info" {
  description = "Master node information"
  value = {
    name       = cloudstack_instance.master.name
    id         = cloudstack_instance.master.id
    private_ip = cloudstack_instance.master.ip_address
  }
}

# Worker Nodes Information
output "worker_info" {
  description = "Worker nodes information"
  value = [
    for idx, worker in cloudstack_instance.workers : {
      name       = worker.name
      id         = worker.id
      private_ip = worker.ip_address
      role       = idx == 0 ? "devops-node" : "worker-node"
    }
  ]
}

# SSH Connection Commands
output "ssh_commands" {
  description = "SSH connection commands"
  value = {
    master   = "ssh -i ~/.ssh/k8s_key -p 2222 ubuntu@${cloudstack_ipaddress.public_ip.ip_address}"
    worker_1 = "ssh -i ~/.ssh/k8s_key -o ProxyCommand='ssh -i ~/.ssh/k8s_key -p 2222 -W %h:%p ubuntu@${cloudstack_ipaddress.public_ip.ip_address}' ubuntu@${cloudstack_instance.workers[0].ip_address}"
    worker_2 = "ssh -i ~/.ssh/k8s_key -o ProxyCommand='ssh -i ~/.ssh/k8s_key -p 2222 -W %h:%p ubuntu@${cloudstack_ipaddress.public_ip.ip_address}' ubuntu@${cloudstack_instance.workers[1].ip_address}"
  }
}

# Service Access URLs
output "service_urls" {
  description = "Service access URLs"
  value = {
    jenkins  = "http://${cloudstack_ipaddress.public_ip.ip_address}:30880"
    gitlab   = "http://${cloudstack_ipaddress.public_ip.ip_address}:30080"
    registry = "http://${cloudstack_ipaddress.public_ip.ip_address}:30500"
    testapp  = "http://${cloudstack_ipaddress.public_ip.ip_address}:30800"
    k8s_api  = "https://${cloudstack_ipaddress.public_ip.ip_address}:6443"
  }
}

# Ansible Inventory Generation
output "ansible_inventory" {
  description = "Ansible inventory content"
  value = <<-EOT
[masters]
${cloudstack_instance.master.name} ansible_host=${cloudstack_instance.master.ip_address}

[workers]
${cloudstack_instance.workers[0].name} ansible_host=${cloudstack_instance.workers[0].ip_address} node_role=devops-node
${cloudstack_instance.workers[1].name} ansible_host=${cloudstack_instance.workers[1].ip_address} node_role=worker-node

[k8s_cluster:children]
masters
workers

[k8s_cluster:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/k8s_key
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ~/.ssh/k8s_key -p 2222 -W %h:%p -o StrictHostKeyChecking=no ubuntu@${cloudstack_ipaddress.public_ip.ip_address}"'
EOT
}
