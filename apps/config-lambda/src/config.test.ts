import { readdirSync, readFileSync } from "node:fs"
import { Effect, Layer, Schema } from "effect"
import { expect, it } from "vitest"
import { AppConfig, AppConfigError, AppConfigFile, Settings } from "./config"
import { program } from "./handler"

it.each(readdirSync("config"))("config/%s matches Settings", (file) => {
  Schema.decodeUnknownSync(Schema.parseJson(Settings))(
    readFileSync(`config/${file}`, "utf8"),
  )
})

it("returns the config", async () => {
  const res = await Effect.runPromise(
    program.pipe(Effect.provide(AppConfigFile("config/dev.json"))),
  )
  expect(res.statusCode).toBe(200)
  expect(JSON.parse(res.body ?? "")).toEqual(
    JSON.parse(readFileSync("config/dev.json", "utf8")),
  )
})

it("returns 500 without leaking the cause", async () => {
  const broken = Layer.succeed(AppConfig, {
    get: Effect.fail(new AppConfigError({ cause: "secret detail" })),
  })
  const res = await Effect.runPromise(program.pipe(Effect.provide(broken)))
  expect(res.statusCode).toBe(500)
  expect(res.body).not.toContain("secret detail")
})
