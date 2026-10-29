variable "server" {
  type        = any
  description = "The host that runs the Velociraptor server and its GUI, as a map of one name to an address, or to a host object with an address and optional host_key, user, port, private_key_file or jump_hosts."

  validation {
    condition     = length(var.server) == 1
    error_message = "Give exactly one server."
  }
}

variable "clients" {
  type        = any
  default     = {}
  description = "Hosts that run the Velociraptor client, by name, in the same form as server. A client can be the server's own address under another name."

  validation {
    condition     = length(setintersection(keys(var.server), keys(var.clients))) == 0
    error_message = "A name can't be both the server and a client. To run the client on the server too, list its address under another name."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "velociraptor_version" {
  type        = string
  default     = "0.77.3"
  description = "Velociraptor release to install, without the leading v."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.velociraptor_version))
    error_message = "velociraptor_version must be a release number such as \"0.77.3\", without the leading v."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the gzipped Linux binary for each architecture, x86_64 and aarch64, from the release page. Change these with velociraptor_version."
  default = {
    x86_64  = "c2c4eb585f16b622cd57de04995a7a13c076ee455bc2a828fd9243cec2ccfed8"
    aarch64 = "f28e097c98bee125bf65adfe64937c9699b4d77742b7ab12f186a065298e72c3"
  }

  validation {
    condition     = alltrue([for a, c in var.checksums : contains(["x86_64", "aarch64"], a) && can(regex("^[0-9a-f]{64}$", c))])
    error_message = "checksums maps x86_64 or aarch64 to a SHA-256 in lowercase hex."
  }
}

variable "server_url" {
  type        = string
  default     = null
  description = "URL clients reach the server on, with the trailing slash, such as \"https://dfir.example.com:8000/\". When null, https://SERVER_ADDRESS:FRONTEND_PORT/."

  validation {
    condition     = var.server_url == null || can(regex("^https://[^\\s/\"]+/$", coalesce(var.server_url, "-")))
    error_message = "server_url must be an https:// URL with a host, an optional port and a trailing slash, such as \"https://203.0.113.10:8000/\"."
  }
}

variable "frontend_address" {
  type        = string
  default     = "0.0.0.0"
  description = "Address the server listens on for clients."

  validation {
    condition     = can(cidrhost("${var.frontend_address}/${strcontains(var.frontend_address, ":") ? 128 : 32}", 0))
    error_message = "frontend_address must be an IP address, such as \"0.0.0.0\"."
  }
}

variable "frontend_port" {
  type        = number
  default     = 8000
  description = "Port the server listens on for clients."

  validation {
    condition     = var.frontend_port >= 1 && var.frontend_port <= 65535 && floor(var.frontend_port) == var.frontend_port
    error_message = "frontend_port must be a port number from 1 to 65535."
  }
}

variable "gui_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the GUI listens on. The default keeps it to the host itself, for a proxy or an SSH tunnel; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.gui_address}/${strcontains(var.gui_address, ":") ? 128 : 32}", 0))
    error_message = "gui_address must be an IP address, such as \"127.0.0.1\"."
  }
}

variable "gui_port" {
  type        = number
  default     = 8889
  description = "Port of the GUI."

  validation {
    condition     = var.gui_port >= 1 && var.gui_port <= 65535 && floor(var.gui_port) == var.gui_port
    error_message = "gui_port must be a port number from 1 to 65535."
  }
}

variable "admin_username" {
  type        = string
  default     = "admin"
  description = "Name of the GUI user the circuit creates with the administrator role."

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,63}$", var.admin_username)) && var.admin_username != "conn3x"
    error_message = "admin_username must start with a letter or digit and use only letters, digits, _, ., @ and -. conn3x is taken by the circuit's API client."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of the admin user, at least 8 characters. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan. Changing it sets the new one."

  validation {
    condition     = length(var.admin_password) >= 8 && !strcontains(var.admin_password, "\n")
    error_message = "admin_password must be at least 8 characters, on one line."
  }
}

variable "client_nonce" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Shared secret every client presents to the server, such as the output of openssl rand -hex 16. Keep it the same for the life of the deployment: a client with another nonce is turned away. It never reaches state or the plan."

  validation {
    condition     = can(regex("^[A-Za-z0-9+/=_-]{8,}$", var.client_nonce))
    error_message = "client_nonce must be at least 8 characters of letters, digits, +, /, =, _ and -."
  }
}
