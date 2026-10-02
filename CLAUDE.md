# coolify-trigger-v4

A Coolify **Docker Compose resource** for self-hosted Trigger.dev v4, derived from
upstream [`hosting/docker`](https://github.com/triggerdotdev/trigger.dev/tree/main/hosting/docker).
There is no application code: the product is `docker-compose.yaml`, `.env.example`,
`clickhouse/*.xml` and the README deploy guide. `main` is the only branch, and
Coolify deploys from it.

## Porting upstream changes

Upstream's compose is written for plain `docker compose`; this one is parsed by
Coolify. When porting (usually from the weekly "Port upstream Trigger.dev
self-hosting changes" issue):

- Follow the parser rules in the header of `docker-compose.yaml`: no top-level or
  per-service `networks:`, no `ports:`/`expose:` on `trigger`, no `container_name`,
  `version:` or `restart:` on long-running services, list-style `environment`,
  no service named `registry`.
- Secrets come from Coolify magic variables (`SERVICE_PASSWORD_*`, `SERVICE_USER_*`,
  `SERVICE_URL_*`, `SERVICE_FQDN_*`), never from `.env` values. Do not change an
  existing magic variable's name or length: Coolify keeps the generated value per
  resource, and `ENCRYPTION_KEY` must stay exactly 32 chars (`SERVICE_PASSWORD_*`).
- Public origins use the unported `${SERVICE_URL_TRIGGER}`, never `_3000`.
- **Never pass a variable as an empty string when the app parses empty as a value.**
  Empty concurrency limits coerce to 0 and block all runs; an empty `BoolEnv` parses
  as `false`. Check `apps/webapp/app/env.server.ts` at the target tag and give such
  variables an explicit `:-default`.
- Skip local-only upstream tooling: `generate-secrets.sh`, the Traefik example,
  publish IPs, logging drivers, `restart:` policies.
- Keep config files under `clickhouse/` verbatim copies of upstream's, so the
  drift diff stays readable.
- Every new variable gets a row in the README configuration reference and an
  entry in `.env.example`.
- Bump `trigger.dev` and `supervisor` together; they must always share a tag.

Verify with the syntax check at the bottom of `.env.example` (`docker compose
config`). A full local boot isn't supported, because the stack depends on Coolify's
magic variables and network.

## Dependencies

Renovate (`renovate.json5`) and `.github/workflows/upstream-drift.yml` run weekly;
the README's "Keeping up to date" section describes both. Images that upstream pins
(Postgres, Redis, ClickHouse, registry, s2, busybox) follow upstream's
pin, not their own latest release.

Electric is intentionally absent: its image was removed from Docker Hub
(electric-sql/electric#4822) and realtime runs on the native backend
(`REALTIME_BACKEND_NATIVE_ENABLED=1`, `REALTIME_BACKEND_DEFAULT=native`), as in
upstream's Helm chart. Do not port an `electric` service back from upstream's
Docker compose.

## Triage & Labels

This repo follows the dodi-smart org-wide issue standard. Three axes, and each
fact belongs on exactly one of them:

- **Type**: what kind of work this is (Bug, Feature, Improvement, Task,
  Chore, Spike, Epic, Initiative). Set via GitHub's Issue Type, not a label.
- **Fields**: how urgent, how big, how risky, and where the issue sits in the
  pipeline (Priority, Effort, Risk, Source, Triage state, Agent mode). Set via
  Issue Fields, not a label.
- **Labels**: where in the code (`area:*`, see `.github/areas.yml`) and what
  is blocking progress (`needs:*`). This is the only per-repo namespace;
  everything else is org-wide.

There is no `type:bug` label and no `priority:high` label — the Type and the
Priority field already say that.

`agent:*` labels are requests, not records: `agent:triage`, `agent:implement`
and `agent:review` each ask an agent to act, and clear themselves when the run
finishes. `agent:no-touch` is the one exception: it never clears itself, and
it stops every agent unconditionally.

Apply `agent:triage` to a new issue (or comment `@claude triage`) to have an
agent set Type, `area:*` and Priority/Risk, and then either write a plan
(`Triage state = Plan ready`) or ask blocking questions. Once `Triage state` is
`Plan ready`, apply `agent:implement` (or comment `@claude implement`) to get a
branch and a draft PR against `main`.
