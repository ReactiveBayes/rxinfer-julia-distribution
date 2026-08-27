# `rxinfer-julia-distribution`

**This repository is a build recipe, not a package.** Nothing here is `Pkg.add`-able and there is
no library code. Its single job is to produce a *relocatable Julia distribution* — a self-contained
tree holding a Julia runtime plus a system image with [RxInfer.jl](https://github.com/ReactiveBayes/RxInfer.jl)
and the course's dependencies baked into it — publish it as a GitHub release, and register it on a
student's machine as a juliaup channel named `rxinfer`, so that:

```console
$ julia +rxinfer
julia> using RxInfer      # resolves nothing, installs nothing, compiles nothing
```

RxInfer itself lives in `ReactiveBayes/RxInfer.jl`. Bugs in inference belong there; bugs in *what
ships* belong here.

## How it works, in one paragraph

`JuliaComputing/create-julia-distribution` (a GitHub Action) calls `create_distribution` from an
unreleased branch of `PackageCompiler`, which bundles a Julia runtime, links a system image
containing this project's dependencies, and exposes those dependencies as bundled stdlibs of that
runtime. A sibling action packs the tree into a tarball, which we attach to a GitHub release. The
installer scripts download it and run `juliaup link rxinfer <path>/bin/julia`. That `link` command
is the only part of the delivery path that is a documented, stable interface; everything else is a
pin into someone else's moving target (see **Pinned dependency state**).

## Layout, and the invariant of each file

| Path | Invariant |
| --- | --- |
| `Project.toml` | Not a package — no `name`/`uuid`. RxInfer is a **dependency**, never the root project (a root package gets baked into the sysimage without its `src/`/`ext/` being shipped, which breaks `pathof`, `pkgdir` and every package extension). Every direct dep carries an **equality** `[compat]` bound. Deliberately minimal: RxInfer plus a plotting stack. Every package added here is bundled as a *pinned stdlib*, so each one is another version students cannot move — `ExponentialFamilyProjection` was dropped for exactly this reason (it also pulled in Manifolds and Manopt, ~30 extra manifest entries). |
| `Manifest.toml` | **Committed on purpose.** A distribution is a build artifact, not a library. Without it the build resolves its own and what ships is decided at build time. |
| `LocalPreferences.toml` | Bundled into the distribution and **frozen into the system image**. See *Frozen preferences* below. |
| `precompile.jl` | A compile-time budget, not a test suite. Whatever it exercises is compiled into the shipped image; whatever it costs is added to every platform build. |
| `sysimage/banner.jl` | Runs *during* image generation. For things that must be baked in rather than applied to the tree afterwards. |
| `scripts/smoke_test.jl` | Run **by** the built distribution, never by `Pkg.test`. It is the only check that catches a run-time file the copy globs failed to ship — that class of failure is invisible at build time. |
| `.github/workflows/lint.yml` | The cheap checks: `shellcheck`, the only place `install.ps1` is ever parsed before a student runs it, and a guard that `Manifest.toml` is in step with `Project.toml`. Runs on every push, unlike the release build. |
| `install.sh`, `install.ps1` | The student-facing contract. Must stay **idempotent**: re-running is how a student upgrades. |
| `.github/workflows/release.yml` | Tag-triggered only. See *Release cadence* — this file spends real money, so read it before changing it. |

## Pinned dependency state

Read this before diagnosing any build failure. Almost every dependency here is a pin into
unversioned upstream work, and the failure modes differ by pin.

| Pin | Where the pin lives | Why, and what breaks when it moves |
| --- | --- | --- |
| `JuliaComputing/create-julia-distribution@958799562b82fcabd2f5508f7ee296e1d91de200` | `.github/workflows/release.yml`, three `uses:` lines | **The riskiest pin.** That repo has no releases, no tags and no Marketplace listing, and its own README asks consumers to pin a commit SHA. Its `docs/limits.md` states the build-shaping inputs are provisional and "expected to be replaced rather than extended" — so an upgrade can **remove** an input we depend on (`sysimage-script`, `additional-copy-globs`, `precompile-execution-file`), not merely change its behaviour. Read the upstream diff *and* `docs/limits.md` before bumping. |
| `PackageCompiler` at rev `9f277c199e7a21ca82d5e54cda39644c3835cbfe` | **Inside the action** (`bin/setup-package-compiler.jl`) — *not ours to set* | `create_distribution` does not exist in any released PackageCompiler; it lives on an unmerged branch. The action installs this exact commit into a shared `create-julia-distribution-support` environment reached through `LOAD_PATH`. There is **no input to override it**, and nothing in our `Project.toml`/`Manifest.toml` affects which compiler builds the distribution. Consequence: bumping the action SHA is *also* a PackageCompiler bump, and that is where a silent change in what gets bundled would come from. |
| `rcodesign_jll` 0.29.0+1, sha256-pinned | Inside the action (`sign-macos/get_rcodesign.sh`) | Used for macOS signing. Only the `aarch64-apple-darwin` build is pinned, which is *why* the signing step needs an Apple Silicon runner. Fails closed on a checksum mismatch; overridable via the `RCODESIGN` env var. |
| Julia `1.12.6` | `install-juliaup` step **and** `[compat] julia = "=1.12.6"` | This is the runtime that ships — the action deliberately does not install Julia, so that step is what chooses it. The two must move together; the compat entry is what turns a mismatch into a resolve-time failure instead of a distribution built against the wrong Julia. `compress-sysimage` stays `false` until we move to Julia 1.13+, which is where it is supported. |
| `RxInfer = "=X.Y.Z"` and every other direct dep | `Project.toml` + committed `Manifest.toml` | The equality pins *are* the reproducibility story. Changing them is a reviewable PR. |
| `actions/checkout`, `julia-actions/install-juliaup`, the release action | `.github/workflows/release.yml` | SHA-pinned with a trailing `# vX.Y.Z` comment, following the upstream action's own examples. |
| `juliaup link` | `install.sh`, `install.ps1` | The one genuinely documented, stable interface in the delivery path. |

### How to update a pin

1. One pin per pull request. **Never** bump the action SHA and the RxInfer/Julia pins together —
   when the build breaks you want to know which pin did it.
2. For an action bump: read the upstream commit range for withdrawn or renamed inputs, and re-read
   `docs/limits.md`.
3. Run the workflow via `workflow_dispatch` on the branch.
4. Merge only when the post-build smoke test **and** the relocation test pass on all three
   platforms. A green build is not evidence: the smoke test executing code inside the built tree is.

## Failure-mode crib sheet

| Symptom | Cause |
| --- | --- |
| The action rejects an input | Action SHA moved and the input was withdrawn or renamed. |
| `Pkg` cannot resolve | A dependency moved outside our equality pins, or the Julia pin and the `install-juliaup` channel disagree. |
| Build fine, but a student hits `SystemError`/missing file at **run** time | A package reads a file at run time that the default copy globs do not ship. Add a pattern to `additional-copy-globs`. This class of failure never shows up at build time — only the smoke test catches it. |
| `pack` fails on Windows | A symlink appeared in the tree. The action rejects those deliberately (extraction needs a privilege most end users lack). Ship a `.zip` for Windows instead. |
| Signing fails | `rcodesign` checksum mismatch, or the job is not on an Apple Silicon runner. |
| `The runner has received a shutdown signal` / `signal 15` mid-build | The runner VM died, not Julia. Peak memory during the system image link is the usual suspect (`JULIA_IMAGE_THREADS: "1"` already mitigates); infrastructure preemption looks the same. Rerun the failed platform alone — `gh run rerun --failed` — before assuming anything. |
| The workload errors | A model in `precompile.jl` broke against a new RxInfer. Fix the workload, or the RxInfer regression it exposed. |
| macOS: "cannot be opened because the developer cannot be verified" | The tarball was downloaded in a browser and carries `com.apple.quarantine`. Ad-hoc signing does not satisfy Gatekeeper. `xattr -dr com.apple.quarantine <dir>`, or install via the script (`curl` never sets the attribute). |

## Deliberate, not bugs

- **Bundled dependencies are pinned stdlibs.** Everything in the manifest is exposed as a stdlib of
  the shipped Julia at exactly the version we shipped. Verified behaviour, not theory:
  - ordinary additions (`DataFrames`, `CSV`) resolve and install into the user's own depot normally;
  - a *version request* for a bundled package is silently satisfied with the shipped version —
    `Pkg.add(name = "Distributions", version = "0.24")` succeeds and gives you `0.25.131`, so this
    fails quietly rather than loudly;
  - a package whose `[compat]` excludes the shipped version fails with
    `Unsatisfiable requirements ... possible versions are: 0.25.131 or uninstalled (package in sysimage!)`.

  This is the strongest argument for keeping the bundled set small: each package added here is one
  more version a student can never move.
- **`pathof`/`pkgdir` resolve inside the distribution.** The action rewrites `Base.pkgorigins` while
  the image is generated, so paths point into the shipped tree rather than at the CI runner.
- **`include_transitive_dependencies = false`.** A package that does not load all of its own
  dependencies when it loads leaves those to compile on the student's machine.
- **Lazy artifacts are not bundled.** A dependency declaring one fetches it at run time.
- **Frozen preferences.** `create_distribution` bundles `LocalPreferences.toml`, and because RxInfer
  is *in the system image* its `@load_preference` calls are compile-time `const`s. So RxInfer's
  telemetry/session settings are fixed at build time and
  `RxInfer.disable_rxinfer_using_telemetry!()` **does nothing** in this distribution — it writes a
  preference that can no longer be read. `LOG_USING_RXINFER=false` (checked at run time) is the only
  opt-out that works, which is why the README leads with it.
- **The distribution reports the same `VERSION` as stock Julia 1.12.6** but has its own system
  image, so packages a student adds on top precompile separately from their stock-Julia caches.

## Release cadence

**A `v*` tag is the only thing that builds.** There is no schedule. A full matrix costs roughly $7
in billed runner minutes — macOS is a 10x multiplier and takes ~100 minutes on a hosted runner,
Windows is 2x at ~60 — so a weekly refresh would have been ~$360/year to find out that a dependency
moved. (Note for anyone recalculating this: public repositories do **not** get these minutes free
in this organization; the first release build was billed.)

`workflow_dispatch` runs the same matrix and publishes nothing, which is how you verify a change to
the build without spending a tag on it. Cutting a release therefore means: bump the pins in a PR,
dispatch a build if the change was risky, then tag.

Because there is no scheduled early-warning build, **nothing here notices on its own that a new
RxInfer or Julia has broken the build.** You find out when you next tag. If that becomes a problem,
the cheap fix is a Linux-only scheduled build (1x multiplier) rather than restoring the full matrix.

### Costs and failure notes from the first release

- macOS ~100 min, Windows ~60 min, Linux ~12 min to the point of failure. `fail-fast: false` is
  what lets a retry rebuild only the platform that died instead of paying for the matrix again;
  `gh run rerun --failed` reuses the successful platforms' artifacts.
- **The Linux OOM, and why x86_64 is the hard case.** The Linux runner was killed during
  `compiling incremental system image` on both the v0.0.1 and v0.0.2 attempts, with
  `The runner has received a shutdown signal` and `signal 15` — no Julia error, nowhere near the
  timeout. Reproduced locally in a memory-capped Debian container (`--memory=7g`), where it is
  unambiguous: PackageCompiler's own monitor warns `Free system memory dropped to 174 MiB during
  sysimage compilation`, the `--output-o` child dies with `ProcessSignaled(9)`, and cgroup v2
  reports `oom_kill 1`.

  The asymmetry worth understanding: `macos-latest` has **7 GB** and succeeds while `ubuntu-latest`
  has **16 GB** and fails. That is not runner strength, it is `cpu_target`.
  `PackageCompiler.default_app_cpu_target()` returns
  `generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)` on x86_64 — **`clone_all` clones
  every function for a second microarchitecture** — against
  `generic;cortex-a57;thunderx2t99;armv8.2-a,...` (no `clone_all`) on aarch64. The x86_64 link is
  simply a much bigger one.

  Mitigations, in the order they were tried:
  1. `JULIA_IMAGE_THREADS: "1"` (workflow-wide). Helped — survival in the link went from 5.3 to
     23.1 minutes — but did not fix it.
  2. A 24 GB swapfile on `/mnt` before the Linux build. Swap does not reduce what the link needs;
     it stops the kernel from killing it, at the cost of a slower link.
  3. Not yet done, and the only fix that addresses the cause: pass a cheaper `cpu_target`
     (`generic`, or the same list minus `clone_all`). **The action exposes no way to do this** —
     there is no option passthrough — so it means either an upstream input or calling
     `create_distribution` ourselves instead of via the action. It would also shrink the 832 MB
     system image and the 409 MB download.

## Working on this repo

- Builds are expensive. Measured on an M-series Mac (macOS aarch64, warm depot): about 15 minutes
  wall clock, producing a **1.5 GB unpacked tree** and a **409 MB tarball** at gzip -6. The
  dominant costs are the system image (832 MB) and bundled artifacts (442 MB, over a third of it
  Qt6 pulled in by GR for Plots). Do not iterate on CI; build locally on one platform first.
- The precompile workload is the one file where effort pays off repeatedly, and the one place where
  carelessness costs every student a wait. Measure before and after: time `using RxInfer` and a
  first `infer` call, both for a model the workload compiled and one it never saw. As a reference
  point, the workload as committed runs in about a minute against a warm depot
  (`GKSwstype=100 julia --project=. precompile.jl`); if it grows past a few minutes, justify it.
- Macros are greedy, so a `begin` block cannot be passed bare as a keyword argument:
  `@initialization begin ... end, iterations = 10` swallows the rest of the argument list. Write
  `@initialization(begin ... end)` or bind it to a variable first. Both appear in `precompile.jl`.
- Model bodies for the workload come from RxInfer's own test suite (`test/models/**`,
  `test/inference/**`) with the `@testitem` wrappers and assertions stripped. Do not point the
  workload at the test suite itself: the items need `TestItems`/`TestItemRunner`, `BenchmarkTools`
  and other `[extras]` we do not ship, and `Aqua` alone would add minutes of waste per platform.
