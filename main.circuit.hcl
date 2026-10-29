# Facts give each host's architecture, which picks the release binary.
data "conn3x_host" "facts" {
  for_each = merge(var.server, var.clients)

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = contains(keys(var.checksums), self.arch)
      error_message = "Host ${each.key} is ${self.arch}. The circuit has Velociraptor builds for ${join(" and ", keys(var.checksums))}."
    }
  }
}

locals {
  server_name    = keys(var.server)[0]
  server_address = try(var.server[local.server_name].address, var.server[local.server_name])
  server_url = coalesce(var.server_url, format("https://%s:%d/",
    strcontains(local.server_address, ":") ? "[${local.server_address}]" : local.server_address,
  var.frontend_port))

  etc     = "/etc/velociraptor"
  config  = "${local.etc}/server.config.yaml"
  api     = "${local.etc}/api.config.yaml"
  home    = "/var/lib/velociraptor"
  release = { x86_64 = "amd64", aarch64 = "arm64" }
  gz      = { for name, f in data.conn3x_host.facts : name => "/opt/velociraptor/velociraptor-v${var.velociraptor_version}-linux-${local.release[f.arch]}.gz" }
  url     = { for name, f in data.conn3x_host.facts : name => "https://github.com/Velocidex/velociraptor/releases/download/v${var.velociraptor_version}/velociraptor-v${var.velociraptor_version}-linux-${local.release[f.arch]}.gz" }
  sha256  = { for name, f in data.conn3x_host.facts : name => var.checksums[f.arch] }
  binary  = "/usr/local/bin/velociraptor-${var.velociraptor_version}"
  unpack  = "gzip -dc %s > ${local.binary}.new && chmod 755 ${local.binary}.new && mv ${local.binary}.new ${local.binary}"

  # The settings the circuit owns, merged into the generated config on
  # every change. Nothing secret is in here, so it's fine in state.
  # use_self_signed_ssl makes clients check the server against the CA in
  # their config rather than the system's roots.
  settings = {
    Client = {
      server_urls         = [local.server_url]
      use_self_signed_ssl = true
    }
    Frontend = {
      bind_address = var.frontend_address
      bind_port    = var.frontend_port
    }
    GUI = {
      bind_address = var.gui_address
      bind_port    = var.gui_port
    }
    Datastore = {
      location            = local.home
      filestore_directory = local.home
    }
  }

  # The server's client config, minus the nonce, which the server step
  # below drops before printing it. Each client gets it back from
  # client_nonce, in a write-only file.
  client_base = yamldecode(conn3x_command.velociraptor_server__client_config[local.server_name].stdout)
}

circuit "velociraptor_server" {
  hosts = var.server

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack either. The release binary is gzipped.
  step "tools" {
    for_each = toset(["curl", "gzip"])
    package {
      name = item.value
    }
  }

  step "user" {
    user {
      name   = "velociraptor"
      system = true
      home   = local.home
      shell  = "/usr/sbin/nologin"
    }
  }

  # Shared with the client on a host that runs both, so the two circuits
  # must agree on it. The files inside carry their own permissions.
  step "etc" {
    directory {
      path = local.etc
      mode = "0755"
    }
  }

  step "datastore" {
    directory {
      path  = local.home
      owner = "velociraptor"
      group = "velociraptor"
      mode  = "0750"
    }
  }

  step "release_dir" {
    directory {
      path = "/opt/velociraptor"
    }
  }

  step "download" {
    download {
      url    = local.url[each.key]
      sha256 = local.sha256[each.key]
      dest   = local.gz[each.key]
    }
  }

  step "unpack" {
    command {
      command = format(local.unpack, local.gz[each.key])
      creates = local.binary
    }
  }

  step "link" {
    link {
      path   = "/usr/local/bin/velociraptor"
      target = local.binary
    }
  }

  # The CA key, the server's keys and the GUI's TLS key are made here, on
  # the host, and never leave it. creates keeps them for good: a new CA
  # would cut off every client that trusts the old one.
  step "generate" {
    command {
      command = "umask 027 && velociraptor config generate > ${local.config}.new && chgrp velociraptor ${local.config}.new && mv ${local.config}.new ${local.config}"
      creates = local.config
    }
  }

  step "settings" {
    file {
      path    = "${local.etc}/settings.json"
      content = jsonencode(local.settings)
    }
  }

  # Write-only: the plan and state record only an HMAC of the nonce.
  step "nonce" {
    file {
      path       = "${local.etc}/nonce"
      content_wo = var.client_nonce
      mode       = "0600"
    }
  }

  # Merges the settings, then the nonce, into the config. printf is a
  # shell builtin, so the nonce never shows up in a process list.
  step "merge" {
    command {
      command = join(" && ", [
        "cd ${local.etc}",
        "umask 077",
        "printf '{\"Client\":{\"nonce\":\"%s\"}}' \"$(cat nonce)\" > nonce.json",
        "velociraptor --config server.config.yaml config show --merge_file settings.json > server.config.yaml.a",
        "velociraptor --config server.config.yaml.a config show --merge_file nonce.json > server.config.yaml.new",
        "rm -f nonce.json server.config.yaml.a",
        "chgrp velociraptor server.config.yaml.new",
        "chmod 640 server.config.yaml.new",
        "mv server.config.yaml.new server.config.yaml",
      ])
      triggers = {
        generate = conn3x_command.velociraptor_server__generate[each.key].revision
        settings = conn3x_file.velociraptor_server__settings[each.key].revision
        nonce    = conn3x_file.velociraptor_server__nonce[each.key].revision
      }
    }
  }

  # Prints the client config for the clients below, without the nonce:
  # this step's output is kept in state. What's left is the server URL
  # and the CA certificate, neither of them secret.
  step "client_config" {
    command {
      command  = "velociraptor --config ${local.config} config client | grep -v '^  nonce: '"
      triggers = { merge = conn3x_command.velociraptor_server__merge[each.key].revision }
    }
  }

  # An API client certificate for the steps below, made as the
  # velociraptor user so the ACL it writes in the datastore stays the
  # server's. The certificate's key is root's alone.
  step "api_client" {
    command {
      command = "runuser -u velociraptor -- velociraptor --config ${local.config} config api_client --name conn3x --role administrator ${local.home}/api.config.yaml && install -m 600 ${local.home}/api.config.yaml ${local.api} && rm -f ${local.home}/api.config.yaml"
      creates = local.api
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/velociraptor_server.service"
      content = <<-EOT
        [Unit]
        Description=Velociraptor server
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=velociraptor
        Group=velociraptor
        Environment=HOME=${local.home}
        ExecStart=/usr/local/bin/velociraptor --config ${local.config} frontend
        Restart=always
        RestartSec=10
        LimitNOFILE=20000
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # A step rather than a handler, so the checks below talk to the server
  # that runs the new binary and config. On a first apply it's what starts
  # the server. The velociraptor commands above run as root and can leave
  # root's files in the datastore, which the server then can't open.
  step "restart" {
    command {
      command = "chown -R velociraptor:velociraptor ${local.home} && systemctl daemon-reload && systemctl restart velociraptor_server"
      triggers = {
        binary = conn3x_link.velociraptor_server__link[each.key].revision
        config = conn3x_command.velociraptor_server__merge[each.key].revision
        unit   = conn3x_file.velociraptor_server__unit[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "velociraptor_server"
      state   = "started"
      enabled = true
    }
  }

  # unless is checked at plan time, before the restart, so the restart's
  # revision makes the apply check again.
  step "ready" {
    command {
      command  = "for _ in $(seq 60); do velociraptor --api_config ${local.api} query 'SELECT 1 FROM scope()' >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"
      unless   = "velociraptor --api_config ${local.api} query 'SELECT 1 FROM scope()' >/dev/null 2>&1"
      triggers = { restart = conn3x_command.velociraptor_server__restart[each.key].revision }
    }
  }

  # Write-only, like the nonce. The server reads it as the velociraptor
  # user when it sets the password.
  step "admin_password" {
    file {
      path       = "${local.etc}/admin_password"
      content_wo = var.admin_password
      owner      = "root"
      group      = "velociraptor"
      mode       = "0640"
    }
  }

  # user_create only works through a running server, and reads the
  # password from its file there, so it never appears on a command line.
  # It returns null rather than failing, hence the grep.
  step "admin" {
    command {
      command = "velociraptor --api_config ${local.api} query \"SELECT user_create(user='${var.admin_username}', roles='administrator', password=read_file(filename='${local.etc}/admin_password')) AS user FROM scope()\" | grep -q '\"user\": \"${var.admin_username}\"'"
      triggers = {
        user     = var.admin_username
        password = conn3x_file.velociraptor_server__admin_password[each.key].revision
      }
    }
  }
}

circuit "velociraptor_clients" {
  hosts = var.clients

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # After the server's binary is in place, since a host can run both and
  # the two circuits would otherwise unpack the same file at once.
  step "tools" {
    package {
      name = "gzip"
    }
    depends_on = [conn3x_link.velociraptor_server__link]
  }

  step "etc" {
    directory {
      path = local.etc
      mode = "0755"
    }
  }

  step "release_dir" {
    directory {
      path = "/opt/velociraptor"
    }
  }

  step "download" {
    download {
      url    = local.url[each.key]
      sha256 = local.sha256[each.key]
      dest   = local.gz[each.key]
    }
  }

  step "unpack" {
    command {
      command = format(local.unpack, local.gz[each.key])
      creates = local.binary
    }
  }

  step "link" {
    link {
      path   = "/usr/local/bin/velociraptor"
      target = local.binary
    }
    notify = [handler.restart]
  }

  # The nonce makes this file a shared secret, so it's write-only.
  step "config" {
    file {
      path       = "${local.etc}/client.config.yaml"
      content_wo = yamlencode(merge(local.client_base, { Client = merge(local.client_base.Client, { nonce = var.client_nonce }) }))
      mode       = "0600"
    }
    notify = [handler.restart]
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/velociraptor_client.service"
      content = <<-EOT
        [Unit]
        Description=Velociraptor client
        After=network-online.target
        Wants=network-online.target

        [Service]
        ExecStart=/usr/local/bin/velociraptor --config ${local.etc}/client.config.yaml client --quiet
        Restart=always
        RestartSec=10
        LimitNOFILE=20000

        [Install]
        WantedBy=multi-user.target
      EOT
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "velociraptor_client"
      state   = "started"
      enabled = true
    }
  }

  handler "restart" {
    service {
      name = "velociraptor_client"
    }
  }
}
