#!/usr/bin/env bash
#
# Installs the RxInfer Julia distribution and registers it with juliaup as the
# channel `rxinfer`, so that `julia +rxinfer` starts a Julia in which
# `using RxInfer` resolves, installs and compiles nothing.
#
#   curl -fsSL https://raw.githubusercontent.com/ReactiveBayes/rxinfer-julia-distribution/main/install.sh | bash
#
# Options (pass after `-s --` when piping: `... | bash -s -- --weekly`):
#   --version <tag>   install a specific release tag instead of the latest stable
#   --weekly          install the newest weekly prerelease (for testing, not for a course)
#   --no-telemetry    also add LOG_USING_RXINFER=false to your shell profile
#   --channel <name>  juliaup channel name to create (default: rxinfer)
#   -h, --help        show this and exit
#
# Re-running this script is how you upgrade: it is idempotent, and replaces the
# channel rather than failing on it.

set -euo pipefail

REPOSITORY="${RXINFER_DIST_REPOSITORY:-ReactiveBayes/rxinfer-julia-distribution}"
VERSION="${RXINFER_DIST_VERSION:-}"
CHANNEL="rxinfer"
WEEKLY="false"
NO_TELEMETRY="false"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "${1}" in
    --version) VERSION="${2:?--version needs a tag}"; shift 2 ;;
    --weekly) WEEKLY="true"; shift ;;
    --no-telemetry) NO_TELEMETRY="true"; shift ;;
    --channel) CHANNEL="${2:?--channel needs a name}"; shift 2 ;;
    -h | --help)
      # Printed rather than extracted from the file: when this script is piped
      # from curl there is no file to read.
      cat <<'USAGE'
Installs the RxInfer Julia distribution as the juliaup channel `rxinfer`.

  --version <tag>   install a specific release tag instead of the latest stable
  --weekly          install the newest weekly prerelease (testing, not coursework)
  --no-telemetry    also add LOG_USING_RXINFER=false to your shell profile
  --channel <name>  juliaup channel name to create (default: rxinfer)
  -h, --help        show this and exit

When piping, pass options after `-s --`:
  curl -fsSL .../install.sh | bash -s -- --no-telemetry
USAGE
      exit 0
      ;;
    *) die "unknown option '${1}'. Run with --help." ;;
  esac
done

# --- 1. Which platform is this? --------------------------------------------
#
# Only the three platforms the release workflow builds are accepted. Failing
# loudly beats downloading a tarball that cannot run.

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) PLATFORM="linux-x86_64" ;;
  Darwin/arm64) PLATFORM="macos-aarch64" ;;
  Darwin/x86_64)
    die "Intel Macs are not built yet. Please open an issue at https://github.com/${REPOSITORY}/issues if you need one -- meanwhile, install RxInfer the usual way with 'juliaup add release' and 'Pkg.add(\"RxInfer\")'."
    ;;
  Linux/aarch64 | Linux/arm64)
    die "ARM Linux is not built yet. Please open an issue at https://github.com/${REPOSITORY}/issues if you need one."
    ;;
  *) die "unsupported platform '$(uname -s)/$(uname -m)'." ;;
esac
log "Platform: ${PLATFORM}"

for tool in curl tar; do
  command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is required but not installed."
done

# --- 2. Ensure juliaup ------------------------------------------------------
#
# juliaup owns the `julia` launcher that makes `julia +rxinfer` work, so it is a
# hard requirement rather than a convenience.

if ! command -v juliaup >/dev/null 2>&1; then
  log "juliaup not found; installing it from https://install.julialang.org"
  curl -fsSL https://install.julialang.org | sh -s -- --yes

  # The official installer edits the shell profile, which does not affect this
  # already-running shell -- so find the binary it just installed.
  for candidate in "${HOME}/.juliaup/bin" "${JULIAUP_DEPOT_PATH:-}/bin"; do
    if [ -x "${candidate}/juliaup" ]; then
      PATH="${candidate}:${PATH}"
      export PATH
      break
    fi
  done
  command -v juliaup >/dev/null 2>&1 ||
    die "juliaup was installed but is not on PATH. Open a new terminal and re-run this script."
fi
log "Using juliaup: $(command -v juliaup)"

# --- 3. Resolve the release -------------------------------------------------

API="https://api.github.com/repos/${REPOSITORY}/releases"

if [ -z "${VERSION}" ]; then
  if [ "${WEEKLY}" = "true" ]; then
    # Weekly builds are prereleases, so /latest never returns one.
    VERSION="$(curl -fsSL "${API}?per_page=30" |
      grep -o '"tag_name": *"weekly-[^"]*"' | head -n 1 |
      sed 's/.*"weekly-/weekly-/; s/"$//')"
    [ -n "${VERSION}" ] || die "no weekly prerelease found in ${REPOSITORY}."
  else
    VERSION="$(curl -fsSL "${API}/latest" |
      grep -o '"tag_name": *"[^"]*"' | head -n 1 |
      sed 's/.*: *"//; s/"$//')"
    [ -n "${VERSION}" ] ||
      die "no stable release found in ${REPOSITORY}. Pass --weekly to install a weekly build."
  fi
fi
log "Release: ${VERSION}"

STEM="rxinfer-${VERSION#v}-${PLATFORM}"
TARBALL="${STEM}.tar.gz"
BASE_URL="https://github.com/${REPOSITORY}/releases/download/${VERSION}"

# --- 4. Download and verify -------------------------------------------------
#
# Downloading with curl rather than a browser is also what keeps macOS from
# attaching a com.apple.quarantine attribute, which Gatekeeper would then block.

WORK_DIRECTORY="$(mktemp -d)"
# shellcheck disable=SC2064 # expand WORK_DIRECTORY now, not at trap time
trap "rm -rf '${WORK_DIRECTORY}'" EXIT

log "Downloading ${TARBALL} (this is a few hundred MB)"
curl -fL --progress-bar -o "${WORK_DIRECTORY}/${TARBALL}" "${BASE_URL}/${TARBALL}" ||
  die "download failed. Does ${VERSION} include a build for ${PLATFORM}? See https://github.com/${REPOSITORY}/releases"

log "Verifying the checksum"
if curl -fsSL -o "${WORK_DIRECTORY}/${TARBALL}.sha256" "${BASE_URL}/${TARBALL}.sha256"; then
  EXPECTED="$(cut -d' ' -f1 <"${WORK_DIRECTORY}/${TARBALL}.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${WORK_DIRECTORY}/${TARBALL}" | cut -d' ' -f1)"
  else
    ACTUAL="$(shasum -a 256 "${WORK_DIRECTORY}/${TARBALL}" | cut -d' ' -f1)"
  fi
  [ "${EXPECTED}" = "${ACTUAL}" ] ||
    die "checksum mismatch: expected ${EXPECTED}, got ${ACTUAL}. Refusing to install."
  log "Checksum ok"
else
  warn "no published checksum for ${TARBALL}; installing without verification."
fi

# --- 5. Extract -------------------------------------------------------------

DEPOT="${JULIA_DEPOT_PATH%%:*}"
DEPOT="${DEPOT:-${HOME}/.julia}"
INSTALL_ROOT="${DEPOT}/rxinfer-distributions"
INSTALL_PATH="${INSTALL_ROOT}/${VERSION}"

if [ -d "${INSTALL_PATH}" ]; then
  log "Replacing the existing installation at ${INSTALL_PATH}"
  rm -rf "${INSTALL_PATH}"
fi
mkdir -p "${INSTALL_PATH}"

log "Extracting into ${INSTALL_PATH}"
tar -xzf "${WORK_DIRECTORY}/${TARBALL}" -C "${INSTALL_PATH}"

JULIA_BINARY="${INSTALL_PATH}/${STEM}/bin/julia"
[ -x "${JULIA_BINARY}" ] || die "the extracted tree has no executable at ${JULIA_BINARY}."

# --- 6. Register the juliaup channel ---------------------------------------
#
# `juliaup link` refuses a channel name that is already in use, so removing
# first is what makes re-running this script an upgrade rather than an error.

if juliaup status 2>/dev/null | grep -qE "^[[:space:]*]+${CHANNEL}[[:space:]]"; then
  log "Removing the previous '${CHANNEL}' channel"
  juliaup remove "${CHANNEL}" >/dev/null 2>&1 || true
fi

log "Linking channel '${CHANNEL}'"
juliaup link "${CHANNEL}" "${JULIA_BINARY}"

# --- 7. Optional telemetry opt-out -----------------------------------------
#
# RxInfer's telemetry preferences are compiled into this distribution's system
# image, so `RxInfer.disable_rxinfer_using_telemetry!()` cannot take effect here.
# The environment variable is the only opt-out that works -- see the README.

if [ "${NO_TELEMETRY}" = "true" ]; then
  case "${SHELL:-}" in
    */zsh) PROFILE="${HOME}/.zshrc" ;;
    */bash) PROFILE="${HOME}/.bashrc" ;;
    *) PROFILE="${HOME}/.profile" ;;
  esac
  LINE="export LOG_USING_RXINFER=false  # added by the rxinfer distribution installer"
  if [ -f "${PROFILE}" ] && grep -qF "LOG_USING_RXINFER" "${PROFILE}"; then
    log "LOG_USING_RXINFER is already set in ${PROFILE}"
  else
    printf '\n%s\n' "${LINE}" >>"${PROFILE}"
    log "Added LOG_USING_RXINFER=false to ${PROFILE} (takes effect in a new terminal)"
  fi
fi

# --- 8. Verify --------------------------------------------------------------

log "Verifying the installation"
julia "+${CHANNEL}" --startup-file=no \
  -e 'using RxInfer; println("RxInfer ", pkgversion(RxInfer), " on Julia ", VERSION, " -- ready")'

cat <<EOF

Done. Start it with:

    julia +${CHANNEL}

Optionally make it your default Julia (this affects a plain \`julia\` too):

    juliaup default ${CHANNEL}

Installed at: ${INSTALL_PATH}
Uninstall:    juliaup remove ${CHANNEL} && rm -rf "${INSTALL_PATH}"

This distribution sends one anonymous event per \`using RxInfer\`. Because the
setting is compiled into the system image, the only way to opt out is the
environment variable LOG_USING_RXINFER=false -- see the README section
"Telemetry" at https://github.com/${REPOSITORY}#telemetry
EOF
