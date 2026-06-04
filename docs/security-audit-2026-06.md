# Sandbox Security & Readiness Audit (2026-06)

Scope: `bin/sandbox`, `docker/` (browser + egress images), `verify.sh`,
`test/fulltest.sh`, `README.md`. The sibling `vm/` (Tart macOS VM) subsystem and
the `docs/` capability notes were out of scope for this pass.

Method: four adversarial review rounds, each fix validated, then both gate
suites re-run live to green. The governing constraint throughout: every
capability is opt-in, and the proven default recipe-runner path stays
byte-identical when its flags are unused. No default behavior was changed.

## Verdict

Green. The sandbox is a hardened, capability-dropped, egress-controlled
browser/compute container with a non-root runtime, pinned and checksum-verified
supply chain, and a fail-closed network boundary. The findings below were fixed;
a separate set of "hardening theater" proposals were rejected with reasons so a
future reviewer does not re-litigate them.

Evidence (live, this pass):
- `verify.sh` -> PASS=8 FAIL=0 (build, navigate+extract, non-root + CapEff=0, no
  container leak after settle, egress allow-list passes allowed + blocks others).
- `test/fulltest.sh` -> PASS=76 FAIL=0 across 34 test groups.
- Hardened `cf-get` (FlareSolverr `v3.5.0`, `--cap-drop ALL`) -> `{"ok": true}`.

## Baseline hardening (already in force, confirmed)

Per-run container flags: `--cap-drop ALL`, `--security-opt no-new-privileges`,
`--pids-limit 512`, `--memory == --memory-swap` (swap disabled), `--cpus`,
`--shm-size 1g`, `--tmpfs /tmp`, `--rm`, non-root `sandbox` user (UID from
`useradd`), scoped `/work` bind for deliverables only. `--readonly` is opt-in.
CapEff is `0000000000000000` at runtime (verified by direct introspection).

Network model: default `bridge`; `--offline` -> `--network none`; `--allow a,b`
puts the browser on an `--internal` network with no route to the internet and
routes egress through a tinyproxy sidecar that default-denies and allows only the
listed host suffixes. The proxy sits on the internal net; only the proxy can
reach the bridge.

## Round 1 - container & network security

Fixed:
- FlareSolverr sidecar pinned from `:latest` to `:v3.5.0` (tag existence and
  digest confirmed via `docker manifest inspect`). Floating `:latest` is a
  supply-chain and reproducibility hole.
- FlareSolverr `docker run` gained `--cap-drop ALL` and `--cpus 2` on top of the
  existing `no-new-privileges` + pid/memory/shm caps. (The earlier claim that the
  sidecar had "no limits" was false; the only real gap was missing cap-drop.)
  Live `cf-get` confirms the capability drop does not break the Chromium-based
  solver.

Rejected (with reason):
- Custom seccomp / AppArmor profiles, `--userns-remap`: on macOS Docker Desktop
  AppArmor is absent and userns is a daemon-level setting; a custom seccomp
  profile risks silently breaking Chromium syscalls and mutates the proven path.
  The default Docker seccomp profile plus `cap-drop ALL` + `no-new-privileges`
  already removes the privileged-syscall surface this would target.
- `--read-only` as the default: breaks profile persistence and the `/work`
  deliverable model. Kept opt-in (`--readonly`), which T20 proves works.
- `--ipc private` / `--cgroupns private`: already the Docker default; adding the
  flags is a no-op.

## Round 2 - code correctness & shell robustness

Fixed:
- `cmd_spider` built its crawl recipe by `printf`-ing the user URL straight into
  a JSON string, so a URL containing `"` or `\` could break out of the JSON or
  inject recipe steps. Replaced with a `python3` heredoc that `json.dumps()` the
  URL and op, plus an integer guard on `--max-pages` (`die` on non-numeric).
  Round-trip proven byte-for-byte on adversarial input.
- Egress allow-list built its tinyproxy filter regex by escaping only dots, so an
  entry like `example.com.*` widened the filter toward allow-everything. Now the
  loop fails closed on any entry that is not `^[A-Za-z0-9.-]+$` and escapes every
  non-alphanumeric character before anchoring as `(^|\.)host$`. Verified under
  bash: `example.com.*` and `evil(.)com` are rejected; valid hosts are escaped
  literally.
- Added `FilterCaseSensitive Off` so host matching is not bypassable by case.

Rejected (with reason):
- Rewriting the heredoc-based recipe plumbing to use `jq`: would add a runtime
  dependency the image does not carry. `python3` is already present and is the
  established pattern (the `cf-get` path already uses a `python3` heredoc).

## Round 3 - red team: escape, egress bypass, supply chain

Findings here overlapped Rounds 1-2 and were closed by those fixes. Confirmed no
residual:
- Egress bypass via regex-injection in `--allow`: closed (Round 2 validation +
  fail-closed).
- Egress bypass via case or URL-path tricks: `FilterCaseSensitive Off`,
  `FilterURLs Off`, `ConnectPort` restricted to 443/563. The browser has no route
  to the bridge except through the proxy (internal network).
- Recipe/JSON injection through crawl URLs: closed (Round 2 `json.dumps`).
- Unpinned/unverified downloads: see Round 4 supply chain.

## Round 4 - enterprise polish

Fixed:
- Supply-chain integrity. The two build-time binary fetches are now
  checksum-verified: axe-core 4.12.0 (`sha256 a0afc408...dece`) and vegeta
  v12.13.0 (per-arch sha256, arm64/amd64, unsupported arch fails the build). A
  wrong checksum fails `docker build` at the verifying layer; the build is green,
  so the pins are correct.
- `SHELL ["/bin/bash","-o","pipefail","-c"]` set before the checksum-verifying
  RUNs so a fetch that fails mid-pipe fails the build (hadolint DL4006). Both
  Dockerfiles now lint clean (T30). The lint config (`.hadolint.yaml`) suppresses
  only DL3008 (apt pinning) with a documented rationale and hides no security
  rule, so this is a real fix, not config suppression.
- OCI image labels (`title`, `description`, `base.name`) for provenance.
- README recipe-op list reconciled with `driver.py` (added `discover_feeds`,
  `discover_sitemaps`, `spider_crawl`, `axe`).
- `verify.sh` stage 4: removed a no-op `grep` typo and replaced a racy
  leftover-container assertion with a settle-retry loop (async `--rm` teardown can
  linger ~1s); a genuine leak still fails.
- Removed orphaned, zero-reference artifacts staged for since-rejected features:
  `mitmproxy-12.2.3-py3-none-any.whl`, `pixelmatch-7.2.0.tgz`, and a regenerable
  `docker/__pycache__/` bytecode directory.

Rejected (with reason):
- Mass `pip` version pinning across all seven venvs + multi-stage slimming: high
  churn and regression risk against the proven venvs for marginal benefit; the
  recipe runner already pins `playwright==1.49.0`, the security-relevant pin.
  Surfaced as a deliberate maintenance tradeoff rather than done silently.
- `HEALTHCHECK`: the run model is ephemeral `--rm` one-shots, not long-lived
  services, so a healthcheck has nothing to gate.
- Root `.dockerignore`: build context is `docker/` and `docker/egress/`, never
  the repo root, so a root-level ignore file is moot. The Dockerfile uses
  selective `COPY` (not `COPY .`), so host cruft never enters the image.

## Residual risk & recommended enterprise hygiene (your call)

These need a decision from you; they were intentionally not created:
- `LICENSE`: the terms are yours to choose. Without one, "ready to share" is
  legally ambiguous.
- `SECURITY.md`: a vulnerability-disclosure/contact policy is standard for
  shared security tooling.
- `THIRD_PARTY_NOTICES.md`: the image bundles Chromium, Playwright, patchright,
  camoufox (MPL-2.0), browser-use, markitdown (MIT), yt-dlp (Unlicense),
  axe-core (MPL-2.0), vegeta (MIT), curl_cffi (MIT), tinyproxy, FlareSolverr.
  An attribution file is good practice and, for the MPL-2.0 components,
  effectively expected.

Known accepted tradeoffs:
- apt packages float on debian-bookworm-slim's patched set (DL3008 suppressed by
  design); pinning exact apt versions on a rolling patched base breaks builds on
  the next security update.
- The egress proxy runs as the container's root because `--cap-drop ALL` removes
  `CAP_SETUID/SETGID`, so tinyproxy cannot drop privileges; the container
  boundary is the isolation, and this keeps the proxy actually running.
