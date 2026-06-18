# ====================================================================================
# Setup Project

PROJECT_NAME ?= provider-harbor
PROJECT_REPO ?= github.com/buttahtoast/$(PROJECT_NAME)

export TERRAFORM_VERSION ?= 1.10.5

export TERRAFORM_PROVIDER_SOURCE ?= goharbor/harbor
export TERRAFORM_PROVIDER_REPO ?= https://github.com/goharbor/terraform-provider-harbor
export TERRAFORM_PROVIDER_VERSION ?= 3.12.0
export TERRAFORM_PROVIDER_DOWNLOAD_NAME ?= terraform-provider-harbor
export TERRAFORM_PROVIDER_DOWNLOAD_URL_PREFIX ?= $(TERRAFORM_PROVIDER_REPO)/releases/download/v$(TERRAFORM_PROVIDER_VERSION)/
export TERRAFORM_NATIVE_PROVIDER_BINARY ?= terraform-provider-harbor_v$(TERRAFORM_PROVIDER_VERSION)
export TERRAFORM_DOCS_PATH ?= docs/resources

PLATFORMS ?= linux_amd64 linux_arm64

# -include will silently skip missing files, which allows us
# to load those files with a target in the Makefile. If only
# "include" was used, the make command would fail and refuse
# to run a target until the include commands succeeded.
-include build/makelib/common.mk

# ====================================================================================
# Setup Output

-include build/makelib/output.mk

# ====================================================================================
# Setup Go

# Set a sane default so that the nprocs calculation below is less noisy on the initial
# loading of this file
NPROCS ?= 1

# each of our test suites starts a kube-apiserver and running many test suites in
# parallel can lead to high CPU utilization. by default we reduce the parallelism
# to half the number of CPU cores.
GO_TEST_PARALLEL := $(shell echo $$(( $(NPROCS) / 2 )))

GO_REQUIRED_VERSION ?= 1.24
GOLANGCILINT_VERSION ?= 2.12.1
GO_STATIC_PACKAGES = $(GO_PROJECT)/cmd/provider $(GO_PROJECT)/cmd/generator
GO_LDFLAGS += -X $(GO_PROJECT)/internal/version.Version=$(VERSION)
GO_SUBDIRS += cmd internal apis
-include build/makelib/golang.mk

# ====================================================================================
# Setup Kubernetes tools

KIND_VERSION = v0.31.0
UPTEST_VERSION = v2.2.0
UPTEST_REPO = crossplane/uptest
CRDDIFF_VERSION = v0.12.1
CROSSPLANE_CLI_VERSION = v2.2.1
CROSSPLANE_VERSION = 2.2.1
USE_HELM3 = true
HELM3_VERSION ?= v3.14.0

export CROSSPLANE_CLI_VERSION := $(CROSSPLANE_CLI_VERSION)
-include build/makelib/k8s_tools.mk

# ====================================================================================
# Setup Images

REGISTRY_ORGS ?= ghcr.io/buttahtoast xpkg.upbound.io/buttahtoast
IMAGES = $(PROJECT_NAME)
-include build/makelib/imagelight.mk

# ====================================================================================
# Setup XPKG

XPKG_REG_ORGS ?= ghcr.io/buttahtoast xpkg.upbound.io/buttahtoast
# NOTE(hasheddan): skip promoting on xpkg.upbound.io as channel tags are
# inferred.
XPKG_REG_ORGS_NO_PROMOTE ?= xpkg.upbound.io/buttahtoast
XPKGS = $(PROJECT_NAME)
-include build/makelib/xpkg.mk

# ====================================================================================
# Fallthrough

# run `make help` to see the targets and options

# We want submodules to be set up the first time `make` is run.
# We manage the build/ folder and its Makefiles as a submodule.
# The first time `make` is run, the includes of build/*.mk files will
# all fail, and this target will be run. The next time, the default as defined
# by the includes will be run instead.
fallthrough: submodules
	@echo Initial setup complete. Running make again . . .
	@make

# NOTE(hasheddan): we ensure the Crossplane CLI is installed prior to running
# platform-specific build steps in parallel to avoid installation races.
build.init: $(CROSSPLANE_CLI)

# ====================================================================================
# Setup Terraform for fetching provider schema
TERRAFORM := $(TOOLS_HOST_DIR)/terraform-$(TERRAFORM_VERSION)
TERRAFORM_WORKDIR := $(WORK_DIR)/terraform
TERRAFORM_PROVIDER_SCHEMA := config/schema.json

$(TERRAFORM):
	@$(INFO) installing terraform $(HOSTOS)-$(HOSTARCH)
	@mkdir -p $(TOOLS_HOST_DIR)/tmp-terraform
	@curl -fsSL https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/terraform_$(TERRAFORM_VERSION)_$(SAFEHOST_PLATFORM).zip -o $(TOOLS_HOST_DIR)/tmp-terraform/terraform.zip
	@unzip $(TOOLS_HOST_DIR)/tmp-terraform/terraform.zip -d $(TOOLS_HOST_DIR)/tmp-terraform
	@mv $(TOOLS_HOST_DIR)/tmp-terraform/terraform $(TERRAFORM)
	@rm -fr $(TOOLS_HOST_DIR)/tmp-terraform
	@$(OK) installing terraform $(HOSTOS)-$(HOSTARCH)

$(TERRAFORM_PROVIDER_SCHEMA): $(TERRAFORM)
	@$(INFO) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)
	@mkdir -p $(TERRAFORM_WORKDIR)
	@echo '{"terraform":[{"required_providers":[{"provider":{"source":"'"$(TERRAFORM_PROVIDER_SOURCE)"'","version":"'"$(TERRAFORM_PROVIDER_VERSION)"'"}}],"required_version":"'"$(TERRAFORM_VERSION)"'"}]}' > $(TERRAFORM_WORKDIR)/main.tf.json
	@$(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) init -upgrade > $(TERRAFORM_WORKDIR)/terraform-logs.txt 2>&1
	@$(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) providers schema -json=true > $(TERRAFORM_PROVIDER_SCHEMA) 2>> $(TERRAFORM_WORKDIR)/terraform-logs.txt
	@$(OK) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)

pull-docs:
	@if [ ! -d "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" ]; then \
  		mkdir -p "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" && \
		git clone -c advice.detachedHead=false --depth 1 --filter=blob:none --branch "v$(TERRAFORM_PROVIDER_VERSION)" --sparse "$(TERRAFORM_PROVIDER_REPO)" "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)"; \
	else \
		git -C "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" fetch --depth 1 origin "v$(TERRAFORM_PROVIDER_VERSION)" && \
		git -C "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" checkout FETCH_HEAD; \
	fi
	@git -C "$(WORK_DIR)/$(TERRAFORM_PROVIDER_SOURCE)" sparse-checkout set "$(TERRAFORM_DOCS_PATH)"

generate.init: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs

.PHONY: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs
# ====================================================================================
# Targets

# NOTE: the build submodule currently overrides XDG_CACHE_HOME in order to
# force the Helm 3 to use the .work/helm directory. This causes Go on Linux
# machines to use that directory as the build cache as well. We should adjust
# this behavior in the build submodule because it is also causing Linux users
# to duplicate their build cache, but for now we just make it easier to identify
# its location in CI so that we cache between builds.
go.cachedir:
	@go env GOCACHE

# Generate a coverage report for cobertura applying exclusions on
# - generated file
cobertura:
	@cat $(GO_TEST_OUTPUT)/coverage.txt | \
		grep -v zz_ | \
		$(GOCOVER_COBERTURA) > $(GO_TEST_OUTPUT)/cobertura-coverage.xml

# Update the submodules, such as the common build scripts.
submodules:
	@git submodule sync
	@git submodule update --init --recursive

# This is for running out-of-cluster locally, and is for convenience. Running
# this make target will print out the command which was used. For more control,
# try running the binary directly with different arguments.
run: go.build
	@$(INFO) Running Crossplane locally out-of-cluster . . .
	@# To see other arguments that can be provided, run the command with --help instead
	UPBOUND_CONTEXT="local" $(GO_OUT_DIR)/provider --debug

# ====================================================================================
# End to End Testing
CROSSPLANE_NAMESPACE = crossplane-system
KIND_CLUSTER_NAME ?= local-dev
XPKG_SKIP_DEP_RESOLUTION := true
-include build/makelib/local.xpkg.mk
-include build/makelib/controlplane.mk

# Crossplane CLI is not available in the pinned build submodule.
ifeq ($(origin CROSSPLANE_CLI), undefined)
CROSSPLANE_CLI := $(TOOLS_HOST_DIR)/crossplane-cli-$(CROSSPLANE_CLI_VERSION)
endif

# Crossplane v2 packages are built with the Crossplane CLI (crank), not up.
UP := $(CROSSPLANE_CLI)

$(CROSSPLANE_CLI):
	@$(INFO) installing Crossplane CLI $(CROSSPLANE_CLI_VERSION)
	@curl -fsSLo $(CROSSPLANE_CLI) --create-dirs https://releases.crossplane.io/stable/$(CROSSPLANE_CLI_VERSION)/bin/$(SAFEHOST_PLATFORM)/crank?source=build || $(FAIL)
	@chmod +x $(CROSSPLANE_CLI)
	@$(OK) installing Crossplane CLI $(CROSSPLANE_CLI_VERSION)

-include makelib/crossplane_v2.mk

# Install community Crossplane v2 (build submodule still targets UXP v1).
controlplane.up: $(HELM3) $(KUBECTL) $(KIND)
	@$(INFO) setting up controlplane
	@$(KIND) get kubeconfig --name $(KIND_CLUSTER_NAME) >/dev/null 2>&1 || $(KIND) create cluster --name=$(KIND_CLUSTER_NAME)
	@$(INFO) setting kubectl context to kind-$(KIND_CLUSTER_NAME)
	@$(KUBECTL) config use-context "kind-$(KIND_CLUSTER_NAME)"
	@$(HELM3) repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
	@$(HELM3) repo update crossplane-stable >/dev/null 2>&1
	@if $(HELM3) list -n $(CROSSPLANE_NAMESPACE) 2>/dev/null | grep -q '^crossplane\s'; then \
		$(INFO) crossplane already installed; \
	else \
		$(INFO) installing crossplane $(CROSSPLANE_VERSION); \
		$(HELM3) install crossplane crossplane-stable/crossplane \
			--namespace $(CROSSPLANE_NAMESPACE) \
			--create-namespace \
			--version $(CROSSPLANE_VERSION) \
			--wait --timeout 5m; \
	fi
	@$(KUBECTL) -n $(CROSSPLANE_NAMESPACE) wait --for=condition=Available deployment --all --timeout=5m

# Crossplane v2 removed ControllerConfig in favor of DeploymentRuntimeConfig.
local.xpkg.deploy.provider.%: $(KIND) local.xpkg.sync
	@$(INFO) deploying provider package $* $(VERSION)
	@$(KIND) load docker-image $(BUILD_REGISTRY)/$*-$(ARCH) -n $(KIND_CLUSTER_NAME)
	@echo '{"apiVersion":"pkg.crossplane.io/v1beta1","kind":"DeploymentRuntimeConfig","metadata":{"name":"runtimeconfig-$*"},"spec":{"deploymentTemplate":{"spec":{"selector":{},"strategy":{},"template":{"spec":{"containers":[{"args":["--debug"],"image":"$(BUILD_REGISTRY)/$*-$(ARCH)","name":"package-runtime"}]}}}}}}' | $(KUBECTL) apply -f -
	@echo '{"apiVersion":"pkg.crossplane.io/v1","kind":"Provider","metadata":{"name":"$*"},"spec":{"package":"$*-$(VERSION).gz","skipDependencyResolution":$(XPKG_SKIP_DEP_RESOLUTION),"packagePullPolicy":"Never","runtimeConfigRef":{"name":"runtimeconfig-$*"}}}' | $(KUBECTL) apply -f -
	@$(OK) deploying provider package $* $(VERSION)

# This target requires the following environment variables to be set:
# - UPTEST_EXAMPLE_LIST, a comma-separated list of examples to test
#   To ensure the proper functioning of the end-to-end test resource pre-deletion hook, it is crucial to arrange your resources appropriately.
#   You can check the basic implementation here: https://github.com/crossplane/uptest/blob/main/internal/templates/03-delete.yaml.tmpl.
# - UPTEST_CLOUD_CREDENTIALS (optional), multiple sets of AWS IAM User credentials specified as key=value pairs.
#   The support keys are currently `DEFAULT` and `PEER`. So, an example for the value of this env. variable is:
#   DEFAULT='[default]
#   aws_access_key_id = REDACTED
#   aws_secret_access_key = REDACTED'
#   PEER='[default]
#   aws_access_key_id = REDACTED
#   aws_secret_access_key = REDACTED'
#   The associated `ProviderConfig`s will be named as `default` and `peer`.
# - UPTEST_DATASOURCE_PATH (optional), see https://github.com/upbound/uptest#injecting-dynamic-values-and-datasource
uptest: $(UPTEST) $(KUBECTL) $(CHAINSAW) $(CROSSPLANE_CLI)
	@$(INFO) running automated tests
	@KUBECTL=$(KUBECTL) CHAINSAW=$(CHAINSAW) CROSSPLANE_CLI=$(CROSSPLANE_CLI) CROSSPLANE_NAMESPACE=$(CROSSPLANE_NAMESPACE) $(UPTEST) e2e "${UPTEST_EXAMPLE_LIST}" --data-source="${UPTEST_DATASOURCE_PATH}" --setup-script=cluster/test/setup.sh --default-conditions="Test" || $(FAIL)
	@$(OK) running automated tests

local-deploy: build controlplane.up local.xpkg.deploy.provider.$(PROJECT_NAME)
	@$(INFO) running locally built provider
	@$(KUBECTL) wait provider.pkg $(PROJECT_NAME) --for condition=Healthy --timeout 5m
	@$(KUBECTL) -n crossplane-system wait --for=condition=Available deployment --all --timeout=5m
	@$(OK) running locally built provider

e2e: local-deploy uptest

crddiff: $(UPTEST)
	@$(INFO) Checking breaking CRD schema changes
	@BASE_REF="origin/$${GITHUB_BASE_REF}"; \
	for crd in $${MODIFIED_CRD_LIST}; do \
		if ! git cat-file -e "$${BASE_REF}:$${crd}" 2>/dev/null; then \
			echo "CRD $${crd} does not exist in the $${BASE_REF} branch. Skipping..." ; \
			continue ; \
		fi ; \
		echo "Checking $${crd} for breaking API changes..." ; \
		changes_detected=$$($(UPTEST) crddiff revision <(git cat-file -p "$${BASE_REF}:$${crd}") "$${crd}" 2>&1) ; \
		if [[ $$? != 0 ]] ; then \
			printf "\033[31m"; echo "Breaking change detected!"; printf "\033[0m" ; \
			echo "$${changes_detected}" ; \
			echo ; \
		fi ; \
	done
	@$(OK) Checking breaking CRD schema changes

schema-version-diff:
	@$(INFO) Checking for native state schema version changes
	@BASE_REF="origin/$${GITHUB_BASE_REF}"; \
	if ! git cat-file -e "$${BASE_REF}:config/schema.json" 2>/dev/null; then \
		echo "Base branch does not have config/schema.json. Skipping..."; \
		exit 0; \
	fi; \
	PREV_PROVIDER_VERSION=$$(git cat-file -p "$${BASE_REF}:Makefile" | sed -nr 's/^export[[:space:]]*TERRAFORM_PROVIDER_VERSION[[:space:]]*[\?:]?=[[:space:]]*(.+)/\1/p'); \
	if [ -z "$${PREV_PROVIDER_VERSION}" ]; then \
		echo "Could not detect previous Terraform provider version. Skipping..."; \
		exit 0; \
	fi; \
	echo Detected previous Terraform provider version: $${PREV_PROVIDER_VERSION}; \
	echo Current Terraform provider version: $${TERRAFORM_PROVIDER_VERSION}; \
	mkdir -p $(WORK_DIR); \
	git cat-file -p "$${BASE_REF}:config/schema.json" > "$(WORK_DIR)/schema.json.$${PREV_PROVIDER_VERSION}"; \
	python3 scripts/version_diff.py config/generated.lst "$(WORK_DIR)/schema.json.$${PREV_PROVIDER_VERSION}" config/schema.json
	@$(OK) Checking for native state schema version changes

.PHONY: cobertura submodules fallthrough run crds.clean

# ====================================================================================
# Special Targets

define CROSSPLANE_MAKE_HELP
Crossplane Targets:
    cobertura             Generate a coverage report for cobertura applying exclusions on generated files.
    submodules            Update the submodules, such as the common build scripts.
    run                   Run crossplane locally, out-of-cluster. Useful for development.

endef
# The reason CROSSPLANE_MAKE_HELP is used instead of CROSSPLANE_HELP is because the crossplane
# binary will try to use CROSSPLANE_HELP if it is set, and this is for something different.
export CROSSPLANE_MAKE_HELP

crossplane.help:
	@echo "$$CROSSPLANE_MAKE_HELP"

help-special: crossplane.help

.PHONY: crossplane.help help-special

# ====================================================================================
# Local Development Extensions
# Include local development targets if Makefile.dev exists
-include Makefile.dev
