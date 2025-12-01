terraform {
  required_providers {
    cloudstack = {
      source  = "cloudstack/cloudstack"
      version = "~> 0.5.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "cloudstack" {
  api_url    = var.cloudstack_api_url
  api_key    = var.cloudstack_api_key
  secret_key = var.cloudstack_secret_key
}
