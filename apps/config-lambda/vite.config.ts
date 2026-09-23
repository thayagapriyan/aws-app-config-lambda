import { resolve } from "node:path"
import { defineConfig, type Plugin } from "vite"

// `pnpm dev` serves the handler on http://localhost:5173 with config/dev.json in place
// of the AppConfig extension, so no AWS credentials are needed. The file is re-read
// on every request, so edits show up without a restart.
const lambdaDev = (): Plugin => ({
  name: "lambda-dev",
  configureServer(server) {
    server.middlewares.use(async (_req, res, next) => {
      try {
        const { makeHandler } = await server.ssrLoadModule("/src/handler.ts")
        const { AppConfigFile } = await server.ssrLoadModule("/src/config.ts")
        const file = resolve(server.config.root, "config/dev.json")
        const result = await makeHandler(AppConfigFile(file))()
        res.writeHead(result.statusCode, result.headers).end(result.body)
      } catch (e) {
        next(e)
      }
    })
  },
})

// Prod: one self-contained ESM file (effect bundled in) that infra/ zips.
export default defineConfig({
  plugins: [lambdaDev()],
  ssr: { noExternal: true },
  build: {
    ssr: "src/handler.ts",
    target: "node24",
    outDir: "dist",
    rolldownOptions: { output: { entryFileNames: "index.mjs" } },
  },
})
