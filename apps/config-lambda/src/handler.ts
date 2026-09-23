import type { APIGatewayProxyStructuredResultV2 } from "aws-lambda"
import { Effect, type Layer, ManagedRuntime } from "effect"
import { AppConfig, AppConfigExtension } from "./config"

const json = (
  statusCode: number,
  body: unknown,
): APIGatewayProxyStructuredResultV2 => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
})

export const program = Effect.gen(function* () {
  const config = yield* AppConfig
  return json(200, {
    // Both set when the Lambda version was published: its number (by Lambda) and the
    // AppConfig version deployed at that moment (by infra/main.tf).
    lambdaVersion: process.env.AWS_LAMBDA_FUNCTION_VERSION ?? "local",
    configVersion: process.env.APPCONFIG_VERSION ?? "local",
    settings: yield* config.get,
  })
}).pipe(
  // The URL is public: log the cause, return nothing about it.
  Effect.catchTag("AppConfigError", (e) =>
    Effect.logError("config unavailable", e.cause).pipe(
      Effect.as(json(500, { error: "config unavailable" })),
    ),
  ),
)

export const makeHandler = <E>(layer: Layer.Layer<AppConfig, E>) => {
  const runtime = ManagedRuntime.make(layer)
  return () => runtime.runPromise(program)
}

export const handler = makeHandler(AppConfigExtension)
