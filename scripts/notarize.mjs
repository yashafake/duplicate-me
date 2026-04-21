import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const projectRoot = process.cwd();
const packageJson = JSON.parse(readFileSync(resolve(projectRoot, "package.json"), "utf8"));
const version = packageJson.version;

const args = new Set(process.argv.slice(2));
const targetPath = resolveTargetPath(args);

if (!existsSync(targetPath)) {
  throw new Error(`Nothing to notarize at ${targetPath}`);
}

const credentialArgs = resolveCredentialArgs();
if (!credentialArgs) {
  console.log("notarization=skipped");
  console.log("reason=missing APPLE_NOTARY_PROFILE or APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD/APPLE_TEAM_ID");
  process.exit(0);
}

console.log(`notarizing=${targetPath}`);

execFileSync(
  "xcrun",
  ["notarytool", "submit", targetPath, "--wait", ...credentialArgs],
  {
    cwd: projectRoot,
    stdio: "inherit",
  },
);

execFileSync(
  "xcrun",
  ["stapler", "staple", "-v", targetPath],
  {
    cwd: projectRoot,
    stdio: "inherit",
  },
);

execFileSync(
  "xcrun",
  ["stapler", "validate", "-v", targetPath],
  {
    cwd: projectRoot,
    stdio: "inherit",
  },
);

console.log(`notarization=done`);
console.log(`target=${targetPath}`);

function resolveTargetPath(rawArgs) {
  if (rawArgs.has("--app")) {
    return resolve(projectRoot, "dist/electron/mac-arm64/DuplicateMe.app");
  }

  if (rawArgs.has("--dmg")) {
    return resolve(projectRoot, `dist/electron/DuplicateMe-${version}-arm64.dmg`);
  }

  const explicit = process.argv.slice(2).find((value) => !value.startsWith("--"));
  if (explicit) {
    return resolve(projectRoot, explicit);
  }

  return resolve(projectRoot, "dist/electron/mac-arm64/DuplicateMe.app");
}

function resolveCredentialArgs() {
  if (process.env.APPLE_NOTARY_PROFILE) {
    return ["--keychain-profile", process.env.APPLE_NOTARY_PROFILE];
  }

  const appleID = process.env.APPLE_ID;
  const password = process.env.APPLE_APP_SPECIFIC_PASSWORD;
  const teamID = process.env.APPLE_TEAM_ID;

  if (!appleID || !password || !teamID) {
    return null;
  }

  return [
    "--apple-id",
    appleID,
    "--password",
    password,
    "--team-id",
    teamID,
  ];
}
