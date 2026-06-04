# Security Policy

## Reporting a vulnerability

If you discover a security issue in this sandbox, please report it privately so
it can be fixed before public disclosure.

- Contact: **arihantdeva@gmail.com**
- Please include: affected component (CLI, browser image, egress sidecar, or VM
  tooling), reproduction steps, and the impact you observed.
- Please do not open a public issue for an unfixed vulnerability.

We aim to acknowledge a report within a few business days and to agree on a
disclosure timeline once the issue is confirmed.

## What this sandbox is for

This is a defensive isolation boundary for running untrusted or
fingerprint-sensitive browser automation and compute off the host screen and off
the host network. Treat the container boundary as the security perimeter.

## Security posture (as shipped)

- Non-root runtime: every run executes as the unprivileged `sandbox` user.
- Capabilities dropped: `--cap-drop ALL` with `--security-opt no-new-privileges`;
  runtime CapEff is verified to be `0`.
- Resource bounds: `--pids-limit`, `--memory` equal to `--memory-swap` (swap
  disabled), `--cpus`, and a bounded `--shm-size`.
- Ephemeral by default: `--rm` one-shot containers; `/tmp` is a tmpfs; an
  optional `--readonly` makes the root filesystem immutable.
- Scoped host exposure: only an explicit `/work` directory is bind-mounted for
  deliverables; the observe-mode VNC port binds to `127.0.0.1` only.
- Network model:
  - Default bridge networking.
  - `--offline` removes networking entirely (`--network none`).
  - `--allow host1,host2` places the browser on an internal network with no
    route to the internet and forces all egress through a default-deny proxy
    sidecar that allows only the listed host suffixes. Allow-list entries are
    validated fail-closed (rejecting anything that is not a plain hostname) and
    matched literally and case-insensitively, so a crafted entry cannot widen
    the filter.
- Supply chain: the base image is `debian:bookworm-slim`; the recipe runner pins
  `playwright==1.49.0`; the FlareSolverr sidecar is pinned to a specific tag; and
  build-time binary downloads (axe-core, vegeta) are verified by SHA-256 so a
  tampered or truncated download fails the build.
- Secrets: no credentials are baked into the images or the source. LLM and
  captcha keys are read from the caller's environment at run time only.

## Known accepted tradeoffs

- The egress proxy runs as the sidecar container's root because `--cap-drop ALL`
  removes `CAP_SETUID`/`CAP_SETGID`, so the proxy cannot drop to an unprivileged
  user. The container boundary is the isolation; this keeps the proxy running.
- apt packages float on the patched `debian:bookworm-slim` set rather than being
  version-pinned, because pinning exact apt versions on a rolling, security
  patched base breaks builds when a pinned version leaves the mirror.

## Scope

In scope: the `sandbox` CLI, the browser and egress container images, and the
Tart VM tooling under `vm/`.

Out of scope: the security of third-party upstream projects bundled into the
images (see THIRD_PARTY_NOTICES.md), the Docker or macOS host configuration, and
any target site the sandbox is pointed at.
