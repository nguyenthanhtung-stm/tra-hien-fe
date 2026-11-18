import { defineConfig } from "@playwright/test";

// Explicit opt-in: isolated real API/PG17 and a local TLS proxy must already be running.
export default defineConfig({
  testDir: "tests/iam", workers: 1, retries: 0, timeout: 120_000,
  outputDir: "../../artifacts/p0-12-iam-browser", reporter: "list",
  use: { baseURL: process.env.ADMIN_IAM_BASE_URL ?? "https://admin.localhost:8443", browserName: "chromium", screenshot: "off", trace: "off",
    launchOptions: { args: process.env.ADMIN_LOCAL_CA_SPKI ? [`--ignore-certificate-errors-spki-list=${process.env.ADMIN_LOCAL_CA_SPKI}`] : [] } }
});
