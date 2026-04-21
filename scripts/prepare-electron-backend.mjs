import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";

const repoRoot = process.cwd();
const outputDir = path.join(repoRoot, ".electron", "backend");

function swiftBuild(configuration) {
  execFileSync("swift", ["build", "-c", configuration], {
    cwd: repoRoot,
    stdio: "inherit",
  });

  return execFileSync("swift", ["build", "-c", configuration, "--show-bin-path"], {
    cwd: repoRoot,
    encoding: "utf8",
  }).trim();
}

const binPath = swiftBuild("release");
const binaryPath = path.join(binPath, "duplicate-me");
const bundlePath = path.join(binPath, "DuplicateMe_ScanCLI.bundle");

if (!existsSync(binaryPath)) {
  throw new Error(`Missing backend binary at ${binaryPath}`);
}

if (!existsSync(bundlePath)) {
  throw new Error(`Missing ScanCLI bundle at ${bundlePath}`);
}

rmSync(outputDir, { recursive: true, force: true });
mkdirSync(outputDir, { recursive: true });
cpSync(binaryPath, path.join(outputDir, "duplicate-me"));
cpSync(bundlePath, path.join(outputDir, "DuplicateMe_ScanCLI.bundle"), { recursive: true });

console.log(`Bundled backend into ${outputDir}`);

