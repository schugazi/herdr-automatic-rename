# herdr-automatic-rename developer tasks.

.PHONY: test lint lint-sh lint-md syntax hooks print-shellcheck-version print-shellcheck-sha256

# The one place the shellcheck version is written down. CI downloads exactly
# this release, so bumping it here is the whole bump. Findings move between
# versions, so a local run on anything else can disagree with CI.
SHELLCHECK_VERSION := 0.11.0
# sha256 of shellcheck-v$(SHELLCHECK_VERSION).linux.x86_64.tar.xz, the tarball
# CI downloads. The version pin says which release, the digest says which bytes,
# so a swapped tarball fails the job. The two move together: bump one, bump both.
SHELLCHECK_SHA256 := 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198

# Run the full test suite (needs bash + jq only).
test:
	@./tests/run.sh

# Every static check. The pieces are separate targets so the pre-commit hooks can
# run each one on its own and report which failed.
lint: lint-sh lint-md

# Skipped when shellcheck is absent and FAILING when it is not. An `&& tool ||
# echo skipping` chain cannot tell those apart: a real warning took the ||
# branch too, so this target printed "not installed" and exited 0, and no local
# lint gate could ever say no. CI runs the same file list.
#
# -x follows the sourced files, which the `# shellcheck source=` directives in
# each of them name. The shell hooks are per-shell (zsh/fish) so only the
# portable bash sources are checked; the syntax target covers those two.
lint-sh:
	@if command -v shellcheck >/dev/null 2>&1; then \
		have=$$(shellcheck --version | sed -n 's/^version: //p'); \
		[ "$$have" = "$(SHELLCHECK_VERSION)" ] || \
			echo "warning: shellcheck $$have, CI runs $(SHELLCHECK_VERSION)"; \
		shellcheck -x -s bash automatic-rename.sh naming.sh icons.sh git.sh transcript.sh ai.sh config.example.sh install.sh \
			shell/hook.bash tests/*.sh tests/mocks/herdr; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

# Markdown prose rules, including the no-hard-wrap check CI enforces. Same shape
# as lint-sh above, and for the same reason: a hard-wrapped line used to report
# itself as a missing npx.
lint-md:
	@if command -v npx >/dev/null 2>&1; then \
		npx --yes markdownlint-cli2@0.23.2; \
	else \
		echo "npx not installed; skipping markdownlint"; \
	fi

# Parse-only pass over every shell file, which catches the typo shellcheck never
# gets to report. Keep this file list identical to the CI workflow's. hook.zsh
# and hook.fish are not bash, so each gets its own interpreter, and each is
# skipped when that shell is absent (CI always has both).
syntax:
	@for f in automatic-rename.sh naming.sh icons.sh git.sh transcript.sh ai.sh config.example.sh install.sh shell/hook.bash \
	          tests/run.sh tests/lib.sh tests/test_*.sh tests/mocks/herdr; do \
		/bin/bash -n "$$f" || exit 1; \
	done
	@if command -v zsh >/dev/null 2>&1; then zsh -n shell/hook.zsh; \
		else echo "zsh not installed; skipping shell/hook.zsh"; fi
	@if command -v fish >/dev/null 2>&1; then fish -n shell/hook.fish; \
		else echo "fish not installed; skipping shell/hook.fish"; fi

# Install the git pre-commit hook from .pre-commit-config.yaml, so the checks
# above run before a commit lands rather than after CI says no.
hooks:
	@if command -v prek >/dev/null 2>&1; then prek install; \
	elif command -v pre-commit >/dev/null 2>&1; then pre-commit install; \
	else echo "prek not installed: see https://prek.j178.dev (or pipx install pre-commit)"; exit 1; fi

# For the CI job, which installs the pinned release rather than the distro's.
print-shellcheck-version:
	@echo $(SHELLCHECK_VERSION)

print-shellcheck-sha256:
	@echo $(SHELLCHECK_SHA256)
