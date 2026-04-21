import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFileSync } from "node:child_process";

const projectRoot = resolve(new URL("..", import.meta.url).pathname);
const packageJsonPath = resolve(projectRoot, "package.json");
const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));

const appName = "DuplicateMe.app";
const sourceApp = resolve(projectRoot, "dist/electron/mac-arm64", appName);

if (!existsSync(sourceApp)) {
  throw new Error(`Expected packaged app at ${sourceApp}. Run "npm run desktop:dir" first.`);
}

const outputDir = resolve(projectRoot, "dist/electron");
const dmgName = `DuplicateMe-${packageJson.version}-arm64.dmg`;
const outputDmg = resolve(outputDir, dmgName);
const stagingDir = mkdtempSync(join(tmpdir(), "duplicate-me-dmg-"));

try {
  cpSync(sourceApp, join(stagingDir, appName), { recursive: true });
  symlinkSync("/Applications", join(stagingDir, "Applications"));

  execFileSync(
    "hdiutil",
    [
      "create",
      "-volname",
      "DuplicateMe",
      "-srcfolder",
      stagingDir,
      "-ov",
      "-format",
      "UDZO",
      outputDmg,
    ],
    {
      cwd: projectRoot,
      stdio: "inherit",
    },
  );

  console.log(`dmg_path=${outputDmg}`);
} finally {
  rmSync(stagingDir, { recursive: true, force: true });
}
