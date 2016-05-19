## Release summary

This package is new on CRAN. It contains the R kernel for the Jupyter
ecosystem. The kernel executes R code, which the frontend (Jupyter Notebook or
other frontends) submits to the kernel via the network.

## Test environments

* local Win7 64bit install, R 3.2.5, R 3.3.0 and r-devel (3.4)
* Ubuntu 12.04 (on travis-ci), oldrelease, release, and r-devel

## R CMD check results

There are no ERRORS and no WARNINGs and 1 NOTEs.

Note:

* Found the following calls to attach():
  File 'IRkernel/R/execution.r':
    attach(NULL, name = "jupyter:irkernel")
  See section 'Good practice' in '?attach'.

  We use this additional environment to add functions so that regular "stuff"
  like `quit()` works in the IRkernel environment (in this case to shutdown the
  kernel). We added the "good practice" call to `detach` in `finalize` so that
  this environment is available as long as the R kernel is running.

## Downstream dependencies

It is assumed that there won't be any code dependencies on this package, as it
implements an application without any API apart from the startup function and the
implemented Jupyter Messaging spec. It's usually started as
`R --slave -e IRkernel::main() --args {connection_file}`.
