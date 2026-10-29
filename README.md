# circuit-velociraptor

A Conn3x circuit that runs [Velociraptor](https://github.com/Velocidex/velociraptor), the open-source endpoint visibility and DFIR tool from Rapid7's Velocidex team. One host runs the server and its GUI. Every other host runs the client as a systemd service, which connects back, enrolls, and waits for questions. Then, when something looks wrong at 2am, you ask all of them at once — which processes are listening, who logged in, what changed in `/etc` — instead of SSHing into each box with a notepad.

The circuit downloads a pinned release binary from GitHub, checks its SHA-256, and installs it on both roles. On the server it generates the config on the first apply, so the CA's private key and the server's keys are made on that host and never leave it. It then derives the client config there, hands it to the clients, and creates an admin user for the GUI from a password that stays out of the plan and state.

If you know [DetectionLab](https://github.com/clong/DetectionLab), this is the Velociraptor part of its Linux side, as a module you can point at real hosts.

## Usage

```hcl
variable "velociraptor_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "velociraptor_client_nonce" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "velociraptor" {
  source = "github.com/conn3xorg/circuit-velociraptor?ref=v0.1.0"

  server               = { dfir = "203.0.113.10" }
  clients              = { web1 = "203.0.113.21", web2 = "203.0.113.22", db1 = "203.0.113.30" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password = var.velociraptor_admin_password
  client_nonce   = var.velociraptor_client_nonce
}
```

Then run `conn3x init` and `conn3x apply`, with the password in `TF_VAR_velociraptor_admin_password` and the nonce in `TF_VAR_velociraptor_client_nonce`. Make the nonce once, with `openssl rand -hex 16`, and keep it somewhere safe: every apply needs the same one. A second `conn3x plan` says `No changes.`

Clients reach the server on `https://SERVER_ADDRESS:8000/` unless you set `server_url`. Open port 8000 on the server to them, and to nobody else if you can help it. When the server sits behind NAT, or you'd rather clients use a name, set `server_url = "https://dfir.example.com:8000/"`; the trailing slash matters to Velociraptor.

A new client shows up in the GUI a minute or two after its first apply, once the server has finished asking it about itself.

To try it on a throwaway container first, see [examples/local](examples/local).

### The GUI

The GUI listens on `127.0.0.1:8889`, over HTTPS with a certificate the server made for itself. That keeps it off the network: reach it through an SSH tunnel, or put a proxy on the same host in front of it.

```sh
ssh -L 8889:127.0.0.1:8889 root@203.0.113.10
```

Then browse to `https://127.0.0.1:8889/` and sign in as `admin`. Your browser will warn about the certificate, since nothing it trusts signed it. A proxy such as Caddy has to be told the same thing: proxy to `https://127.0.0.1:8889` and skip verifying the upstream certificate. To listen on the network directly, set `gui_address = "0.0.0.0"`.

### What stays on the server, and what reaches state

The server's config holds the CA private key, the frontend's key, and the GUI's TLS key. `velociraptor config generate` makes all three on the server on the first apply, and they never leave it: not in the plan, not in state. A later apply never regenerates them, since a new CA would cut off every client that trusts the old one. Ports, addresses and the server URL are merged into that config on every change, without touching the keys.

The client config is the awkward part. It has to travel from the server, where it's made, to every client, and Conn3x carries a value from one host to another through a command step's output, which it keeps in state in plain text. Velociraptor's client config holds three things that matter: the server URL, the CA certificate, and a nonce. The first two are public. The nonce isn't. Velociraptor's docs call it a shared secret: the server refuses clients whose nonce doesn't match, so anyone who has it, and can reach port 8000, can enroll a client of their own.

So the nonce doesn't come from the server. You pass it in `client_nonce`, an ephemeral variable. The circuit writes it to the server, merges it into the server's config there, and strips it from the client config before that config is printed and kept in state. Each client gets it back in a write-only file. What ends up in state is the server URL and the CA certificate, which every client holds anyway.

The cost is one more value you have to keep and pass on every run. The nonce does still sit in `/etc/velociraptor/client.config.yaml` on every client, readable only by root, because that's where Velociraptor reads it from. A root on any client can read it, which is how Velociraptor works everywhere.

### The admin password

`admin_password` reaches the server as a root-owned file the server can read, `/etc/velociraptor/admin_password`. The circuit then asks the running server, through its local API, to create the user with that file as the password, so the password is never on a command line either. Change `admin_password` and the next apply sets the new one.

The circuit also makes an API client certificate called `conn3x`, with the administrator role, in `/etc/velociraptor/api.config.yaml`, readable by root only. Conn3x uses it to create the admin. You can use it too:

```sh
velociraptor --api_config /etc/velociraptor/api.config.yaml query "SELECT client_id, os_info.hostname FROM clients()"
```

### The server as a client too

To watch the server itself, list its address again under `clients`, with another name. The two roles share the binary and `/etc/velociraptor`, and run as separate services.

```hcl
server  = { dfir = "203.0.113.10" }
clients = { dfir_self = "203.0.113.10", web1 = "203.0.113.21" }
```

### Hosts created in the same plan

Pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry.

```hcl
clients = {
  for name, d in digitalocean_droplet.web : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

## What it does

On the server, in order:

1. Installs `curl` and `gzip`, creates a `velociraptor` system user, and makes `/etc/velociraptor` and the datastore, `/var/lib/velociraptor`.
2. Downloads the release binary for the host's architecture to `/opt/velociraptor`, checks its SHA-256, unpacks it to `/usr/local/bin/velociraptor-VERSION`, and points `/usr/local/bin/velociraptor` at it.
3. On the first apply only, generates `/etc/velociraptor/server.config.yaml`, with new keys.
4. Writes `/etc/velociraptor/settings.json` with the circuit's settings and `/etc/velociraptor/nonce` with the nonce, then merges both into the server config whenever either changes. The settings are the server URL, the frontend and GUI addresses and ports, self-signed mode for clients, and the datastore path.
5. Prints the client config, minus the nonce, for the clients.
6. Makes the `conn3x` API client certificate, once.
7. Writes `velociraptor_server.service`, which runs `velociraptor frontend` as the `velociraptor` user, and restarts it when the binary, config or unit changes. Starts it now and at boot, and waits for its API to answer.
8. Writes the admin password file and creates or updates the admin user.

On each client:

1. Installs `gzip`, then downloads, checks and unpacks the same binary, as on the server.
2. Writes `/etc/velociraptor/client.config.yaml`, write-only, mode `0600`.
3. Writes `velociraptor_client.service`, which runs `velociraptor client` as root, starts it now and at boot, and restarts it when the binary, config or unit changes.

The client keeps its own identity in `/etc/velociraptor.writeback.yaml`, Velociraptor's default. Delete that file and the client enrolls again as a new client.

Before either circuit runs, the `conn3x_host` data source reads each host's architecture over SSH, which picks the binary.

### What it doesn't do

- It doesn't open firewall ports. Clients need port 8000 on the server; nothing else needs to be open. [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) can do it.
- It doesn't set up single sign-on or Let's Encrypt for the GUI. Both are in Velociraptor's config, and both want a public name.
- It doesn't run more than one server, or add orgs.
- It doesn't install clients on Windows or macOS. The client config those need is the same one; print it on the server with `velociraptor --config /etc/velociraptor/server.config.yaml config client`.
- Deleting a client from `clients` leaves Velociraptor installed and running on it, still reporting in. Deleting the module leaves everything as it was.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `server` | any | Required | The server, as a map of one name to an address, such as `{ dfir = "203.0.113.10" }`, or to a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. |
| `clients` | any | `{}` | Clients, by name, in the same form as `server`. A name can't be both. |
| `admin_password` | string | Required | Password of the GUI's admin user, at least 8 characters. Ephemeral and sensitive: it never reaches the plan or state. Changing it sets the new one. |
| `client_nonce` | string | Required | Shared secret clients present to the server, at least 8 of letters, digits, `+`, `/`, `=`, `_` and `-`, such as the output of `openssl rand -hex 16`. Ephemeral and sensitive. Keep it the same for the life of the deployment: changing it turns away every client the circuit doesn't manage. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `velociraptor_version` | string | `"0.77.3"` | Velociraptor release to install, without the leading `v`. |
| `checksums` | map(string) | 0.77.3's | SHA-256 of the gzipped Linux binary, `velociraptor-vVERSION-linux-amd64.gz` or `-arm64.gz`, for `x86_64` and `aarch64`, from the release page. Change these with `velociraptor_version`. |
| `server_url` | string | `null` | URL clients reach the server on, such as `"https://dfir.example.com:8000/"`, with the trailing slash. When null, `https://SERVER_ADDRESS:FRONTEND_PORT/`. |
| `frontend_address` | string | `"0.0.0.0"` | Address the server listens on for clients. |
| `frontend_port` | number | `8000` | Port the server listens on for clients. |
| `gui_address` | string | `"127.0.0.1"` | Address the GUI listens on. |
| `gui_port` | number | `8889` | Port of the GUI. |
| `admin_username` | string | `"admin"` | Name of the GUI user the circuit creates, with the administrator role. It can't be `conn3x`. |

## Outputs

| Name | Description |
| --- | --- |
| `server_url` | URL the clients reach the server on, such as `https://203.0.113.10:8000/`. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, on x86_64 or aarch64, with GitHub reachable for the download.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local), a server and a client on one host, to each on amd64, and checks that the second plan has no changes, that the admin signs in to the GUI's API and a wrong password is refused, and that the client enrolls and appears in the server's `clients()` under the host's name. It then changes the admin password with a second apply, checks the new one works and the old one doesn't, and checks state holds neither the password, the nonce nor any private key. A second job runs the server on Ubuntu 24.04 and a client on Rocky Linux 10 in two containers, and checks the client enrolls across the network.

By hand, on DigitalOcean droplets: a Rocky Linux 10 server with SELinux enforcing, which also ran a client, and an Ubuntu 24.04 client. Both clients enrolled, the GUI took the admin's password, and on the Rocky Linux droplet both services ran as `unconfined_service_t` with no denials in the audit log. After rebooting both droplets, the plan had no changes and both clients were back in the server's list.

## License

MPL-2.0. See [LICENSE](LICENSE). Velociraptor itself is AGPL-3.0.
