# lkrms/check-ci-runs

> Skip your CI workflow if an identical run already succeeded with a different
> commit/tag/branch.

This GitHub Action uses [actions/checkout@v4][] to check out your repository if
necessary and looks for a successful CI workflow run with the same tree.

If it finds an `in_progress` run with the same tree that was triggered before
the run that called the action, it waits for it to finish before returning a
result.

If there are non-empty lines in a `.ci-pathspec` file at the root of your
repository, they are passed to `git` to limit files that must be the same in
both commits.

## Usage

<!-- prettier-ignore -->
```yaml
jobs:
  check-ci-runs:
    outputs:
      # - 0 = successful CI workflow run found with this tree
      # - 1 = CI workflow has not run on this tree yet
      ci_required: ${{ steps.check-ci-runs.outputs.ci_required }}
    steps:
      - id: check-ci-runs
        uses: lkrms/check-ci-runs@v1
        with:
          # CI workflow names (comma-delimited)
          ci_workflows: "CI,Release"
        env:
          # Required by GitHub CLI
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  ci:
    needs:
      - check-ci-runs
    if: ${{ needs.check-ci-runs.outputs.ci_required == 1 && !cancelled() && !failure() }}
```

### `.ci-pathspec`

Changes to files that do not match a pattern in your repository's `.ci-pathspec`
file are ignored when the action compares workflow run commits.

Here's an example from a PHP project:

```
# /.ci-pathspec
.github/workflows/**
bin/**
scripts/**
src/**
tests/**
tools/**
.ci-pathspec
.gitattributes
.php-cs-fixer.dist.php
.prettyphp
bootstrap.php
box.json
composer.json
composer.lock
phpstan*
phpunit.xml.dist
```

Empty lines and lines that start with `#` are ignored.

Pattern syntax is documented under `pathspec` in the [Git Glossary][pathspec].

## License

This project is licensed under the [MIT License][].

[actions/checkout@v4]: https://github.com/actions/checkout/tree/v4/
[MIT License]: LICENSE
[pathspec]:
  https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec
