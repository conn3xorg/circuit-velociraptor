variable "port" {
  type    = number
  default = 2222
}

# Pass both at run time, such as with TF_VAR_admin_password and
# TF_VAR_client_nonce.
variable "admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "client_nonce" {
  type      = string
  ephemeral = true
  sensitive = true
}

# One container runs the server and a client that reports to it, which
# reaches the server on https://127.0.0.1:8000/ inside the container.
module "velociraptor" {
  source = "../.."

  server               = { server = "127.0.0.1" }
  clients              = { client = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  admin_password = var.admin_password
  client_nonce   = var.client_nonce
}

output "server_url" {
  value = module.velociraptor.server_url
}
