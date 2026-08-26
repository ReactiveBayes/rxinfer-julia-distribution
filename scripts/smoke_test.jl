# Run BY the julia inside a built distribution, never by `Pkg.test`: the
# distribution under test is the thing executing this file.
#
# `julia --version` is answered before the system image is loaded, so it exits 0
# even on a tree whose sysimage is missing entirely -- which is exactly what a
# failed build leaves behind. This file executes real code instead, and asserts
# the two properties that cannot be checked any other way:
#
#   1. the shipped packages load without resolving, installing or compiling, and
#   2. they resolve to paths INSIDE the distribution, so a file a package reads
#      at run time is actually present on a student's machine.
#
# (2) is the one that matters most: a missing run-time file is invisible at build
# time and surfaces only when someone uses the distribution.

using RxInfer
using Plots
using StatsPlots

"""
Root of the distribution running this script, derived from the running binary
rather than passed in, so a distribution can only ever be checked against itself.
Ends in a path separator so a prefix comparison means containment rather than
merely sharing a name.
"""
distribution_root() = joinpath(normpath(Sys.BINDIR, ".."), "")

function check(condition, message)
    condition || error("smoke test failed: ", message)
    println("  ok: ", message)
    return nothing
end

println("Distribution root: ", distribution_root())
println("Julia ", VERSION, ", RxInfer ", pkgversion(RxInfer))

# The packages the distribution exists to ship must live inside it. `RxInfer`
# itself is the load-bearing case: it is bundled as a stdlib of this Julia, so a
# path outside the tree means it was baked into the image without its sources and
# `pkgdir`-relative reads would fail on a student's machine.
for pkg in (RxInfer, Plots, StatsPlots)
    path = pkgdir(pkg)
    check(
        path !== nothing && startswith(normpath(path), normpath(distribution_root())),
        "$(nameof(pkg)) resolves inside the distribution ($(path))",
    )
end

check(isfile(joinpath(pkgdir(RxInfer), "LICENSE")), "RxInfer's license file ships")

# Inference has to actually run. A coin toss is enough: it exercises model
# construction, the message-passing machinery and free energy in one call.
@model function smoke_beta_bernoulli(y)
    θ ~ Beta(1.0, 1.0)
    for i in eachindex(y)
        y[i] ~ Bernoulli(θ)
    end
end

result = infer(
    model = smoke_beta_bernoulli(),
    data = (y = float.([1, 0, 1, 1, 1, 0, 1, 1, 1, 1]),),
    free_energy = true,
)

posterior = result.posteriors[:θ]
check(mean(posterior) > 0.5, "inference returns a sensible posterior (mean $(mean(posterior)))")
check(length(result.free_energy) == 1, "free energy is computed")

# Plotting, including writing a file -- the part of the GR pipeline most likely
# to be missing an artifact.
mktempdir() do dir
    target = joinpath(dir, "smoke.png")
    plot(1:10, (1:10) .^ 2, label = "smoke")
    savefig(target)
    check(isfile(target) && filesize(target) > 0, "a plot renders and saves to a file")
end

println("smoke test passed")
