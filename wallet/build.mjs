// COINFORCE cüzdan paketi derlemesi: npm ci --ignore-scripts && node build.mjs cf-wallet-1.1.0.js
// Çıktının sha384 değeri index.html içindeki WK_SRI ile aynı olmalı.
import * as esbuild from "esbuild";
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { resolve } from "path";
const stubWs = { name: "stub-ws", setup(b) { b.onResolve({ filter: /^rpc-websockets$/ }, () => ({ path: resolve("src/ws-stub.js") })) } };
const out = process.argv[2] || "dist/cf-wallet.js";
await esbuild.build({ entryPoints: ["src/core.js"], bundle: true, format: "iife", globalName: "CFW", platform: "browser", target: ["es2020", "safari15"],
  minify: true, legalComments: "eof", define: { "process.env.NODE_ENV": '"production"', global: "globalThis" }, outfile: out, logLevel: "warning", metafile: true, plugins: [stubWs] }).then(r => r);
const b = readFileSync(out); console.log(out, (b.length / 1024).toFixed(1) + " KB", "sha384-" + createHash("sha384").update(b).digest("base64"));
