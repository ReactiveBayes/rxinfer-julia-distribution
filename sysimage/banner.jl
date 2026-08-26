# Runs while the system image is generated, for what has to be baked into the
# image rather than applied to the tree afterwards.
#
# This runs *after* the build action's own script, which rewrites the package
# origin paths baked into the image (what keeps `pathof`/`pkgdir` resolving
# inside the distribution on a student's machine). It composes with it and can
# never displace it.
#
# The banner is how the shipped runtime identifies itself as this distribution
# rather than as the plain Julia release it was built from -- which matters when
# a student pastes a REPL header into an issue.
@eval Base const TAGGED_RELEASE_BANNER = "RxInfer distribution -- https://github.com/ReactiveBayes/rxinfer-julia-distribution"
