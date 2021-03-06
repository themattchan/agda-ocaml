Introduction
============
This is an experimental backend for Agda that targets the OCaml compiler.

This repo is a mirror (and a branch off of) the repo that was used
during development. The original repo can be found here:

    https://gitlab.com/janmasrovira/agda2mlf

The major differece is the project structure. And the above repo also
contains a report we wrote for the project.

Project structure
=================
The project layout is designed to mirror suitable locations in `agda`.

Building
========
You need to install `malfunction` to get up and running. Please refer
to [malfunction] to see how to get this on your system.

This project has been tested using `stack`. Building should be as easy as:

    ln -s stack-8.0.2.yaml stack.yaml
    stack build

Running:

    stack exec agda-ocaml

Installing:

    stack install agda-ocaml

Testing:

    stack test

Benchmarking:

    stack exec agda-ocaml-bench

The benchmarks depend on [agda-prelude] - so download that and add it to
your default libraries.

[malfunction]: https://github.com/stedolan/malfunction
[agda-prelude]: https://github.com/UlfNorell/agda-prelude
