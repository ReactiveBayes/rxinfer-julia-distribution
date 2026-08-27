# RxInfer Julia distribution

A prebuilt Julia that already contains [RxInfer.jl](https://github.com/ReactiveBayes/RxInfer.jl).
Install it once and

```julia
julia> using RxInfer     # instant: nothing to resolve, install or compile
```

No `Pkg.add`, no dependency resolution, no first-use precompilation wait. Made for teaching, where
thirty people installing the same stack on thirty laptops is thirty chances for something to go
wrong.

Measured on an M-series Mac against a stock Julia 1.12.6 with an **already warm** package cache —
i.e. the best case for stock, not the cold first run a student actually faces:

| | this distribution | stock Julia (warm) |
| --- | --- | --- |
| `using RxInfer` | 0.0 s | 2.6 s |
| first `infer` on a familiar model | 1.5 s | 5.9 s |
| first `infer` on a new model | 1.5 s | 2.9 s |
| **total** | **3.0 s** | **11.4 s** |

A student's genuine first run on stock Julia also includes installing and precompiling ~300
packages, which is minutes rather than seconds.

## Install

**Linux and macOS** (Apple Silicon):

```bash
curl -fsSL https://raw.githubusercontent.com/ReactiveBayes/rxinfer-julia-distribution/main/install.sh | bash
```

**Windows** (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/ReactiveBayes/rxinfer-julia-distribution/main/install.ps1 | iex
```

The installer will:

1. install [juliaup](https://github.com/JuliaLang/juliaup) if you do not have it,
2. download the distribution for your platform (about 400 MB) and verify its checksum,
3. unpack it under `~/.julia/rxinfer-distributions/` (about 1.5 GB on disk), and
4. register it as a juliaup channel called `rxinfer`.

Then:

```console
$ julia +rxinfer
julia> using RxInfer
```

Re-running the installer is how you upgrade — it replaces the channel rather than complaining
about it.

### Options

| | |
| --- | --- |
| `--version <tag>` | install a specific release instead of the latest |
| `--no-telemetry` | also set `LOG_USING_RXINFER=false` in your shell profile |
| `--channel <name>` | use a different juliaup channel name |

When piping into `bash`, pass options after `-s --`:

```bash
curl -fsSL .../install.sh | bash -s -- --no-telemetry
```

On Windows use PowerShell parameter syntax (`-NoTelemetry`, `-Version v1.2.3`).

## Using it

```console
$ julia +rxinfer                       # start it
$ juliaup default rxinfer              # optional: make it your default `julia`
```

**VS Code**: set the Julia extension's `julia.executablePath` to the `bin/julia` inside
`~/.julia/rxinfer-distributions/<version>/rxinfer-<version>-<platform>/`, or simply make `rxinfer`
your juliaup default.

**Uninstall**:

```bash
juliaup remove rxinfer
rm -rf ~/.julia/rxinfer-distributions
```

## What's inside

RxInfer, its dependencies, and a plotting stack — deliberately nothing more:

- **RxInfer.jl**
- **Plots.jl** and **StatsPlots.jl** — plotting works instantly too, which on a stock install is
  its own long first wait
- **StableRNGs.jl** — for reproducible examples

Optional RxInfer extensions such as `ExponentialFamilyProjection` are **not** bundled. Keeping the
stack small keeps the download small and reduces the chance of the version conflicts described
below. If you need one, `Pkg.add` it — see [adding your own packages](#important-adding-your-own-packages).

Exact versions are pinned per release; see `Project.toml` and the `manifest-<version>.toml` asset
attached to each release.

## Important: adding your own packages

Everything shipped in the distribution is **fixed at the version that shipped**. Those packages are
built into the Julia itself, which is what makes loading them instant — but it also means their
versions cannot move. Pkg is explicit about it: the only version it will offer you is the bundled
one, marked `(package in sysimage!)`.

Most things just work:

```julia
julia> using Pkg
julia> Pkg.add("DataFrames")   # fine — installs into ~/.julia as usual
julia> Pkg.add("CSV")          # fine
```

Two behaviours are worth knowing about:

**Asking for a specific version of a bundled package is silently ignored.**
`Pkg.add(name = "Distributions", version = "0.24")` does not fail — you get the bundled
`0.25.131` anyway, because the bundled copy is the only one available to this Julia.

**A package that requires a version we did not ship cannot be installed at all.** You get:

```
Unsatisfiable requirements detected for package Distributions [31c24e10]:
 ├─possible versions are: 0.25.131 or uninstalled (package in sysimage!)
 └─restricted to versions 0.24 by SomePackage — no versions left
```

There is no way around this from inside the distribution. Use a normal Julia for that work:

```console
$ juliaup add release      # a stock Julia, if you don't have one
$ julia +release           # then Pkg.add whatever you need
```

Keeping coursework in `julia +rxinfer` and side projects in `julia +release` is the intended split.

## Telemetry

**This distribution reports one anonymous event each time you run `using RxInfer`**, which is
RxInfer's own default behaviour — the same as installing it with `Pkg.add`. The event contains:

- a timestamp,
- a random UUID generated fresh for each session (not a persistent identifier),
- the RxInfer version, and
- the Julia version.

It contains **no code, no data and nothing identifying you or your machine**. Session sharing — the
feature that can upload model source and error context — is **off**. The full account is in
[RxInfer's telemetry manual](https://reactivebayes.github.io/RxInfer.jl/stable/manuals/telemetry/).

### Opting out

Set an environment variable:

```bash
export LOG_USING_RXINFER=false      # add to ~/.zshrc or ~/.bashrc
```

```powershell
[Environment]::SetEnvironmentVariable("LOG_USING_RXINFER", "false", "User")
```

Or let the installer do it for you: `--no-telemetry` (`-NoTelemetry` on Windows).

> [!IMPORTANT]
> **`RxInfer.disable_rxinfer_using_telemetry!()` does not work in this distribution.** On a normal
> install that is the documented way to opt out, and it works by writing a preference. Here RxInfer
> is compiled into the Julia system image, so its preferences were frozen when the distribution was
> built and can no longer be re-read. The environment variable above is the only opt-out that has
> any effect — we are calling this out explicitly so nobody believes they have opted out when they
> have not.

## Platforms

| Platform | Status |
| --- | --- |
| Linux x86-64 | supported |
| macOS Apple Silicon (M1 and later) | supported |
| Windows x86-64 | supported |
| macOS Intel | not built — [open an issue](https://github.com/ReactiveBayes/rxinfer-julia-distribution/issues) if you need it |
| Linux ARM64 | not built — [open an issue](https://github.com/ReactiveBayes/rxinfer-julia-distribution/issues) if you need it |

### macOS note

The macOS build is ad-hoc signed but not notarized. Installing with the script is unaffected —
`curl` does not mark downloads as quarantined. If you download a tarball **in a browser** instead,
macOS will refuse to run it; clear the flag with:

```bash
xattr -dr com.apple.quarantine ~/.julia/rxinfer-distributions
```

### Windows note

The bundled system image is not code-signed, so antivirus software occasionally flags it. Each
release publishes a `.sha256` checksum (which the installer verifies) if you want to confirm what
you downloaded.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| `julia: command not found` after installing | Open a new terminal — juliaup edits your shell profile and the change does not apply to an already-open one. |
| `Unsatisfiable requirements` when adding a package | See [adding your own packages](#important-adding-your-own-packages). Use `julia +release` for that work. |
| macOS: "developer cannot be verified" | You downloaded the tarball in a browser; see the [macOS note](#macos-note). |
| Something recompiles on first use | Expected for *your own* models — model code is compiled when you write it. RxInfer's own machinery is prebuilt. |
| `juliaup: command not found` mid-install | Open a new terminal and re-run the installer. |

Anything else: [open an issue](https://github.com/ReactiveBayes/rxinfer-julia-distribution/issues)
and include the output of `julia +rxinfer --version` and `juliaup status`.

## For maintainers

Read [AGENTS.md](AGENTS.md) first — it covers the pinned dependency state, how to update a pin, and
the failure-mode crib sheet. In short:

```bash
# Resolve and pin
julia --project=. -e 'using Pkg; Pkg.resolve()'

# Run the precompilation workload on its own (~1 minute warm) before a build
GKSwstype=100 julia --project=. precompile.jl

# Build one platform locally, using the pinned build action's own entry point
git clone https://github.com/JuliaComputing/create-julia-distribution /tmp/cjd
git -C /tmp/cjd checkout 958799562b82fcabd2f5508f7ee296e1d91de200
env DISTRIBUTION_ID=rxinfer-local-$(uname -m) SOURCE_PATH="$PWD" \
    SYSIMAGE_SCRIPT=sysimage/banner.jl GKSwstype=100 \
    julia /tmp/cjd/bin/create-distribution.jl

# Verify the result the only way that means anything: run it
./distributions/rxinfer-local-$(uname -m)/bin/julia scripts/smoke_test.jl
```

Releases are cut by tagging `v*`, which is the **only** thing that triggers a build — there is no
schedule, because a full matrix costs roughly $7 in billed runner minutes (macOS is a 10x
multiplier at ~100 minutes, Windows 2x at ~60). `workflow_dispatch` builds the same matrix without
publishing, for verifying a change before spending a tag on it.
