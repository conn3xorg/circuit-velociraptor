# Local example

Applies circuit-velociraptor to a throwaway Rocky Linux 10 container with systemd. The one container runs the server and a client that reports to it, which is enough to see a host turn up in the GUI. You need Conn3x and Podman.

```sh
./up.sh
export TF_VAR_admin_password='pick-a-password'
export TF_VAR_client_nonce="$(openssl rand -hex 16)"
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` Keep the same `TF_VAR_client_nonce` for every run: a new one changes the server's nonce and every client's config.

To open the GUI, forward its port over SSH and browse to `https://127.0.0.1:8889/`, signing in as `admin`. The certificate is the server's own, so the browser warns about it.

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8889:127.0.0.1:8889 root@127.0.0.1
```

The client shows up under the container's hostname within a minute or two. To list clients from the command line instead:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  velociraptor --api_config /etc/velociraptor/api.config.yaml query "'SELECT client_id, os_info.hostname FROM clients()'"
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
