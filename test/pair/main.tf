# A server and a client in two containers that up.sh started on ports 2292
# and 2295. The client reaches the server on its container address, which
# CI passes as server_ip.
variable "server_ip" {
  type = string
}

module "velociraptor" {
  source = "../.."

  server               = { server = { address = "127.0.0.1", port = 2292 } }
  clients              = { client = { address = "127.0.0.1", port = 2295 } }
  server_url           = "https://${var.server_ip}:8000/"
  admin_password       = "ci-only-admin-pass"
  client_nonce         = "ci-only-nonce"
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}
