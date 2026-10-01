SHELL := /usr/bin/env bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*')

.PHONY: help lint test run
help:            ## list targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

lint:            ## shellcheck every script
	shellcheck $(SCRIPTS)

test:            ## run all test suites
	bash system-triage/tests/run_tests.sh

run:             ## run system triage (use sudo for the full view)
	bash system-triage/triage.sh
