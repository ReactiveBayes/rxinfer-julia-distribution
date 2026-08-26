# Precompilation workload for the RxInfer distribution.
#
# Whatever this file exercises is compiled into the system image the distribution
# ships, so a student never pays for it. Whatever it costs in time is paid by
# every platform build, every release. It is a budget, not a test suite: there is
# not a single assertion here, and there should not be. Correctness is RxInfer's
# own test suite's job.
#
# The models are lifted from RxInfer's test suite (test/models/**,
# test/inference/**) with the `@testitem` wrappers and assertions stripped, since
# those are the model shapes the library itself considers representative. Do not
# replace this with the test suite: its items need TestItems/TestItemRunner,
# BenchmarkTools and other [extras] this distribution does not ship, and Aqua
# alone would add minutes of pure waste to every platform build.
#
# The checklist this is meant to cover -- keep it covered when editing:
#
#   @model expansion and create_model         @constraints (MeanField and structured)
#   batch infer with iterations               @meta
#   free_energy = true                        @initialization
#   streaming infer with @autoupdates         deferred RxInferenceEngine start
#   KeepLast / KeepEach return modes          the plotting routines the course
#                                             uses, including savefig
#
# Requires GKSwstype=100 in the environment, or GR tries to open a display.

using RxInfer
using StableRNGs
using Plots
using StatsPlots
using LinearAlgebra

@info "precompile.jl: starting workload"

# ---------------------------------------------------------------------------
# 1. Beta-Bernoulli -- the first model a student writes.
#    Covers: batch infer, iterations, free_energy, MeanField, @initialization.
# ---------------------------------------------------------------------------

@model function beta_bernoulli(y, a, b)
    θ ~ Beta(a, b)
    for i in eachindex(y)
        y[i] ~ Bernoulli(θ)
    end
end

let
    dataset = float.(rand(StableRNG(42), Bernoulli(0.75), 500))
    # A macro with a `begin` block cannot be written bare as a keyword argument:
    # macros are greedy, so `@initialization begin ... end, iterations = 10`
    # swallows every argument after it. Either parenthesize the macro call --
    # `@initialization(begin ... end)` -- or bind it first, as here. Bound is
    # preferred in this file when the value is used more than once. The same
    # applies to `@constraints` and `@autoupdates` throughout.
    init = @initialization begin
        q(θ) = Beta(1.0, 1.0)
    end

    result = infer(
        model = beta_bernoulli(a = 2.0, b = 7.0),
        data = (y = dataset,),
        iterations = 10,
        free_energy = true,
    )

    infer(
        model = beta_bernoulli(a = 2.0, b = 7.0),
        constraints = MeanField(),
        data = (y = dataset,),
        iterations = 10,
        free_energy = true,
        initialization = init,
    )

    global beta_posterior = result.posteriors[:θ][end]
    global beta_free_energy = result.free_energy
end

# ---------------------------------------------------------------------------
# 2. Linear regression.
#    Covers: deterministic nodes, broadcasting in a model, KeepLast, returnvars.
# ---------------------------------------------------------------------------

@model function linear_regression(x, y)
    a ~ Normal(mean = 0.0, var = 1.0)
    b ~ Normal(mean = 0.0, var = 1.0)
    for (i, k) in zip(eachindex(x), eachindex(y))
        y[k] ~ Normal(mean = x[i] * b + a, var = 1.0)
    end
end

@model function linear_regression_broadcasted(x, y)
    a ~ Normal(mean = 0.0, var = 1.0)
    b ~ Normal(mean = 0.0, var = 1.0)
    y .~ Normal(mean = x .* b .+ a, var = 1.0)
end

let
    rng = StableRNG(1234)
    N = 100
    xdata = collect(1:N) .+ randn(rng, N)
    ydata = 10.0 .+ (-10.0) .* xdata
    init = @initialization begin
        μ(b) = NormalMeanVariance(0.0, 100.0)
    end

    for modelfn in (linear_regression, linear_regression_broadcasted)
        infer(
            model = modelfn(),
            data = (x = xdata, y = ydata),
            returnvars = (a = KeepLast(), b = KeepLast()),
            initialization = init,
            free_energy = true,
            iterations = 25,
        )
    end
end

# ---------------------------------------------------------------------------
# 3. Univariate linear Gaussian state space model.
#    Covers: the filtering/smoothing machinery over a long chain, which is the
#    single most expensive code path most course models go through.
# ---------------------------------------------------------------------------

@model function univariate_lgssm(y, x0, c, P)
    x_prior ~ Normal(μ = mean(x0), v = var(x0))
    x_prev = x_prior
    for i in eachindex(y)
        x[i] ~ x_prev + c
        y[i] ~ Normal(μ = x[i], v = P)
        x_prev = x[i]
    end
end

let
    rng = StableRNG(123)
    P = 100.0
    n = 250
    hidden = collect(1:n)
    data = hidden + rand(rng, Normal(0.0, sqrt(P)), n)

    result = infer(
        model = univariate_lgssm(x0 = NormalMeanVariance(0.0, 10_000.0), c = 1.0, P = P),
        data = (y = data,),
        free_energy = true,
    )

    global lgssm_posteriors = result.posteriors[:x]
    global lgssm_hidden = hidden
    global lgssm_data = data
end

# ---------------------------------------------------------------------------
# 4. Hidden Markov model.
#    Covers: structured @constraints, discrete nodes, KeepEach, vague
#    initialization, and the multi-iteration VMP loop.
# ---------------------------------------------------------------------------

@model function hidden_markov_model(x)
    A ~ DirichletCollection(ones(3, 3))
    B ~ DirichletCollection([10.0 1.0 1.0; 1.0 10.0 1.0; 1.0 1.0 10.0])

    s_0 ~ Categorical(fill(1.0 / 3.0, 3))
    s_prev = s_0

    for t in eachindex(x)
        s[t] ~ DiscreteTransition(s_prev, A)
        x[t] ~ DiscreteTransition(s[t], B)
        s_prev = s[t]
    end
end

let
    rng = StableRNG(123)
    n = 50
    onehot = k -> (v = zeros(3); v[k] = 1.0; v)
    observations = [onehot(rand(rng, 1:3)) for _ in 1:n]

    constraints = @constraints begin
        q(s, s_0, A, B) = q(s, s_0)q(A)q(B)
    end
    init = @initialization begin
        q(A) = vague(DirichletCollection, (3, 3))
        q(B) = vague(DirichletCollection, (3, 3))
        q(s) = vague(Categorical, 3)
    end

    infer(
        model = hidden_markov_model(),
        constraints = constraints,
        data = (x = observations,),
        options = (limit_stack_depth = 500,),
        free_energy = true,
        initialization = init,
        iterations = 10,
        returnvars = (s = KeepEach(), A = KeepEach(), B = KeepEach()),
    )
end

# ---------------------------------------------------------------------------
# 5. Streaming inference.
#    Covers: @autoupdates, the reactive engine, keephistory, historyvars, and
#    an explicit start/stop cycle on a non-autostarted engine.
# ---------------------------------------------------------------------------

@model function streaming_lgssm(y, x_prev_mean, x_prev_var, τ_shape, τ_rate)
    x_prev ~ Normal(mean = x_prev_mean, var = x_prev_var)
    τ ~ Gamma(shape = τ_shape, rate = τ_rate)
    x ~ Normal(mean = x_prev, precision = 1.0)
    y ~ Normal(mean = x, precision = τ)
end

let
    rng = StableRNG(42)
    n = 50
    hidden = cumsum(randn(rng, n))
    observations = hidden .+ 0.3 .* randn(rng, n)

    autoupdates = @autoupdates begin
        x_prev_mean, x_prev_var = mean_var(q(x))
        τ_shape = shape(q(τ))
        τ_rate = rate(q(τ))
    end
    init = @initialization begin
        q(x) = NormalMeanVariance(0.0, 1e3)
        q(τ) = GammaShapeRate(1.0, 1.0)
    end

    # Autostarted: the path a student's streaming script takes.
    infer(
        model = streaming_lgssm(),
        constraints = MeanField(),
        data = (y = observations,),
        autoupdates = autoupdates,
        initialization = init,
        returnvars = (:x, :τ),
        historyvars = (x = KeepLast(), τ = KeepLast()),
        keephistory = n,
        iterations = 5,
        free_energy = true,
        autostart = true,
    )

    # Manually driven, which compiles the deferred-start path a student's
    # interactive session takes. No `RxInfer.stop` here: the dataset is finite,
    # so the engine has already exhausted itself by the time `start` returns and
    # `stop` would only reach the "exhausted engine" guard, not the real
    # teardown -- it warns, and compiles nothing worth having.
    engine = infer(
        model = streaming_lgssm(),
        constraints = MeanField(),
        data = (y = observations,),
        autoupdates = autoupdates,
        initialization = init,
        keephistory = n,
        iterations = 5,
        autostart = false,
    )
    RxInfer.start(engine)
end

# ---------------------------------------------------------------------------
# 6. Plotting.
#    A first `plot` on a stock install is one of the longest waits in the whole
#    course. `savefig` matters most: writing a file is where much of the GR
#    output pipeline is first compiled.
# ---------------------------------------------------------------------------

let
    m = mean.(lgssm_posteriors)
    s = std.(lgssm_posteriors)
    steps = 1:length(m)

    p1 = plot(steps, m, ribbon = s, label = "posterior", xlabel = "t", ylabel = "x")
    plot!(p1, steps, lgssm_hidden, label = "hidden")
    scatter!(p1, steps, lgssm_data, label = "observations", markersize = 2)

    p2 = plot(beta_free_energy, xlabel = "iteration", ylabel = "BFE", label = "free energy")

    p3 = plot(0:0.01:1, x -> pdf(beta_posterior, x), fill = true, label = "q(θ)")

    samples = rand(StableRNG(1), beta_posterior, 500)
    p4 = histogram(samples, bins = 30, label = "samples")

    # StatsPlots recipes are compiled per recipe, so exercise the ones the course uses.
    p5 = density(samples, label = "density")

    plot(p1, p2, p3, p4, p5, layout = (3, 2), size = (900, 900))

    mktempdir() do dir
        savefig(joinpath(dir, "workload.png"))
    end
end

@info "precompile.jl: workload complete"
