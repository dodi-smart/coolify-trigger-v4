# Trigger.dev v4 on Coolify

A Coolify **Docker Compose** resource for self-hosting [Trigger.dev](https://trigger.dev)
v4, pinned to `v4.5.12`. It tracks the current official self-hosting stack —
ClickHouse 26.2, s2-lite realtime streams, MinIO object storage — and adds a
bundled, TLS-terminated Docker registry as the default deploy target plus
Resend as the default email transport.

- Official docs: [Self-hosting with Docker](https://trigger.dev/docs/self-hosting/docker)
- Upstream compose: [triggerdotdev/trigger.dev `hosting/docker`](https://github.com/triggerdotdev/trigger.dev/tree/main/hosting/docker)
- Coolify catalog template: [coollabsio/coolify `templates/compose/trigger.yaml`](https://github.com/coollabsio/coolify/blob/main/templates/compose/trigger.yaml)

This is **not** a supported Trigger.dev product — it's a community-maintained
adaptation of the official compose for Coolify's parser and conventions. For
heavy production use, the official compose on a dedicated Docker host remains
the recommended path.

## Stack

| Service | Image | Role |
| --- | --- | --- |
| `trigger` | `ghcr.io/triggerdotdev/trigger.dev` | Webapp (API, dashboard, login) |
| `supervisor` | `ghcr.io/triggerdotdev/supervisor` | Starts and manages task-runner containers |
| `docker-proxy` | `tecnativa/docker-socket-proxy` | Only holder of `docker.sock`, read-only |
| `postgresql` | `postgres:14` | Primary database (`wal_level=logical`) |
| `redis` | `redis:7` | Queues and caching |
| `electric` | `electricsql/electric` | Postgres sync (ElectricSQL) |
| `clickhouse` | `clickhouse/clickhouse-server:26.2` | Run analytics and event storage |
| `minio` | `bitnamilegacy/minio` | Object store for run packets (`packets` bucket) |
| `s2-init` + `s2` | `busybox` + `ghcr.io/s2-streamstore/s2` | Realtime streams v2 (s2-lite) |
| `dockerregistry-init` + `dockerregistry` | `httpd` + `registry:2` | Bundled deploy registry, htpasswd-protected |

### Naming vs upstream

| Official | This repo | Why |
| --- | --- | --- |
| `webapp` | `trigger` | — |
| `postgres` | `postgresql` | Matches the Coolify catalog template naming |
| `registry` | `dockerregistry` | Coolify maps the exact service name `registry` to its own docker-registry catalog entry, and a hyphenated name (`docker-registry`) can't form valid `SERVICE_*` magic-variable keys |

## Prerequisites

- A Coolify v4 instance on a reasonably sized host. Guideline: 4+ vCPU and
  8+ GB RAM for the webapp and worker on one host; runner concurrency scales
  with available resources.
- Two DNS records pointing at the Coolify host: one for the app, one for the
  bundled registry.
- A [Resend](https://resend.com) account and API key (optional — without it,
  magic-link emails fall back to being readable in the container logs).
- Willingness to allow the `/var/run/docker.sock` bind (read-only) on the
  `docker-proxy` service when Coolify prompts for it.

## Deploy

1. In Coolify: project → **New Resource** → **Docker Compose**. Point it at
   this repository's Git URL, branch `main`, compose file `docker-compose.yaml`.

2. Assign domains: the `trigger` service gets your app domain (e.g.
   `https://trigger.example.com`), and the `dockerregistry` service gets your
   registry domain (e.g. `https://registry.example.com`).

   The compose declares a bare `SERVICE_URL_TRIGGER_3000` on `trigger`, which
   tells Traefik to route port 3000. Coolify also auto-creates a portless
   `SERVICE_URL_TRIGGER`, and the compose uses that one — not the ported
   variant — for `APP_ORIGIN`, `LOGIN_ORIGIN`, and `API_ORIGIN`. Using the
   ported variant there produces `https://host:3000` and breaks login
   ([coollabsio/coolify#8638](https://github.com/coollabsio/coolify/issues/8638)).

3. In the resource's Environment Variables UI, set `RESEND_API_KEY`,
   `FROM_EMAIL`, and `REPLY_TO_EMAIL` (or switch `EMAIL_TRANSPORT` to `smtp`
   or `aws-ses` — see [Alternatives](#alternatives)). Setting
   `WHITELISTED_EMAILS` and/or `ADMIN_EMAILS` is recommended before exposing
   the instance publicly.

4. Deploy from the Coolify UI. Never run `docker compose up` by hand inside
   `/data/coolify/services/<uuid>/` — the resource's UUID network only exists
   after a UI or API deploy. Running compose manually there is what produces
   `network <uuid> declared as external, but could not be found`.

5. **Mandatory second step.** After the first successful deploy, set
   `DOCKER_RUNNER_NETWORKS` to the resource's UUID network — the folder name
   under `/data/coolify/services/`, also visible via `docker network ls` —
   and redeploy. The supervisor starts runner containers outside compose;
   those containers only join the networks listed in `DOCKER_RUNNER_NETWORKS`.
   Skipping this leaves every run stuck in `dequeued`
   ([triggerdotdev/trigger.dev#2584](https://github.com/triggerdotdev/trigger.dev/issues/2584)).
   If you ever recreate the resource, the UUID changes — update the variable
   again.

6. Log in at your app domain via magic-link email. Without Resend configured,
   retrieve the link with `docker logs <trigger container>` on the host.

## Deploy your first project

From the machine you deploy from:

1. `docker login registry.example.com` using the `SERVICE_USER_DOCKERREGISTRY`
   / `SERVICE_PASSWORD_DOCKERREGISTRY` values (copy them from the Coolify
   environment variables UI).
2. On trigger.dev CLI ≥4.4.0, if deploy fails fetching registry credentials
   (`registry_not_supported`,
   [triggerdotdev/trigger.dev#3168](https://github.com/triggerdotdev/trigger.dev/issues/3168)),
   export `TRIGGER_DOCKER_USERNAME` and `TRIGGER_DOCKER_PASSWORD` before
   deploying.
3. Never point the deploy registry at a `localhost` or `127.0.0.1` host — the
   CLI silently skips the push and deploys break at runtime
   ([triggerdotdev/trigger.dev#3257](https://github.com/triggerdotdev/trigger.dev/issues/3257)).
   That's why the bundled registry needs a real domain.
4. Set your project's config and run `npx trigger.dev@v4 deploy`. Self-hosted
   deploys build locally, so Docker is required on the deploying machine.

## Configuration reference

| Variable | Default | Purpose |
| --- | --- | --- |
| `TRIGGER_IMAGE_TAG` | `v4.5.12` | Webapp/supervisor image tag; `v4.5.0` is the last tag running v3 SDK tasks |
| `EMAIL_TRANSPORT` | `resend` | Email backend: `resend`, `smtp`, or `aws-ses` |
| `RESEND_API_KEY` | — | Resend API key |
| `FROM_EMAIL` | — | Sender address for magic-link emails |
| `REPLY_TO_EMAIL` | — | Reply-to address |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURE` / `SMTP_USER` / `SMTP_PASSWORD` | — | Used when `EMAIL_TRANSPORT=smtp` |
| `WHITELISTED_EMAILS` | — | Regex/list restricting who can sign up |
| `ADMIN_EMAILS` | — | Emails granted admin rights |
| `AUTH_GITHUB_CLIENT_ID` / `AUTH_GITHUB_CLIENT_SECRET` | — | Optional GitHub OAuth login |
| `DOCKER_RUNNER_NETWORKS` | empty | Leave empty on first deploy; set to the resource UUID network after (step 5) |
| `DEPLOY_REGISTRY_NAMESPACE` | `trigger` | Namespace prefix for pushed deploy images |
| `DOCKER_AUTOREMOVE_EXITED_CONTAINERS` | `1` | Auto-remove exited runner containers |
| `SUPERVISOR_DEBUG` | `0` | Set `1` only for debugging — leaks run env vars into logs ([trigger.dev#3566](https://github.com/triggerdotdev/trigger.dev/issues/3566)) |
| `RUN_REPLICATION_ENABLED` | `1` | Replicate run data into ClickHouse |
| `EVENT_REPOSITORY_DEFAULT_STORE` | `clickhouse_v2` | Task event store; empty keeps events in Postgres |
| `TRIGGER_TELEMETRY_DISABLED` | — | Set to disable telemetry |
| `NODE_MAX_OLD_SPACE_SIZE` | `8192` | Node heap size in MB; set to ~80% of the container's RAM limit |
| `DEFAULT_ENV_EXECUTION_CONCURRENCY_LIMIT` | `100` | Max concurrent runs per environment — applied only to environments created after it's set |
| `DEFAULT_ORG_EXECUTION_CONCURRENCY_LIMIT` | `300` | Max concurrent runs per organization (keep ~3× the env limit) — applied only to orgs created after it's set |
| `POSTGRES_DB` | `main` | Database name |
| `POSTGRES_IMAGE_TAG` | `14` | Postgres image tag |
| `REDIS_IMAGE_TAG` | `7` | Redis image tag |
| `ELECTRIC_IMAGE_TAG` | `1.2.4` | ElectricSQL image tag |
| `CLICKHOUSE_IMAGE_TAG` | `26.2` | ClickHouse image tag |
| `REGISTRY_IMAGE_TAG` | `2` | Bundled registry image tag |
| `MINIO_IMAGE_TAG` | `latest` | MinIO image tag |
| `BUSYBOX_IMAGE_TAG` | `1.37` | s2-init helper image tag |
| `HTTPD_IMAGE_TAG` | `2.4` | dockerregistry-init helper image tag |
| `S2_IMAGE` | pinned digest | s2-lite realtime image |
| `REALTIME_STREAMS_DEFAULT_VERSION` | `v2` | Realtime streams protocol version |
| `REALTIME_STREAMS_S2_BASIN` | `trigger-realtime` | s2 basin name |
| `REALTIME_STREAMS_S2_ENDPOINT` | `http://s2/v1` | s2 endpoint |
| `REALTIME_STREAMS_S2_SKIP_ACCESS_TOKENS` | `true` | Skip s2 access tokens (internal network only) |
| log level vars | `info` | `APP_LOG_LEVEL`, `CLICKHOUSE_LOG_LEVEL`, `RUN_REPLICATION_LOG_LEVEL`, etc. |

Coolify auto-generates the rest on first deploy: `SERVICE_URL_TRIGGER_3000`
(and the derived portless `SERVICE_URL_TRIGGER`), `SERVICE_FQDN_DOCKERREGISTRY_5000`
(and the derived portless `SERVICE_FQDN_DOCKERREGISTRY`), `SERVICE_USER_POSTGRES`
/ `SERVICE_PASSWORD_POSTGRES`, `SERVICE_PASSWORD_64_SESSION` / `_MAGICLINK` /
`_PROVIDER` / `_COORDINATOR` / `_WORKERSECRET` / `_CLICKHOUSE`,
`SERVICE_PASSWORD_ENCRYPTIONKEY` (exactly 32 characters, as Trigger.dev
requires), `SERVICE_USER_CLICKHOUSE`, `SERVICE_USER_MINIO` /
`SERVICE_PASSWORD_MINIO`, `SERVICE_USER_DOCKERREGISTRY` /
`SERVICE_PASSWORD_DOCKERREGISTRY` (the registry login), and
`SERVICE_PASSWORD_REGISTRYHTTPSECRET`. You should not need to set these by
hand.

## Alternatives

### GHCR or another external registry

Fork the repo and point the deploy registry at GHCR (or any other registry)
instead of the bundled one:

```yaml
# on the `trigger` service
- DEPLOY_REGISTRY_HOST=ghcr.io

# on the `supervisor` service
- DOCKER_REGISTRY_URL=ghcr.io
- DOCKER_REGISTRY_USERNAME=<your registry username>
- DOCKER_REGISTRY_PASSWORD=<your registry password>
```

You can then delete the `dockerregistry-init` and `dockerregistry` services.

### SMTP / AWS SES email

Set `EMAIL_TRANSPORT=smtp` and fill in `SMTP_HOST`, `SMTP_PORT`,
`SMTP_SECURE`, `SMTP_USER`, `SMTP_PASSWORD` — note that `SMTP_SECURE=false`
means STARTTLS, not plaintext. Or set `EMAIL_TRANSPORT=aws-ses` and provide
the standard AWS SDK environment variables.

## Troubleshooting

**`network <uuid> declared as external, but could not be found`**
Deploy from the Coolify UI, not with `docker compose up` by hand. If Docker's
address pools are exhausted (`all predefined address pools have been fully
subnetted`), widen `default-address-pools` in `/etc/docker/daemon.json`
([coollabsio/coolify#4943](https://github.com/coollabsio/coolify/issues/4943)).

**Runs stuck in `dequeued`**
`DOCKER_RUNNER_NETWORKS` isn't set to the resource's UUID network — see
[step 5](#deploy). Also check the runner container's own logs with
`docker logs`; the supervisor logging "create succeeded" only means the
container was created, not that it's healthy.

**Runs queued even though workers are idle / concurrency capped**
The effective limits live on the `Organization.maximumConcurrencyLimit` and
`RuntimeEnvironment.maximumConcurrencyLimit` database rows, stamped at creation
time. Setting `DEFAULT_ORG_EXECUTION_CONCURRENCY_LIMIT` /
`DEFAULT_ENV_EXECUTION_CONCURRENCY_LIMIT` only affects orgs and environments
created afterwards — raise existing ones directly (server shell, container name
via `docker ps | grep postgres`):

```sql
-- docker exec -it <postgresql-container> sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"'
UPDATE "Organization" SET "maximumConcurrencyLimit" = 300
  WHERE slug = '<your-org-slug>';
UPDATE "RuntimeEnvironment" SET "maximumConcurrencyLimit" = 100
  WHERE "organizationId" = (SELECT id FROM "Organization" WHERE slug = '<your-org-slug>');
```

Keep the org limit ~3× the env limit. New dequeues pick the values up; restart
the `trigger` service if a stale limit appears to linger.

**Registry push 401 / auth failures**
Confirm `docker login` against the registry domain using the
`SERVICE_USER_DOCKERREGISTRY` credentials. Large layer pushes go through
Coolify's Traefik, which has no body-size limit by default.

**Login link broken / wrong origin**
The domain assigned to `trigger` must match the public URL exactly. Origins
use the portless `SERVICE_URL_TRIGGER`
([coolify#8638](https://github.com/coollabsio/coolify/issues/8638)).

**`ENCRYPTION_KEY` errors**
It must be exactly 32 characters; the compose maps
`SERVICE_PASSWORD_ENCRYPTIONKEY` (32 characters) for that reason. Rotating it
makes existing encrypted data unreadable.

**Don't set `SUPERVISOR_DEBUG=1` on shared instances** — it leaks run
environment variables into logs
([trigger.dev#3566](https://github.com/triggerdotdev/trigger.dev/issues/3566)).

**v3 SDK projects**
Pin `TRIGGER_IMAGE_TAG=v4.5.0` — later tags reject v3 deploys and triggers.

## Local syntax check

A full boot outside Coolify isn't supported (the UUID network, Traefik
routing, and `SERVICE_*` magic variables are all Coolify-side). To validate
the compose file's syntax:

```bash
env SERVICE_URL_TRIGGER=https://trigger.example.com SERVICE_URL_TRIGGER_3000=https://trigger.example.com:3000 \
    SERVICE_FQDN_DOCKERREGISTRY=registry.example.com SERVICE_FQDN_DOCKERREGISTRY_5000=registry.example.com:5000 \
    SERVICE_USER_POSTGRES=p SERVICE_PASSWORD_POSTGRES=x SERVICE_PASSWORD_64_SESSION=x \
    SERVICE_PASSWORD_64_MAGICLINK=x SERVICE_PASSWORD_ENCRYPTIONKEY=x SERVICE_PASSWORD_64_PROVIDER=x \
    SERVICE_PASSWORD_64_COORDINATOR=x SERVICE_PASSWORD_64_WORKERSECRET=x SERVICE_USER_CLICKHOUSE=c \
    SERVICE_PASSWORD_64_CLICKHOUSE=x SERVICE_USER_MINIO=m SERVICE_PASSWORD_MINIO=x \
    SERVICE_USER_DOCKERREGISTRY=r SERVICE_PASSWORD_DOCKERREGISTRY=x SERVICE_PASSWORD_REGISTRYHTTPSECRET=x \
  sh -c 'sed "/exclude_from_hc/d" docker-compose.yaml | docker compose -f - config >/dev/null' && echo OK
```

(The `sed` strips the Coolify-only `exclude_from_hc` key, which plain
`docker compose` doesn't understand.)

## Credits

- Upstream Trigger.dev [`hosting/docker`](https://github.com/triggerdotdev/trigger.dev/tree/main/hosting/docker) compose
- Coolify catalog [`templates/compose/trigger.yaml`](https://github.com/coollabsio/coolify/blob/main/templates/compose/trigger.yaml)
- [essamamdani/coolify-trigger-v4](https://github.com/essamamdani/coolify-trigger-v4), origin of the community Coolify port
