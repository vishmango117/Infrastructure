# Internal DNS alongside Tailscale: Pi-hole v6 vs AdGuard Home vs Technitium vs CoreDNS (vs Blocky)

Research for issue #3. Sources are official docs, maintainers' repositories and release notes, checked on 2026-10-11. Versions current at that date: Pi-hole FTL v6.7.1 / docker-pi-hole 2026.09.0, AdGuard Home v0.107.79, Technitium DNS Server v15.6, CoreDNS v1.14.7, Blocky v0.35.0 (from each project's GitHub "latest release").

The assumed setup is a primary and a secondary DNS VM (Ubuntu) managed by Ansible from a controller, with compose files in git, Traefik on the same Docker hosts, and Tailscale installed on the DNS VMs.

## TL;DR

**Recommendation: AdGuard Home**, deployed identically on both VMs from one Ansible-templated `AdGuardHome.yaml`. Ansible is the sync mechanism: there is no primary-to-secondary replication to run.

- One declarative file holds local records (`filtering.rewrites`), blocklists (`filters`), custom rules (`user_rules`), upstreams (including per-domain upstreams) and access lists, so the whole resolver lives in git.
- It matches or beats Pi-hole's ad-blocking (hosts, domains-only and Adblock-style lists, per-client settings, blocked services).
- It works as a Tailscale split DNS target with no extra settings, because by default it accepts queries from any client, including tailnet `100.64.0.0/10` addresses.
- An official Docker image, a web UI that can sit behind Traefik, and documented steps for the Ubuntu `systemd-resolved` port-53 conflict.

**Runner-up: Technitium DNS Server.** Pick it if you want a real authoritative DNS server: RFC 1035 zone files, native AXFR/IXFR secondaries, catalog zones, and built-in clustering since v14. The cost is that records are pushed through its HTTP API rather than kept as a file it reads, and cluster upgrades have needed all nodes upgraded together.

**Pure-GitOps alternative: Blocky.** It is stateless and runs from one YAML file with ad-blocking and custom DNS, but it has no web UI.

**Keep Pi-hole v6 only to minimise change.** Its DNS records and settings can be code (`pihole.toml` / `FTLCONF_*`), but blocklists, groups and domains live in `gravity.db` and change only through the API. Pair sync needs a third-party tool (nebula-sync), because gravity-sync is archived.

**CoreDNS is not recommended on its own.** It is excellent for records-as-code and secondaries, but it has no real ad-blocking.

## Comparison

| | Pi-hole v6 | AdGuard Home | Technitium | CoreDNS | Blocky |
|---|---|---|---|---|---|
| (a) Records as code | `pihole.toml` `dns.hosts`, `dns.cnameRecords`, `misc.dnsmasq_lines`; or `FTLCONF_*` env vars (become read-only). Adlists in `gravity.db` via `/api/lists` only | Whole config in `AdGuardHome.yaml` (rewrites, filters, rules, upstreams); REST API `/control/rewrite/*`, `/control/filtering/*` | RFC 1035 zone file pushed via `POST /api/zones/import` (`overwriteZone=true`); full HTTP API with bearer tokens | Corefile + RFC 1035 zone files (`file` plugin, auto-reload on serial/mtime) or `hosts` file | Single YAML: `customDNS.mapping` or inline `zone`, lists, conditional forwarding |
| (b) Pair sync | None native; nebula-sync (third-party, Teleporter/selective); or identical env on both | None native; identical template on both; or adguardhome-sync (third-party) | Native secondary zones (AXFR/IXFR, NOTIFY), catalog zones (RFC 9432), clustering (v14+) | Native `secondary` + `transfer` plugins; or identical files | Stateless, identical config; optional Redis to share cache and blocking state |
| (c) Tailscale | Official Tailscale KB guide; needs "Permit all origins" (`listeningMode = ALL` in Docker bridge) | Accepts all clients by default; `[/domain/]upstream` syntax for per-domain forwarding | Default recursion ACL "private networks" includes `100.64.0.0/10`; conditional forwarder zones | `forward` plugin; no ACL unless `acl` plugin added | `conditional` mapping; `ports.freeBind` for Tailscale addresses |
| (d) Ad-blocking vs Pi-hole | Baseline | Parity+ (Adblock syntax, `$dnsrewrite`, per-client, blocked services) | Parity (block list URLs incl. hosts/wildcard/Adblock Plus; Advanced Blocking app for per-client groups) | No list management; `hosts` plugin can load a hosts-format list, nothing fetches or refreshes it | Parity (hosts/domains/wildcard/regex lists, client groups, schedules); no UI |
| (e) Docker + Traefik | Official image, built-in web server on 80/443 (configurable) | Official image, setup on 3000 then UI port from config | Official image, console on 5380 | Tiny official image, no UI | Small image, HTTP API/metrics only |

## (a) Local records as code from git/Ansible

### Pi-hole v6

- All settings live in `/etc/pihole/pihole.toml`. Each key can be set by an environment variable `FTLCONF_<section>_<key>`, and **a setting defined by an environment variable becomes read-only** in the TOML file, CLI and web UI ([FTL config reference](https://docs.pi-hole.net/ftldns/configfile/), [Docker configuration](https://docs.pi-hole.net/docker/configuration/)).
- Local records: `dns.hosts` takes an array of `"IP HOSTNAME [HOSTNAME ...]"`, and `dns.cnameRecords` takes `"<cname>,<target>[,<TTL>]"` ([configfile](https://docs.pi-hole.net/ftldns/configfile/)). In Docker, arrays are delimited with `;` or written as a YAML block ([Docker configuration](https://docs.pi-hole.net/docker/configuration/)). Other record types or forwarding rules go through `misc.dnsmasq_lines`.
- Blocklists ("lists"), groups and allow/deny domains are **not** in `pihole.toml`. They are stored in the gravity database (`files.gravity`, default `/etc/pihole/gravity.db`, see [configfile](https://docs.pi-hole.net/ftldns/configfile/)), and the REST API manages them (`/api/lists`, `/api/domains`, `/api/groups`; [API docs](https://docs.pi-hole.net/api/), [lists spec in FTL](https://github.com/pi-hole/FTL/blob/master/src/api/docs/content/specs/lists.yaml)).
- Net: compose env vars rendered by Ansible cover records and DNS settings. Blocklists need Ansible `uri` calls against the API, so the configuration is split across two mechanisms.

### AdGuard Home

- The whole configuration is one `AdGuardHome.yaml`. Per the docs: "You can modify the file while your AdGuard Home service is not running. Otherwise, any changes to the file will be lost because the running program will overwrite them" ([Configuration wiki](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration#configuration-file)).
- Relevant keys ([Configuration wiki](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration)):
  - `filtering.rewrites` (since v0.107.37): `domain`/`answer` pairs (IP, CNAME, or wildcard).
  - `filters` and `whitelist_filters`: list URLs.
  - `user_rules`: custom rules.
  - `dns.upstream_dns`: upstreams, including `[/example.local/]<server>` per-domain upstreams.
  - `dns.allowed_clients` / `dns.disallowed_clients`: access lists.
  - `users`: web login with a bcrypt hash.
- For records beyond A/AAAA/CNAME, `$dnsrewrite` rules in `user_rules` take an `RCODE;RRTYPE;VALUE` form ([Hosts-Blocklists wiki: dnsrewrite](https://github.com/AdguardTeam/AdGuardHome/wiki/Hosts-Blocklists#dnsrewrite)).
- The first-run wizard is skipped whenever the config file already exists: `detectFirstRun` only checks that the file is present ([source](https://github.com/AdguardTeam/AdGuardHome/blob/master/internal/home/home.go)). A pre-templated file therefore starts the instance fully configured.
- There is also a REST API for imperative changes: `/rewrite/add|update|delete`, `/filtering/add_url|set_rules|refresh` ([openapi.yaml](https://github.com/AdguardTeam/AdGuardHome/blob/master/openapi/openapi.yaml)).
- Ansible pattern: `template` the file, then restart the container from a handler when it changes. The UI becomes a viewer, because any UI edit is reverted on the next run.

### Technitium DNS Server

- Records live in real zones. `POST /api/zones/import` accepts "a complete zone file or a set of DNS resource records in standard RFC 1035 zone file format". `overwriteZone=true` deletes all existing records first, so the zone matches the file exactly ([APIDOCS: Import Zone](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md#import-zone)). The overwrite-entire-zone option was added in v15.0 ([CHANGELOG](https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md)).
- Authentication uses API tokens (`/api/user/createToken`) passed as `Authorization: Bearer <token>`, supported since v15.0 ([CHANGELOG v15.0](https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md), [APIDOCS](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md)).
- Core settings (admin password, recursion ACL, forwarders, block list URLs) can be passed as `DNS_SERVER_*` environment variables in the official compose file ([docker-compose.yml](https://github.com/TechnitiumSoftware/DnsServer/blob/master/docker-compose.yml)). Everything else goes through `/api/settings/set`.
- Net: a zone file in git is a clean source of truth. Ansible pushes it with `uri`. This is imperative (API calls) rather than a file the server reads.

### CoreDNS

- The `file` plugin serves RFC 1035 zone files. It reloads when the SOA serial changes (default check every minute), or on mtime with `reload_by_mtime` ([file plugin](https://coredns.io/plugins/file/)).
- The `hosts` plugin serves A/AAAA/PTR from a hosts-format file and re-reads it every 5 seconds ([hosts plugin](https://coredns.io/plugins/hosts/)).
- This is the most "as code" option of the five, but it does nothing else a homelab DNS appliance usually does (see d).

### Blocky (alternative)

- One YAML file ([configuration docs](https://0xerr0r.github.io/blocky/latest/configuration/), [source](https://github.com/0xERR0R/blocky/blob/main/docs/configuration.md)):
  - `customDNS.mapping`: A/AAAA/CNAME/TXT/SRV, with automatic reverse lookups.
  - `customDNS.zone`: inline zone-file content.
  - `conditional.mapping`: per-domain resolvers.
  - `blocking.denylists` / `allowlists` / `clientGroupsBlock`.
- A published JSON schema allows editor and CI validation.

## (b) Keeping a primary/secondary pair in sync

When (a) is solved by rendering the same config from git onto both VMs, sync reduces to "run the playbook against both hosts". That works for every candidate except the parts of Pi-hole that live in `gravity.db`.

- **Pi-hole v6:** no built-in replication.
  - [gravity-sync](https://github.com/vmstan/gravity-sync) is **archived** (last release v4.0.7, January 2024).
  - The maintained third-party option for v6 is [nebula-sync](https://github.com/lovelaze/nebula-sync). It is "not a part of the official Pi-hole project", uses the Pi-hole API with Teleporter for a full sync or selective features, and runs on a cron schedule. Latest release v0.11.2, May 2026.
- **AdGuard Home:** no built-in replication.
  - Option 1, recommended: render an identical `AdGuardHome.yaml` on both nodes.
  - Option 2: [adguardhome-sync](https://github.com/bakito/adguardhome-sync), third-party and active (v0.9.4, October 2026). It syncs filters, rewrites and other settings from an origin to replicas over the API.
  - Query logs and statistics remain per-node in both cases.
- **Technitium:** the strongest native story.
  - Standard secondary zones with zone transfer and NOTIFY.
  - Catalog zones (RFC 9432) auto-provision secondaries.
  - Network ACLs for zone transfer ([CHANGELOG](https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md)).
  - v14.0 (November 2025) added **Clustering**: "manage all of them from a single DNS admin web console … aggregate Dashboard data". Initialising a cluster creates a cluster catalog zone "for automatic provisioning of Secondary zones on all of the Cluster Secondary nodes" ([APIDOCS: Initialize Cluster](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md#initialize-cluster)).
  - Caveat from the same changelog: v14.1, v14.2 and v15.0 each carried breaking cluster changes that required upgrading all nodes together.
- **CoreDNS:** the `secondary` plugin does AXFR from a primary, including RFC 9432 catalog zones. The transferred zone is not written to disk and is re-fetched on restart ([secondary plugin](https://coredns.io/plugins/secondary/)). The `transfer` plugin serves outbound transfers.
- **Blocky:** stateless. Identical config is the sync. Optional Redis "can synchronize its cache and blocking state between multiple instances" ([Redis section](https://0xerr0r.github.io/blocky/latest/configuration/#redis)).

## (c) Tailscale split DNS / MagicDNS

Facts from Tailscale:

- MagicDNS names devices automatically, but "it's not possible to add arbitrary records to MagicDNS" ([DNS in Tailscale](https://tailscale.com/kb/1054/dns)). Internal service names therefore need our own server.
- A **restricted nameserver** (split DNS) "only applies to DNS queries matching a specific search domain". A **global nameserver** handles everything. "Override DNS servers" forces tailnet devices to use the global nameservers ([DNS in Tailscale](https://tailscale.com/kb/1054/dns)).
- This configuration can itself be code:
  - API: `/api/v2/tailnet/{tailnet}/dns/split-dns` with GET/PATCH/PUT, plus `/dns/nameservers`, `/dns/preferences` and `/dns/configuration` ([Tailscale API](https://tailscale.com/api), [Go client](https://github.com/tailscale/tailscale-client-go-v2/blob/main/dns.go)).
  - Terraform: `tailscale_dns_split_nameservers` and `tailscale_dns_configuration` ([provider docs](https://github.com/tailscale/terraform-provider-tailscale/tree/main/docs/resources)).
- Tailscale's own Pi-hole guide has two requirements ([Pi-hole with Tailscale](https://tailscale.com/kb/1114/pi-hole)):
  - The DNS server must answer queries arriving from `100.x` tailnet addresses (for Pi-hole: "Permit all origins").
  - The DNS host should run `tailscale up --accept-dns=false`, "since the Raspberry Pi is the DNS server".
- `100.100.100.100` (Quad100) is a device-local stub resolver for MagicDNS. Other devices cannot reach your device through it ([What is Quad100](https://tailscale.com/kb/1381/what-is-quad100)).

Per candidate:

- **Pi-hole:** the default `dns.listeningMode = "LOCAL"` only answers clients on directly attached subnets. The docker-pi-hole README says to use `ALL` with Docker's bridge network ([configfile: listeningMode](https://docs.pi-hole.net/ftldns/configfile/#listeningmode), [docker-pi-hole README](https://github.com/pi-hole/docker-pi-hole)).
- **AdGuard Home:** `allowed_clients` is empty by default, so it answers everyone ([Configuration wiki](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration)). Tighten it to LAN + `100.64.0.0/10` if desired.
- **Technitium:** the default recursion setting `AllowOnlyForPrivateNetworks` ([compose env](https://github.com/TechnitiumSoftware/DnsServer/blob/master/docker-compose.yml)) uses `NetUtilities.IsPrivateIP`. That function explicitly includes `100.64.0.0/10` (carrier-grade NAT, the tailnet range) ([TechnitiumLibrary source](https://github.com/TechnitiumSoftware/TechnitiumLibrary/blob/master/TechnitiumLibrary.Net/NetUtilities.cs)). Tailnet clients work out of the box.
- **CoreDNS / Blocky:** no client ACL by default. Blocky has `ports.freeBind` to bind Tailscale/WireGuard addresses that are not up yet ([Blocky ports](https://0xerr0r.github.io/blocky/latest/configuration/#ports-addresses-configuration)).

Recommended Tailscale wiring, the same for any candidate:

1. Join **both** DNS VMs to the tailnet with `--accept-dns=false`.
2. Add a split DNS entry for the internal zone pointing at both VMs' tailnet addresses, managed through the API or Terraform rather than by hand.
3. Keep MagicDNS on. Tailnet clients resolve `*.ts.net` locally through Quad100, so the DNS servers do not need to forward `ts.net`.
4. Optional: also set the two servers as **global** nameservers with "Override DNS servers" to get ad-blocking on roaming devices. Tailscale warns that every device must be able to reach the global nameservers, or it cannot resolve anything.

## (d) Ad-blocking parity with Pi-hole

- **AdGuard Home** reads hosts, domains-only and Adblock-style lists. It adds modifiers (`$client`, `$dnstype`, `$dnsrewrite`, `$important`), per-client settings, blocked services, schedules and safe search ([Hosts-Blocklists wiki](https://github.com/AdguardTeam/AdGuardHome/wiki/Hosts-Blocklists), [Configuration wiki](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration)). That is at least parity.
- **Technitium** subscribes to block list URLs. It supports wildcard and Adblock Plus formats ([CHANGELOG](https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md)), and the Advanced Blocking app provides per-client/group policies and a configurable update interval. That is parity, with a less familiar UI.
- **Blocky** supports hosts, domains, wildcard and regex lists, client groups, schedule-based blocking and a query log to SQLite or other databases ([configuration](https://0xerr0r.github.io/blocky/latest/configuration/#blocking-and-allowlisting)). That is parity on features, but there is no UI (API plus Prometheus/Grafana only).
- **CoreDNS:** the `hosts` plugin "can be used with readily available hosts files that block access to advertising servers" ([hosts plugin](https://coredns.io/plugins/hosts/)). It only covers hosts format, with no list fetching or updating, no allowlists and no query UI. It falls short of parity.

## (e) Docker deployment alongside Traefik

- Every candidate ships an official image:
  - `pihole/pihole`
  - `adguard/adguardhome`
  - `technitium/dns-server`
  - `coredns/coredns`
  - `ghcr.io/0xerr0r/blocky` / `spx01/blocky`
- **Publish port 53/tcp+udp straight from the DNS container on the host. Do not route it through Traefik.** Traefik can proxy UDP, but per-client stats, client groups and ACLs all key on the client source address, and an extra proxy hop hides it. Route only the web UI through Traefik with the usual HTTP router labels. This works the same on Traefik v2 and v3.
- UI ports:
  - **Pi-hole v6:** built-in web server, `webserver.port`, default `"80o,443os,[::]:80o,[::]:443os"` ([configfile](https://docs.pi-hole.net/ftldns/configfile/)). Move it off 80/443 if Traefik shares the host network.
  - **AdGuard Home:** setup wizard on 3000, then the UI on `http.address` ([Docker wiki](https://github.com/AdguardTeam/AdGuardHome/wiki/Docker)).
  - **Technitium:** 5380 (HTTP), 53443 (HTTPS). It also has an optional DNS-over-HTTP listener on 8053 "to be used with a TLS terminating reverse proxy" ([compose](https://github.com/TechnitiumSoftware/DnsServer/blob/master/docker-compose.yml)).
- **Ubuntu gotcha:** `systemd-resolved`'s stub listener holds `127.0.0.53:53`, so Docker cannot bind 53 until `DNSStubListener=no` is set and `/etc/resolv.conf` is re-pointed ([AdGuard Home Docker wiki: resolved](https://github.com/AdguardTeam/AdGuardHome/wiki/Docker#resolved-daemon)). This applies to all candidates and belongs in the Ansible role.

## Recommendation and trade-offs

**Use AdGuard Home on both DNS VMs, configured entirely from an Ansible-templated `AdGuardHome.yaml`.**

Why:

1. **Everything is in one file in git.** Records, blocklists, custom rules, upstreams and access are all in that file, and the same template on both hosts *is* the pair sync. There is no replication tool, and no split between config and a database as with Pi-hole.
2. **Ad-blocking is a superset of Pi-hole's** and it accepts the same list URLs, so blocking does not regress.
3. **It works as a Tailscale split DNS target with zero extra config.** Split DNS itself can also be code (Tailscale API/Terraform).
4. **The Docker footprint is light**, with a UI that fits behind Traefik.

Trade-offs to accept:

- **The UI is effectively read-only.** AGH rewrites its YAML at runtime, and Ansible overwrites UI edits on the next run. Edit only while the container is stopped (or let the handler restart it).
- **Template churn on upgrades.** The file has a `schema_version`, and upgrades migrate it in place. Pin the image tag and refresh the template whenever the tag changes, or Ansible will keep reporting diffs.
- **Stats and query logs are per node.** No aggregate dashboard; Technitium's cluster has one.
- **Local records are rewrites, not authoritative zones.** No SOA/NS, zone transfer or DNSSEC for internal names. Fine for a homelab; choose Technitium if that changes.
- **The admin password hash sits in the YAML.** Keep it in Ansible Vault, not in plain git, because this repo is public.

When to choose otherwise:

- **Technitium:** you want authoritative internal zones, DNSSEC, native secondaries/catalog zones, or one console for both nodes. Accept that it is API-driven and that cluster upgrades are lockstep.
- **Blocky:** you are happy to have no UI and want the smallest, fully declarative, stateless resolver. Add Redis to share cache and blocking state.
- **Pi-hole v6:** migration effort must be minimal. Use `FTLCONF_*` env vars for records and settings, and API calls or nebula-sync for lists, and accept two config mechanisms plus a third-party sync tool.
