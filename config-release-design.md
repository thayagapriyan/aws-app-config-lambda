# Config release design: aws-app-config-lambda

Draft for discussion, updated 2026-09-23. **Not implemented.** Section 10 lists what would
have to change.

## 1. Decisions so far

Every release is one of three types:

| Type | What changes | Order | Rollback |
|---|---|---|---|
| **1. Config only** | Config values. The shape stays the same and the live code already handles it. | Config: dev → test → prod | Deploy the previous config version |
| **2. Lambda only** | Code. It works with the live config. | Lambda: dev → test → prod | `live` → previous Lambda version |
| **3. Lambda + breaking config** | Anything the live code can't read or handle | **Lambda first** (new code reads old *and* new config, with defaults), **then** config | Reverse order: config back first, then the Lambda |

`dev` is the test stage for all three types. There's no canary environment.

## 2. Requirements

| # | Requirement |
|---|---|
| R1 | One AppConfig application. Each account has one live environment (`dev` / `prod`) and the profile `settings`. |
| R2 | A change to the env JSON creates a new AppConfig version. No change keeps the current one. |
| R3 | The Lambda reads config through the AppConfig extension layer, which Terraform attaches. |
| R4 | Type 1 does **not** publish a Lambda version. Type 2 does **not** create a config version. |
| R5 | `dev` is the test stage. `prod` gets only what passed `dev`. |
| R6 | Type 3 goes Lambda first, and the new Lambda version works with both the old and the new config. |
| R7 | Every type rolls back to the previous config version and/or Lambda version. |
| R8 | You can always tell which Lambda version and which config version are live. |
| R9 | Later: an ALB sends traffic to the `live` alias. The org SCP blocks load balancers today. |

## 3. How the two switches behave

Everything below builds on these facts. The schema rows were checked by running Effect 3.22
against sample configs.

| Switch or situation | Behaviour |
|---|---|
| **Lambda alias move** (`live` → new version) | New requests reach the new version within seconds. Requests already running finish on the old version. It is never partly applied. |
| **Config deployment** (zero-wait strategy) | AppConfig marks it COMPLETE immediately. Instances starting fresh fetch the new config on their first read. Instances already running see it at their next poll, **within 45 s**. |
| Config deployment (gradual strategy) | Until it's COMPLETE, only some instances get the new config. |
| Code reads config **with extra fields** | **Works.** `Schema.Struct` ignores keys it doesn't know, at any nesting level. |
| Code reads config **missing a field** | **Fails** if the field is required. **Works** if the field has a default: `Schema.optionalWith(X, { default: () => … })`. |
| Code reads config with a **retyped** field | **Fails**, unless the schema accepts both types. |
| AppConfig versions | Can't be changed after creation. Numbers are per account: dev's v5 is not prod's v5. |
| Config versions owned by Terraform | The old version is **deleted** when the content changes, so it can't be deployed again. |

## 4. How to classify a change

Ask two questions about the PR:

1. **Does the live Lambda version work with the new config?**
   - Yes, and there's no code change: **Type 1**.
   - No: **Type 3**. The new code has to be written so that question 2 is "yes".
2. **Does the new Lambda version work with the live config?**
   - Yes, and there's no config change: **Type 2**.
   - In Type 3 this must be **yes**. That's what "defaults added" guarantees.

"Live Lambda version" includes **the version you'd roll back to**. A config change that the
current code handles, but that breaks your rollback target, isn't Type 1 yet.

Both questions can be checked in CI (section 8), so nobody has to classify by hand.

## 5. Type 1: config only

```
PR     edit config/dev.json (+ config/prod.json)          Settings schema unchanged
       CI: both files decode against the live schema
merge
 ├─ dev   new config version → deploy to `dev` → smoke test → you test in dev
 └─ prod  approval → new config version → deploy to `prod` → smoke test
Lambda: untouched in both accounts
```

- **Examples:** change the greeting text; turn an existing flag on or off.
- **Rollback:** deploy the previous config version to the environment again. You land in a
  state that was live before, so it's safe. This needs **old versions kept** (section 10.3).
  Running Lambdas switch back within 45 s.

> **Gap to decide: what does "the same config" mean in prod?** `config/dev.json` and
> `config/prod.json` are separate files. Testing in dev proves dev's *values*, plus the shape
> and the code path. Prod's *values* are only schema-checked and reviewed in the PR. See open
> question 1.

## 6. Type 2: Lambda only

```
PR     code change, config files unchanged
merge
 ├─ dev   publish Lambda version N → live → N → smoke test → you test in dev
 └─ prod  approval → publish → live → N → smoke test
AppConfig: untouched
```

- **Rollback:** `live` → the previous version. The config never changed, so that's the exact
  state that ran before.

## 7. Type 3: Lambda + breaking config

### 7.1 Why Lambda first

The two switches can't happen as one atomic step, so one mixed state is live in between.
Going Lambda first means that state is *new code with old config*:

```
(L1, C1) ──► (L2, C1) ──► (L2, C2)
   before      mixed        after
```

The new code is written to read the old config, so the mixed state works. It's also exactly
where you land if the config step goes wrong and you undo it. That's why the rule is "new
Lambda version first, with defaults".

Config first would put *old code on new config* in the middle, and by definition of Type 3
the old code can't read the new config. That's an outage.

### 7.2 What "works with the old config" means for each kind of change

A default is enough only for added fields:

| Breaking change | How the new code handles the old config | Effect Schema |
|---|---|---|
| Add a field | Give it a default | `maxItems: Schema.optionalWith(Schema.Number, { default: () => 50 })` |
| Remove a field | Stop reading it; the extra key in the old config is ignored | nothing needed |
| Rename a field | Read the new name, fall back to the old one | both `Schema.optional(...)`, then `welcomeMessage ?? greeting` |
| Change a type or unit | Accept both forms and normalise | `Schema.Union(Schema.Number, Schema.String)`, then convert |
| Same field, new meaning | The code can't tell old from new | Don't do it: use a new field name, which makes it "Add a field" |

> **Defaults are for the switch-over, not for prod.** A default also hides a field you forgot to
> put in the real config: the code "works" with the wrong value. CI must check that the config
> files set every field (section 8, check 4).

### 7.3 Flow

```
PR     schema + code change (tolerant of old config) + config change
       CI: all four checks in section 8
merge
 ├─ dev   publish L2 → live → L2 → [config: new version → deploy to dev] → smoke test → you test
 └─ prod  approval → same order
```

Within each stage, the Lambda step finishes before the config deploys.

### 7.4 Rollback: reverse order, with one trap

| What broke | Action | You land in | Safe? |
|---|---|---|---|
| The new config (the code is fine) | Deploy the previous config version | (L2, C1) | ✓ the new code reads old config (7.2) |
| The new code, **before** the config step ran | `live` → L1 | (L1, C1) | ✓ what ran before |
| The new code, **after** the config deployed | **First** the previous config, **then** `live` → L1 | (L2, C1) → (L1, C1) | ✓ reverse order |
| Same, but only `live` → L1 is rolled back | none | (L1, C2) | **✗ the old code can't read the new config** |

**How to keep "roll back only the Lambda" possible:** for one release, the new config keeps
the old fields alongside the new ones. For example, it contains both `greeting` and
`welcomeMessage`. Then (L1, C2) works and the Lambda can be rolled back on its own. A later
Type 1 release removes the old fields, once L1 isn't a rollback target any more. This works
for renames and removals. It can't work for a type change in place, so use a new field name
instead.

### 7.5 Worked examples

| Change | Type | Plan |
|---|---|---|
| New greeting text | 1 | Config-only release |
| New code needs `maxItems` | 3 | L2 has `maxItems` with a default 50 → deploy config with `maxItems: 100` |
| Rename `greeting` → `welcomeMessage` | 3 | L2 reads `welcomeMessage ?? greeting` → config has **both** (so the Lambda can roll back alone) → later Type 1 removes `greeting` |
| Timeout from seconds to milliseconds | 3 | Add `timeoutMs` (default derived from `timeout`) → config sets `timeoutMs` → later Type 1 removes `timeout` |
| Remove the `betaBanner` feature | 2 then 1 | L2 stops reading it; the config still has it, which is harmless → later Type 1 removes it |

## 8. CI checks (proposal): classification done by the machine

"Live" means the version on `main`. These four checks cover every state a release passes
through:

| # | Decode | Represents | Must pass when |
|---|---|---|---|
| 1 | PR's config with PR's schema | (L2, C2) the end state | always (this exists today) |
| 2 | `main`'s config with PR's schema | (L2, C1) Type 3's mixed state, and rolling back the config | the schema changed |
| 3 | PR's config with `main`'s schema | (L1, C2) Type 1 safety, and rolling back only the Lambda | the config changed and the schema didn't (Type 1). Otherwise reported only: it tells you whether a Lambda-only rollback is safe |
| 4 | PR's config sets every field, with no defaults used | forgotten fields | always |

Check 3 failing on a PR with no schema change means "this needs code": the PR can't go out as
Type 1.

## 9. Pipeline order

Every pipeline run deploys the whole of `main`. Per stage it runs **Lambda first, then
config**:

```
Lambda: publish if the code changed → live → new version   ──►   config: new version if the file changed → deploy → COMPLETE   ──►   smoke test
```

- **Type 1:** the Lambda step does nothing. **Type 2:** the config step does nothing.
  **Type 3:** both steps run, in the required order.
- **In Terraform:** `aws_appconfig_deployment` depends on `aws_lambda_alias.live`. The working
  tree has the **opposite** today: the Lambda depends on the deployment. That has to flip.

## 10. What this means for implementation (not done)

1. **Remove `APPCONFIG_VERSION` from the Lambda.** Type 1 must never publish a Lambda
   version (R4).
2. **Flip the Terraform dependency** so the Lambda goes before the config (section 9).
3. **Keep old config versions** so "deploy the previous config version" is possible (R7). That
   means the pipeline creates the versions with the AWS CLI and never deletes them, and
   Terraform stops owning versions. The existing version 1 moves over with a `removed { destroy
   = false }` block. Without this, config rollback is only a git revert: a new version with the
   old content, and a full pipeline run.
4. **A rollback workflow:** manual, with inputs `config_version` and/or `lambda_version`. It
   applies them in reverse order (config, then Lambda). Prod needs approval.
5. **The CI checks** in section 8.
6. **Schema convention:** a new field always gets a default. Renames and type changes follow
   the table in 7.2.

## 11. Open questions

1. **dev vs prod values:** one shared file with per-env overrides, so prod gets exactly what
   dev tested? Or separate files, with prod values only reviewed?
2. **Config rollback:** the fast path (keep versions; pipeline-owned, 10.3) or git revert only?
3. **CI checks (section 8):** all four, or just 1 and 4 to start?
4. **Testing in dev:** manual, or an automated suite that must pass before prod approval?
5. **Type 3 in prod:** keep the old fields for one release by default (7.4), so the Lambda can
   always be rolled back on its own?
6. **Prod deployment strategy:** instant, or gradual with CloudWatch-alarm rollback? Gradual
   needs the pipeline to wait for COMPLETE.
7. **ALB (R9):** request an SCP exception in aws-foundation, or stay on Function URLs?

## Appendix: alternatives considered

| Alternative | Why not |
|---|---|
| Config first, with config changes that only add | Also sound. But "Lambda first, with code that reads the old config" covers removals, renames and type changes with a single rule |
| A `dev-canary` environment chosen by alias | Works, but `dev` itself is the test stage |
| Pin the config version number in the Lambda (control-plane read) | No extension, capped at 100/s, and every config change needs a Lambda publish |
| One AppConfig environment per config version | A Lambda publish per config change, and environment sprawl (quota 20) |
| Two profiles as alternating slots | Stages disguised as profiles. A new profile stays an option for a very large shape change |
