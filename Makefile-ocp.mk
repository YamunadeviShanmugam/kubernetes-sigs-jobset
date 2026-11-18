include Makefile

# Verify that go.mod and the CI build images (Dockerfile.ci and
# Dockerfile.ci-build-root, plus .ci-operator.yaml while it is still in use)
# agree on the Go version, so CI does not silently compile with an older
# Go than the code requires.
.PHONY: verify-golang-versions
verify-golang-versions:
	./hack/verify-golang-versions.sh

.PHONY: verify-ocp
verify-ocp: manifests verify-golang-versions
	@if !(git diff --quiet HEAD); then \
		git diff; \
		echo "manifests are out of date, run make manifests"; exit 1; \
	fi

.PHONY: build-ocp
build-ocp: fmt vet
	$(GO_BUILD_ENV) $(GO_CMD) build -ldflags="$(LD_FLAGS)" -o bin/manager main.go
