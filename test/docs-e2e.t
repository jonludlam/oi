End-to-end smoke test for [oi docs]: set up a tiny project, run sync
to populate the d10 cache with build layers, then check that [oi docs]
exercises the full pipeline.

  $ export OI_DATA_DIR=$PWD/data
  $ export OI_CACHE_DIR=$PWD/cache
  $ export HOME=$PWD/home
  $ mkdir -p "$HOME"

A minimal project declaring [csexp] as its dep — chosen because csexp
is a small leaf library depending only on [ocaml].

  $ cat > test_pkg.opam <<EOF
  > opam-version: "2.0"
  > maintainer: "test"
  > authors: "test"
  > homepage: "https://example.org"
  > bug-reports: "https://example.org"
  > license: "ISC"
  > dev-repo: "git+https://example.org/test.git"
  > synopsis: "test fixture"
  > depends: [ "csexp" ]
  > EOF

[oi docs] runs: Pipeline.build (deps), Doc_plan.build (DAG),
Doc_execute.run (per-node Doc_build), Doc_assemble.assemble.

  $ oi docs 2>&1 | grep -q "^Building project deps"
  $ oi docs 2>&1 | grep -q "^Doc DAG: [0-9]"
  $ oi docs 2>&1 | grep -q "^Assembled to "

The assemble step writes to _oi/docs/.

  $ test -d _oi/docs/odoc_docs

Real odoc HTML output:

  $ test -f _oi/docs/odoc_docs/odoc.css
  $ test -f _oi/docs/odoc_docs/p/csexp/1.5.2/doc/index.html
  $ ! test -d _oi/docs/odoc_docs/u

odoc_driver_voodoo's intermediate dirs (.odoc/.odocl) and our
prep / cwd dirs are kept OUT of the captured doc layer.

  $ ! test -d _oi/docs/_oi-cwd
  $ ! test -d _oi/docs/odoc_docs/.odoc
  $ ! test -d _oi/docs/odoc_docs/.odocl
