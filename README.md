# aws-app-config-lambda

A Lambda (TypeScript + Effect) that reads its config from AWS AppConfig and returns it
from a public Function URL. Turbo/pnpm monorepo, Vite for both the dev server and the
prod bundle, Terraform for infra, deploy roles vended by `aws-foundation`.

```
apps/config-lambda/
  config/{dev,prod}.json   config content per environment (deployed to AppConfig)
  src/config.ts            Settings schema + AppConfig service (extension / file layers)
  src/handler.ts           Lambda handler
  vite.config.ts           dev server + single-file ESM build (dist/index.mjs)
infra/main.tf              AppConfig app/env/profile/deployment, Lambda, Function URL
.github/workflows/         ci.yml (build → plan | dev → prod), terraform.yml (reusable)
```

## Local

Node 24 (`.nvmrc`) and pnpm (`corepack enable`).

```bash
pnpm install
pnpm dev          # http://localhost:5173 serves the handler with config/dev.json
pnpm test         # every config/*.json must decode against Settings
pnpm build        # apps/config-lambda/dist/index.mjs
pnpm lint
```

## Changing config

Edit `apps/config-lambda/config/<env>.json`. Changing its shape means editing
`Settings` in [src/config.ts](apps/config-lambda/src/config.ts) too. CI fails the PR if
any env file stops matching. On merge, Terraform creates a new hosted version and deploys
it instantly. Warm Lambdas pick it up within the extension's 45 s poll.

## One-time setup

1. **Deploy roles.** Merge the aws-foundation PR adding
   `role-vending/repos/aws-app-config-lambda.yaml`. That vends
   `aws-app-config-lambda-dev` (724126527725) and `aws-app-config-lambda-prod`
   (224193574799). The workflow derives the ARNs, so there are no variables to set.
2. **GitHub environments** in this repo (the roles trust only these names):
   - `dev`: no branch restriction, because PR plans run in it.
   - `production`: required reviewers, deployment branch `main`.

## Pipeline

| Event | Jobs |
|---|---|
| PR | lint, typecheck, test, build → `terraform plan` against dev (in the job summary) |
| push to `main` | same build → apply dev + smoke test → apply prod (after approval) + smoke test |

State: `<account>-tf-remote-state` / `aws-app-config-lambda/main.tfstate`, in each account.
