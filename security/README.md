# BoxEU security gate

The gate runs locally before commit/push and in CI before publishing an image. It blocks every reported vulnerability severity, source-code security finding, detected credential and failed scanner. Unfixed vulnerabilities remain blocking. There are no blanket exclusions or accepted vulnerability baselines.

## Local workflow

Requirements: Python 3.12 or newer, Docker, and internet access for verified scanner installation, vulnerability databases and image builds.

```sh
python3 scripts/security-check.py setup --install-hooks
python3 scripts/security-check.py scan --source-only
python3 scripts/security-check.py scan
python3 scripts/security-report.py
```

`--source-only` checks dependency locks, configuration, source code, tracked/unignored files and complete reachable Git history. A Go module advisory may additionally require its declared image to establish package applicability. The full command builds and scans all Linux amd64 images declared in `project.json` and generates CycloneDX SBOMs.

The pre-commit hook inspects the actual Git index for credentials. The pre-push hook reads every outgoing ref from Git, exports each distinct commit into a temporary directory and scans that exact commit, its reachable history and its built images. Unstaged or newer working-tree edits cannot hide a problem in an outgoing commit. Branch and tag deletion performs no code publication. Existing unrelated hooks are never replaced automatically.

Private reports and scanner executables are under `.local/security`. Reports are excluded from Git and Docker build contexts; detected credential values are redacted. Semgrep receives only a read-only source snapshot and a report directory, runs without networking or additional Linux capabilities, and does not upload source to a cloud service. Trivy/Gitleaks archives are verified against repository-pinned SHA-256 values. The Semgrep image and vendored rules use immutable references.

`security-report.py --workspace` consolidates completed scans from available sibling repositories, including each advisory, affected version and published fix. Source and built-image findings are separate; a clean source scan does not validate its image. Workflow syntax is checked with a pinned Actionlint executable.

Fast source scans use `reports/working-tree-source`; complete scans use `reports/working-tree`. A source-only pass never replaces the previous complete image findings.

## Dependency changes

Commit JavaScript manifests and their corresponding lockfiles together. Gradle dependency locks are strict; ordinary builds never silently update them. After a reviewed Java dependency change:

```sh
./gradlew resolveAndLockAll --write-locks --write-verification-metadata sha256
python3 scripts/security-check.py scan
```

Review new artifact checksums before committing verification metadata. Checksums establish reproducibility against reviewed artifacts; they do not establish that an artifact is safe. Trivy scans both locked dependencies, including development dependencies, and the packaged image.

## CI and deployment

CI verifies pull requests once and releases default-branch pushes. A branch without a pull request can run `Container verification` manually; it does not also spend minutes on every branch push. Actions use complete commit SHA references and checkout does not persist GitHub credentials. There is one authoritative `Security gate` check per event. Verification has only read permissions. Release separates read-only source/application checks from package-write publication; a failed prerequisite makes publication fail. CI never deploys Selectel or receives its SSH credentials.

Application checks compile once. Where an application artifact exists, CI transfers only its bounded checked output and receipt through an immutable artifact ID from the same run. The publisher verifies the source tree, complete revision, repository/ref, run identity and artifact checksums before packaging; local security builds still compile from source. Every exact image receives a fresh blocking scan and SBOM before registry login and publication. Revision tags publish before existing moving tags advance. Machine-owned `ci/project.json`, `scripts/ci-checks.sh` and the shared actions/helper own the recipes and qualification details.

Daily verification queries GitHub for a completely successful release of the exact current default-branch revision. Only then can it skip application tests/recompilation and freshly scan the published registry digests, checking source/revision/schema labels and the complete declared image set. Source/history/dependency analysis still runs. Without a qualifying release it runs all application/build/image checks; API, authentication, missing images and scanner errors block instead of falling back to a green result. A scheduled check cannot publish. Infrastructure validates configuration against its already scanned immutable gateway image, without building that image twice.

Dependabot groups routine minor/patch version updates per ecosystem to reduce repeated full checks. Security updates and major upgrades remain separate; proposals are never automatically approved or merged.

CI may restore checksum-verified tool archives, Trivy advisory databases, locked dependency downloads and BuildKit layers; it never restores application/test outputs, reports, passing gate results, credentials or Go applicability proofs. The scanner's opt-in `BOXEU_BUILDX_CACHE=true` uses a configured Buildx builder and per-image local cache exports under `.local/security/buildkit-cache`. Restored layers still go through pinned source/base resolution and fresh scans of the resulting immutable image. Trivy retains its normal advisory-update checks, and Go package analysis contacts the current advisory database on every scan. Cache misses are a performance condition and never a reason to skip a gate.

Pinned tool archives and advisory inputs have separate caches. Advisory input keys rotate by week and job purpose to avoid retaining a large database copy per commit/day and to let image jobs retain their Java analysis input. Every invocation still performs normal advisory-update checks; the cache period never sets an advisory freshness allowance. Build layers have separate scopes and revision keys.

Published registry digest inputs are scanned directly from that immutable registry artifact, using the operator's existing Docker registry credentials. The gate requires the digest in the pulled image's `RepoDigests`, a Linux AMD64 single-platform manifest, and matching local manifest/configuration identity and scanner configuration digest. This accounts for Docker's legacy configuration IDs and containerd manifest IDs. It avoids OCI export failures without falling back after a failed scan or trusting a moving tag. Unpublished CI/local candidates are scanned by their immutable Docker image ID. SBOM generation checks the same immutable scan target. Registry mode is supported by [Trivy's container image scanner](https://trivy.dev/docs/dev/guide/target/container_image/).

Infrastructure `deploy.sh` and `update.sh` scan every selected candidate before the first migration or restart and pin the operation to scanned image digests. They fail closed on scanner, database-download and vulnerability failures. Initial deployment also scans PostgreSQL, Redis, the gateway and the built tunnel wrapper. These checks do not authorize or perform deployment by themselves.

Git hooks can be bypassed and are not a server trust boundary. Enable the repository's `main-branch-ruleset.json` on GitHub to require a pull request and the `Security gate` status without bypass actors. Private-repository rules require an eligible GitHub plan. CODEOWNERS identifies security policy ownership; it does not enforce review without server rules. Repository files do not configure GitHub account settings by themselves.

## Handling findings

Read the local report, verify applicability and update to a compatible fixed release or correct the implementation. Fix a false positive at its precise source when practical. Do not add inline scanner exclusions, ignore files or a global CVE baseline to obtain a green build. Any future exception mechanism requires a separate reviewed decision with exact scope, owner, rationale and expiration.

For `GO-2026-5932` only, the affected deprecated OpenPGP packages can be absent even when the Go crypto module is present. The gate retains the original finding and records `NOT_AFFECTED` only after fresh verification of the exact immutable image: a compiler dependency receipt bound to the binary SHA-256, an independently extracted binary inventory, and pinned Govulncheck package analysis against the current Go advisory database. If the package is present, the receipt is missing/mismatched, analysis fails, another linked vulnerability exists, or the advisory scope changes, the gate blocks. Evidence is regenerated for each scan; no user-supplied exclusion or previous proof is trusted.

Trivy covers known dependency/OS vulnerabilities, supported configuration formats and credential patterns. Gitleaks additionally covers Git history. The vendored Semgrep rules cover selected injection, TLS, deserialization, cryptography and browser risks. Trivy does not analyze ordinary Docker Compose security semantics; review Compose isolation, mounted-file permissions and application authorization separately. Static scans do not prove business authorization, tenant isolation, runtime configuration or the absence of unknown vulnerabilities.

## Policy ownership

`boxeudelivery-infrastructure/security/policy` owns common scanner scripts, hooks, tool pins and rules. Every repository keeps a standalone copy and its own `security/project.json`; no sibling checkout is needed in CI.

After editing the canonical policy in the complete workspace:

```sh
python3 scripts/sync-security-policy.py
python3 scripts/sync-security-policy.py --check
```

Commit synchronized policy updates in all affected independent repositories. Exact tool versions and checksums belong to `toolchain.json`; vendored rule provenance and license belong to `semgrep-rules`.
