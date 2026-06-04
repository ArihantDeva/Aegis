# Third-Party Notices

This sandbox bundles, vendors, or pulls the third-party components listed below.
Each retains its own license; the sandbox's own MIT license (see LICENSE) does
not extend to them. Versions reflect what is installed in the browser image at
the time of this audit (2026-06); package licenses were read from the installed
package metadata inside the image, not from memory.

Full per-package license texts for the Debian system packages are available
inside the image at `/usr/share/doc/<package>/copyright`.

## Python components (per-venv, in the browser image)

| Component | Version | License | Project |
|---|---|---|---|
| playwright | 1.49.0 | Apache-2.0 | https://github.com/microsoft/playwright-python |
| patchright | 1.60.0 | Apache-2.0 | https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python |
| browser-use | 0.12.9 | MIT | https://github.com/browser-use/browser-use |
| trafilatura | 2.0.0 | Apache-2.0 | https://github.com/adbar/trafilatura |
| markdownify | 1.2.2 | MIT | https://github.com/matthewwithanm/python-markdownify |
| lxml | 6.1.1 | BSD-3-Clause | https://lxml.de |
| lxml-html-clean | 0.4.5 | BSD-3-Clause | https://github.com/fedora-python/lxml_html_clean |
| pybreaker | 1.4.1 | BSD-3-Clause | https://github.com/danielfm/pybreaker |
| markitdown | 0.1.6 | MIT | https://github.com/microsoft/markitdown |
| camoufox (launcher) | 0.4.11 | MIT | https://github.com/daijro/camoufox |
| yt-dlp | 2026.3.17 | Unlicense | https://github.com/yt-dlp/yt-dlp |
| curl_cffi | 0.15.0 | MIT | https://github.com/lexiforest/curl_cffi |

Note on camoufox: the Python launcher above is MIT. At build time it fetches a
patched Firefox build; Firefox and that derived build are licensed under
MPL-2.0. The browser binary therefore carries MPL-2.0 obligations independent of
the MIT launcher.

## Vendored binaries and scripts

| Component | Version | License | Project |
|---|---|---|---|
| axe-core (`/opt/axe.min.js`) | 4.12.0 | MPL-2.0 | https://github.com/dequelabs/axe-core |
| vegeta (`/usr/local/bin/vegeta`) | 12.13.0 | MIT | https://github.com/tsenart/vegeta |

## Base image and system packages

Built on `debian:bookworm-slim`. The notable installed system packages and their
licenses:

| Component | License | Project |
|---|---|---|
| Chromium | BSD-3-Clause (plus bundled components under their own licenses) | https://www.chromium.org |
| tini | MIT | https://github.com/krallin/tini |
| Xvfb / X11 utilities | MIT (X.Org) | https://www.x.org |
| x11vnc | GPL-2.0-or-later | https://github.com/LibVNC/x11vnc |
| fluxbox | MIT | http://fluxbox.org |
| noVNC | MPL-2.0 | https://github.com/novnc/noVNC |
| websockify | LGPL-3.0 | https://github.com/novnc/websockify |
| fonts-liberation | SIL OFL-1.1 | https://github.com/liberationfonts/liberation-fonts |
| fonts-unifont | GPL-2.0 / OFL | https://unifoundry.com/unifont/ |
| tinyproxy (egress image) | GPL-2.0-or-later | https://github.com/tinyproxy/tinyproxy |

Remaining Debian base-system packages (libc, ca-certificates, curl, passwd,
python3, and their transitive dependencies) are distributed under their
respective Debian licenses, recorded per package under
`/usr/share/doc/<package>/copyright` in the image.

## Runtime-pulled sidecar (not bundled in the build)

| Component | Version | License | Project |
|---|---|---|---|
| FlareSolverr | v3.5.0 | MIT | https://github.com/FlareSolverr/FlareSolverr |

FlareSolverr is pulled as a separate, pinned image only when `cf-get` is used; it
is not part of the browser image build.

## Copyleft notices

Some components above are copyleft. In particular: the camoufox-fetched Firefox
build and axe-core and noVNC are MPL-2.0 (file-level copyleft); x11vnc,
fonts-unifont, and tinyproxy are GPL-2.0; websockify is LGPL-3.0. If you
redistribute the images, honor those obligations (notably, make corresponding
source available where the respective license requires it).
