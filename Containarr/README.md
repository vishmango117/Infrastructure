# Containarr

Self-hosted download stack: **Seerr** (browse/request movies & TV) → auto-approved
request → **Sonarr/Radarr** search via **Jackett** indexers → torrent handed to
**qBittorrent** → import into the media library. All services are fronted by
**Traefik** at `https://<service>.example.internal`.

```
Containarr/
├── ansible/          # base Ubuntu LTS setup (Docker Engine + user + network)
│   ├── playbook.yml
│   ├── inventory.ini
│   └── requirements.yml
├── arr/              # sonarr, radarr, qbittorrent, jackett, seerr
│   ├── docker-compose.yml
│   └── .env.example
└── proxy/            # traefik reverse proxy + generated routers
    ├── docker-compose.yml
    ├── .env.example
    └── config/{traefik.yml,config.yml,acme.json,certs/}
```

## Configuration model

The compose files are **structure only** — they contain no tunable values. Every
setting comes from the `.env` files (`arr/.env`, `proxy/.env`; copy the shipped
`.env.example`s and adjust). Missing a variable fails loudly at `up` time
(`${VAR:?...}`). Traefik's routing config lives in `proxy/config/` as plain
files (static + templated dynamic) — no Docker socket, no labels.

## 1. Prepare the server (Ansible)

From this machine (needs `ansible-core` installed). Edit `ansible/inventory.ini`
first — it ships with a placeholder address under the `containarr` group:

```bash
ansible-galaxy install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml --ask-become-pass
```

The playbook installs Docker Engine + Compose v2 from the official apt repo,
creates `arruser` (docker group), builds `/opt/containarr/{arr/data/*,media,downloads}`
and creates the external network `arr-net`.

Then copy the stack to the server and activate the env files:

```bash
rsync -a --exclude data ./ <server>:/opt/containarr/
ssh <server>
cp /opt/containarr/arr/.env.example   /opt/containarr/arr/.env
cp /opt/containarr/proxy/.env.example /opt/containarr/proxy/.env
chmod 600 /opt/containarr/proxy/config/acme.json
```

## 2. DNS for `*.example.internal`

`.internal` is a reserved private TLD — it must resolve on your **internal DNS**
(Pi-hole / AdGuard Home / Unbound / dnsmasq), or per-client via `/etc/hosts`:

```
192.0.2.10  sonarr.example.internal radarr.example.internal qbittorrent.example.internal jackett.example.internal seerr.example.internal traefik.example.internal
```

Wildcard (`*.example.internal → server IP`) is preferred.

## 3. Start the stack (on the server)

```bash
cd /opt/containarr/proxy && docker compose up -d   # Traefik first
cd /opt/containarr/arr    && docker compose up -d   # then the arr stack
docker compose logs traefik                         # verify it booted clean
```

## 4. Wire the services together (one-time UI setup)

1. **qBittorrent** — `docker logs qbittorrent` prints a temporary admin password;
   log in at `https://qbittorrent.example.internal`, set a permanent user/password,
   and set *Save path* to `/downloads`.
2. **Jackett** (`https://jackett.example.internal`) — add your indexers; copy the
   API key from *Settings → Details*.
3. **Sonarr / Radarr** — *Settings → Indexers → Add → Jackett (Torznab)*:
   URL `http://jackett:9117/api/v2.0/indexers/all/results/torznab` + the API key;
   root folders `/media/tv` and `/media/movies`.
   *Settings → Download Clients → qBittorrent*: host `http://qbittorrent:8080`, category `sonarr` / `radarr`.
4. **Seerr** (`https://seerr.example.internal`) — the unified Overseerr/Jellyseerr
   successor. Onboarding: pick media server type **Jellyfin**, point it at your
   Jellyfin server URL, and sign in with a Jellyfin admin account (no Plex needed).
   Then *Settings → Services*: add Sonarr (`http://sonarr:8989`, API key from its
   General settings) and Radarr (`http://radarr:7878`), and set **Automatically
   approve requests = Yes** on both.

Done — a request in Seerr now auto-approves, Sonarr/Radarr search Jackett, the
torrent is sent to qBittorrent, and completed files are imported into `/media`.

## TLS for an internal domain

Let's Encrypt cannot issue certs for `.internal`. Options (see comments in
`proxy/config/traefik.yml`): **A)** mkcert local CA — generate a key pair into
`proxy/config/certs/` and uncomment the `certificates:` block; clients trust the
mkcert root CA once. **B)** do nothing: Traefik serves an auto-generated self-signed
cert (browser warning until you trust the CA).

## Adding another service

1. Add its service block to `arr/docker-compose.yml` (join it to `arr-net`,
   give it a `<name>_PORT` env var for the host port mapping).
2. Append `"<name>" (env "<NAME>_PORT" | default "<container-port>")` to the
   `$services` dict in `proxy/config/config.yml`.
3. Add `<NAME>_PORT=<port>` to `proxy/.env` and recreate both projects:
   `cd arr && docker compose up -d && cd ../proxy && docker compose up -d`.

Traefik renders one TLS router (`https://<name>.example.internal`) and one
load-balancer service (`http://<name>:<port>`, resolved over `arr-net` DNS) per
entry in `$services` — no labels, no socket access.
