import { readFile } from "node:fs/promises"
import { Config, Context, Data, Effect, Layer, Schema } from "effect"

// The shape of the AppConfig profile. The Lambda decodes every read with it, and
// config.test.ts decodes config/*.json with it, so a bad edit fails the PR, not prod.
export const Settings = Schema.Struct({
  greeting: Schema.String,
  features: Schema.Struct({ betaBanner: Schema.Boolean }),
})
export type Settings = typeof Settings.Type

export class AppConfigError extends Data.TaggedError("AppConfigError")<{
  readonly cause: unknown
}> {}

export class AppConfig extends Context.Tag("AppConfig")<
  AppConfig,
  { readonly get: Effect.Effect<Settings, AppConfigError> }
>() {}

const decode = Schema.decodeUnknown(Schema.parseJson(Settings))

const fromText = (load: Effect.Effect<string, unknown>) =>
  AppConfig.of({
    get: load.pipe(
      Effect.flatMap(decode),
      Effect.mapError((cause) => new AppConfigError({ cause })),
    ),
  })

// Prod: the AWS AppConfig Lambda extension polls AppConfig and caches, so each read
// is a localhost call, not an AWS API call. Names come from env vars set in infra/.
export const AppConfigExtension = Layer.effect(
  AppConfig,
  Effect.gen(function* () {
    const { port, app, env, profile } = yield* Config.all({
      port: Config.integer("AWS_APPCONFIG_EXTENSION_HTTP_PORT").pipe(
        Config.withDefault(2772),
      ),
      app: Config.string("APPCONFIG_APPLICATION"),
      env: Config.string("APPCONFIG_ENVIRONMENT"),
      profile: Config.string("APPCONFIG_PROFILE"),
    })
    const url = `http://localhost:${port}/applications/${app}/environments/${env}/configurations/${profile}`
    return fromText(
      Effect.tryPromise(async () => {
        const res = await fetch(url)
        if (!res.ok) throw new Error(`${res.status} ${await res.text()}`)
        return res.text()
      }),
    )
  }),
)

// Local dev and tests: same decoding, read from a file.
export const AppConfigFile = (path: string) =>
  Layer.succeed(
    AppConfig,
    fromText(Effect.tryPromise(() => readFile(path, "utf8"))),
  )
