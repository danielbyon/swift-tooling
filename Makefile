SHELL := /bin/bash

.PHONY: test lint release

test:
	bash Tests/test_suite.sh

lint:
	bash -n bin/swift-tooling Scripts/*.sh Tests/test_suite.sh

release:
	@test -n "$(VERSION)" || (printf '%s\n' 'VERSION is required, for example VERSION=v0.1.0' >&2; exit 2)
	bash Scripts/build-release.sh "$(VERSION)" dist
