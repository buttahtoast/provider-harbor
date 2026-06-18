# Crossplane v2 overrides for the pinned upbound/build submodule.
# Keep these in the parent repo so CI can fetch the build submodule from upstream.

# uptest moved from upbound/uptest to crossplane/uptest for v2.x releases.
$(UPTEST):
	@$(INFO) installing uptest $(UPTEST)
	@mkdir -p $(TOOLS_HOST_DIR)
	@curl -fsSLo $(UPTEST) https://github.com/$(UPTEST_REPO)/releases/download/$(UPTEST_VERSION)/uptest_$(SAFEHOSTPLATFORM) || $(FAIL)
	@chmod +x $(UPTEST)
	@$(OK) installing uptest $(UPTEST)

# Crossplane CLI uses a different xpkg build/push API than legacy up.
xpkg.build.provider-harbor: do.build.images
	@$(INFO) Building package provider-harbor-$(VERSION).xpkg for $(PLATFORM)
	@mkdir -p $(OUTPUT_DIR)/xpkg/$(PLATFORM)
	@runtime_arg=$$$$(grep -E '^kind:\s+Provider\s*$$$$' $(XPKG_DIR)/crossplane.yaml > /dev/null && echo "--embed-runtime-image=$(BUILD_REGISTRY)/provider-harbor-$(ARCH)"); \
	ignore_arg=$$$$([ -n "$(XPKG_IGNORE)" ] && echo "--ignore=$(XPKG_IGNORE)"); \
	$(UP) xpkg build \
		$$$${runtime_arg} \
		--package-root $(XPKG_DIR) \
		--examples-root $(XPKG_EXAMPLES_DIR) \
		$$$${ignore_arg} \
		--package-file $(XPKG_OUTPUT_DIR)/$(PLATFORM)/provider-harbor-$(VERSION).xpkg || $(FAIL)
	@$(OK) Built package provider-harbor-$(VERSION).xpkg for $(PLATFORM)

define xpkg.v2.release.targets
xpkg.release.publish.$(1).$(2):
	@$(INFO) Pushing package $(1)/$(2):$(VERSION)
	@$(UP) xpkg push \
		-f $(subst $(SPACE),$(COMMA),$(foreach p,$(XPKG_LINUX_PLATFORMS),$(XPKG_OUTPUT_DIR)/$(p)/$(2)-$(VERSION).xpkg)) \
		$(1)/$(2):$(VERSION) || $(FAIL)
	@$(OK) Pushed package $(1)/$(2):$(VERSION)
endef
$(foreach r,$(XPKG_REG_ORGS), $(foreach x,$(XPKGS),$(eval $(call xpkg.v2.release.targets,$(r),$(x)))))

local.xpkg.sync: local.xpkg.init $(UP)
	@$(INFO) copying local xpkg cache to Crossplane pod
	@mkdir -p $(XPKG_OUTPUT_DIR)/cache
	@for pkg in $(XPKG_OUTPUT_DIR)/linux_*/*; do $(UP) xpkg extract --from-xpkg $$pkg -o $(XPKG_OUTPUT_DIR)/cache/$$(basename $$pkg .xpkg).gz; done
	@XPPOD=$$($(KUBECTL) -n $(CROSSPLANE_NAMESPACE) get pod -l app=crossplane,patched=true -o jsonpath="{.items[0].metadata.name}"); \
		$(KUBECTL) -n $(CROSSPLANE_NAMESPACE) cp $(XPKG_OUTPUT_DIR)/cache -c dev $$XPPOD:/tmp
	@$(OK) copying local xpkg cache to Crossplane pod