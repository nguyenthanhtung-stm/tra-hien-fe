import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import openapiTS, { astToString } from "openapi-typescript";
import ts from "typescript";

// The backend lives in its own repository. Read the contract from a running API
// (Development exposes /openapi/v1.json) or from a saved file via OPENAPI_FILE.
const openapiUrl = process.env.OPENAPI_URL ?? "http://localhost:8080/openapi/v1.json";
let document;
if (process.env.OPENAPI_FILE) {
  document = JSON.parse(await readFile(process.env.OPENAPI_FILE, "utf8"));
} else {
  let response;
  try {
    response = await fetch(openapiUrl, { headers: { Accept: "application/json" } });
  } catch (error) {
    throw new Error(`Cannot reach backend OpenAPI at ${openapiUrl}. Start the backend or set OPENAPI_URL/OPENAPI_FILE.`, { cause: error });
  }
  if (!response.ok) throw new Error(`Backend OpenAPI ${openapiUrl} returned HTTP ${response.status}.`);
  document = await response.json();
}
// A running API adds its own host to "servers"; drop it so output does not depend on where BE runs.
delete document.servers;
if (!document.openapi?.startsWith("3.") || !document.paths || !document.info) {
  throw new Error("API did not generate a valid OpenAPI contract");
}
// Stable key ordering/newlines across Windows and Linux; never remove paths or schemas.
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
const json = JSON.stringify(canonical(document), null, 2) + "\n";
// TypeScript cannot recursively index a component's own property (TS2502).
// Hoist this JSON union into a named recursive alias, deriving its complete body
// from the API schema rather than maintaining a second handwritten JSON model.
const jsonName = "SettingsJsonValue";
const aliases = [];
const ast = await openapiTS(JSON.parse(json), {
  alphabetize: true,
  postTransform(type, { path }) {
    if (path !== `#/components/schemas/${jsonName}`) return;
    const rewritten = ts.transform(type, [(context) => (root) => {
      function visit(node) {
        if (ts.isIndexedAccessTypeNode(node)
          && node.indexType.literal?.text === jsonName
          && ts.isIndexedAccessTypeNode(node.objectType)
          && node.objectType.indexType.literal?.text === "schemas"
          && ts.isTypeReferenceNode(node.objectType.objectType)
          && node.objectType.objectType.typeName.text === "components") {
          return ts.factory.createTypeReferenceNode(jsonName);
        }
        return ts.visitEachChild(node, visit, context);
      }
      return ts.visitNode(root, visit);
    }]);
    aliases.push(ts.factory.createTypeAliasDeclaration(
      [ts.factory.createModifier(ts.SyntaxKind.ExportKeyword)], jsonName, undefined, rewritten.transformed[0],
    ));
    rewritten.dispose();
    return ts.factory.createTypeReferenceNode(jsonName);
  },
});
const types = "// Generated from the actual API by corepack pnpm generate:api. Do not edit.\n"
  + astToString([...aliases, ...ast]).replaceAll("\r\n", "\n");
const targets = [
  [new URL("./openapi.json", import.meta.url), json],
  [new URL("./src/generated/schema.ts", import.meta.url), types],
];
const check = process.argv.includes("--check");
for (const [target, content] of targets) {
  if (check) {
    const committed = await readFile(target, "utf8");
    if (committed.replaceAll("\r\n", "\n") !== content) {
      throw new Error(`Stale generated output: ${fileURLToPath(target)}. Run corepack pnpm generate:api.`);
    }
  } else {
    await mkdir(new URL(".", target), { recursive: true });
    await writeFile(target, content);
  }
}
console.log(check ? "OpenAPI/client are current." : "OpenAPI/client generated.");
