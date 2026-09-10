# AirBuild3G — build an iOS 4.0 app for iPhone 3G (armv6) and 3GS (armv7)
# using a modern Xcode toolchain.
#
# Xcode 27 blocks this three ways, each worked around below:
#
#   1. The legacy SDK's dylibs predate LC_VERSION_MIN_IPHONEOS, so ld reports
#      them as built for an "unknown" platform and errors out.
#      -> tools/mkstubs.py regenerates them as .tbd text stubs, which ld takes.
#   2. ld refuses any iOS deployment target below 4.3.
#      -> link at 5.0, then tools/patch_minos.py stamps the load command to 4.0.
#         4.3 would link too; 5.0 is what has been verified on device.
#   3. ld refuses "-arch armv6" outright.
#      -> compile real armv6 code, relabel the objects armv7 so ld accepts them,
#         then relabel the linked slice back (tools/relabel_arch.py).

APP_NAME      := AirBuild3G
ARCHS         := armv6 armv7
DEPLOY_TARGET := 4.0
SDK_VERSION   := 4.1
PACKAGE_ID    := com.apple.airbuild.oss
PACKAGE_VER   := 1.0.0

LEGACY_SDK ?= $(HOME)/theos/sdks/iPhoneOS$(SDK_VERSION).sdk

# Same tree, same bytes. Everything that goes into a package is already a
# function of its input -- the binary is built -no_uuid, the SDK tarball
# normalises its members and gzips with mtime 0 -- but the deb around it is
# not: dpkg-deb stamps the ar members with the time it ran, and records each
# file's mtime, which in a fresh clone is the time of the clone. Both come
# from the tree's own last commit instead. A tree with no history gets the
# epoch, which is stable too.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 0)
export SOURCE_DATE_EPOCH
# SOURCE_DATE_EPOCH only makes dpkg-deb *clamp* mtimes to that instant, so a
# file already older than it keeps its own -- and two checkouts have different
# ones. Stamp the whole tree before packing.
STAMP_MTIME = find $(1) -exec touch -h -t $(shell date -r $(SOURCE_DATE_EPOCH) +%Y%m%d%H%M.%S) {} +

BUILD  := build
SHIM   := $(BUILD)/sdkshim
OBJ    := $(BUILD)/obj
APPDIR := $(BUILD)/$(APP_NAME).app
BINARY := $(APPDIR)/$(APP_NAME)
STAMP  := $(SHIM)/.stamp
DEBROOT := $(BUILD)/debroot
DEB     := $(BUILD)/$(PACKAGE_ID)_$(PACKAGE_VER)_iphoneos-arm.deb

# The build environment ships as its own package: it is ~90 MB of Debian
# archives and tarballs that change far less often than the 700 KB app, and
# separating them means iterating on the app does not mean re-copying the
# toolchain to the phone.
PAYLOAD      := $(BUILD)/payload
# One payload per device family. A 3G on iOS 4 is armv6 and gets Telesphoreo
# GCC 4.2; a 3GS or iPod on iOS 6 is armv7 and gets clang, which declares
# firmware (>= 5.0). Shipping one package made every 3G carry 38 MB it then
# marked "Skipped". The two debs Conflict, so a phone holds exactly one.
PAYLOAD_TARGETS := ios4 ios6
payload_deb  = $(BUILD)/$(PACKAGE_ID).bootstrap$(patsubst ios%,%,$(1))_$(PACKAGE_VER)_iphoneos-arm.deb
PAYLOAD_DEBS := $(foreach t,$(PAYLOAD_TARGETS),$(call payload_deb,$(t)))

# The phone, over SSH. Every device target needs it; there is no sensible
# default, so say so once rather than failing at ssh with someone else's
# address: make install-device DEVICE=root@192.168.1.20
DEVICE ?=
require_device = @[ -n "$(DEVICE)" ] || { echo "error: set DEVICE, e.g. make $@ DEVICE=root@192.168.1.20"; exit 1; }

SOURCES    := $(wildcard src/*.m)
FRAMEWORKS := UIKit Foundation CoreFoundation CoreGraphics Security
SLICES     := $(foreach a,$(ARCHS),$(OBJ)/$(APP_NAME)/$(a)/$(APP_NAME))

# The one privileged binary. The app runs as mobile like any other app; this
# is installed 4755 beside it and is the only thing that ever holds uid 0, for
# one command at a time. It lives outside src/ so the app's own wildcard does
# not pick up a second main().
HELPER_NAME    := airbuildhelper
HELPER_SOURCES := src/helper/ABLHelperMain.m src/ABLStash.m
HELPER_SLICES  := $(foreach a,$(ARCHS),$(OBJ)/$(HELPER_NAME)/$(a)/$(HELPER_NAME))
HELPER         := $(APPDIR)/$(HELPER_NAME)

CC   := $(shell xcrun -f clang)
LDID := $(shell command -v ldid 2>/dev/null)

# Compile against the real SDK headers at a true 4.0 target, so the compiler
# selects the iOS 4.0 Objective-C runtime and availability macros.
CFLAGS = -arch $(ARCH) \
         -isysroot $(LEGACY_SDK) \
         -mios-version-min=$(DEPLOY_TARGET) \
         -fno-objc-arc \
         -fobjc-abi-version=2 \
         -fmessage-length=0 \
         -Wall \
         -Os \
         -Isrc

# Link at 5.0 against the .tbd shim (ld's floor is 4.3; 5.0 is what has been
# run on device). -no_pie: iOS had no ASLR before 4.3, and the stubs ld emits
# for this target must stay plain ARM. ld-27037.1 emits the same ldr/add stubs
# either way -- `make verify` asserts the property directly rather than
# trusting the flag.
# -no_objc_category_merging: ld-27037.1 folds a category into its class by
# default and rewrites the class's method list -- without the Thumb bit on any
# IMP. The armv7 slice is Thumb, so on a 3GS the first message to such a class
# lands in ARM mode and dies at pc 0; armv6 is all ARM and never showed it.
LDFLAGS = -arch $(LINK_ARCH) \
          -isysroot $(LEGACY_SDK) \
          -mios-version-min=5.0 \
          -nostartfiles \
          -F$(SHIM)/System/Library/Frameworks \
          -L$(SHIM)/usr/lib \
          -Wl,-no_pie \
          -Wl,-no_objc_category_merging \
          -lobjc \
          $(addprefix -framework ,$(FRAMEWORKS))

.PHONY: artwork all app stubs ipa deb package payload payload-ios4 payload-ios6 \
        payload-lock payload-from-device \
        install-device hello-device test e2e e2e-device clean distclean verify

all: app

ARTWORK := $(wildcard Resources/*.png)
SKILLS  := $(APPDIR)/skills

app: $(BINARY) $(HELPER) $(APPDIR)/Info.plist $(addprefix $(APPDIR)/,$(notdir $(ARTWORK))) $(SKILLS)

stubs: $(STAMP)

$(STAMP): tools/mkstubs.py
	@test -d "$(LEGACY_SDK)" || { echo "error: legacy SDK not found at $(LEGACY_SDK)"; exit 1; }
	python3 tools/mkstubs.py "$(LEGACY_SDK)" "$(SHIM)"
	@touch $@

# One rule per architecture per binary: compile, relabel armv6 -> armv7, link,
# relabel back. ld only ever sees armv7, so armv6 objects are disguised for the
# link and restored immediately after.
#
#   $(1) architecture   $(2) binary name   $(3) sources
define SLICE_RULES
$(OBJ)/$(2)/$(1)/$(2): ARCH := $(1)
$(OBJ)/$(2)/$(1)/$(2): LINK_ARCH := armv7
$(OBJ)/$(2)/$(1)/$(2): $(3) tools/relabel_arch.py tools/patch_minos.py | $(STAMP)
	@mkdir -p $(OBJ)/$(2)/$(1)
	@rm -f $(OBJ)/$(2)/$(1)/*.o
	@for s in $(3); do \
	    echo "  compile [$(1)] $$$$s"; \
	    $$(CC) $$(CFLAGS) -c $$$$s -o $(OBJ)/$(2)/$(1)/$$$$(basename $$$$s .m).o || exit 1; \
	done
	@lipo -thin $(1) "$(LEGACY_SDK)/usr/lib/crt1.3.1.o" -output $(OBJ)/$(2)/$(1)/crt1.startup
	@for o in $(OBJ)/$(2)/$(1)/*.o; do python3 tools/relabel_arch.py $$$$o armv7; done; python3 tools/relabel_arch.py $(OBJ)/$(2)/$(1)/crt1.startup armv7
	@echo "  link    [$(1)] $$@"
	@rm -f $$@
	@set -o pipefail; $$(CC) $$(LDFLAGS) $(OBJ)/$(2)/$(1)/crt1.startup $(OBJ)/$(2)/$(1)/*.o -o $$@ 2>&1 \
	    | grep -v "no platform load command" || test -f $$@
	@test -f $$@
	@python3 tools/relabel_arch.py $$@ $(1)
	@python3 tools/patch_minos.py $$@ $(DEPLOY_TARGET) $(SDK_VERSION) >/dev/null
endef
$(foreach a,$(ARCHS),$(eval $(call SLICE_RULES,$(a),$(APP_NAME),$(SOURCES))))
$(foreach a,$(ARCHS),$(eval $(call SLICE_RULES,$(a),$(HELPER_NAME),$(HELPER_SOURCES))))

# Whether there is a signature to apply is settled once, here, rather than
# inside the canned recipe below: a conditional in a canned recipe is read as a
# shell command, not as a directive.
ifeq ($(LDID),)
SIGN = @echo "warning: ldid not found — $(1) is unsigned and will not launch on device"
else
SIGN = @$(LDID) -S $(1) && echo "ad-hoc signed with ldid"
endif

# Fat binary, then ad-hoc signature. Unsigned is SIGKILL at launch on the
# phone, for the helper exactly as much as for the app.
define LIPO_AND_SIGN
	@mkdir -p $(APPDIR)
	lipo -create $(1) -output $(2)
	@lipo -info $(2)
	$(call SIGN,$(2))
endef

$(BINARY): $(SLICES)
	$(call LIPO_AND_SIGN,$(SLICES),$@)

$(HELPER): $(HELPER_SLICES)
	$(call LIPO_AND_SIGN,$(HELPER_SLICES),$@)

$(APPDIR)/Info.plist: Resources/Info.plist
	@mkdir -p $(APPDIR)
	cp $< $@

# Bundled agent skills. Copied as a tree; SKILL.md is read into the
# launch-time system prompt.
$(SKILLS): $(shell find Resources/skills -type f)
	@mkdir -p $(APPDIR)
	rm -rf $@
	COPYFILE_DISABLE=1 cp -R Resources/skills $@

# iOS 4's SpringBoard/UIKit expect Apple-optimized (CgBI, premultiplied) PNGs;
# plain RGBA icons get bright fringes on the rounded corners and a wrong tap
# highlight mask. pngcrush ships with Xcode.
PNGCRUSH := $(shell xcrun -f pngcrush 2>/dev/null)

$(APPDIR)/%.png: Resources/%.png
	@mkdir -p $(APPDIR)
	@if [ -n "$(PNGCRUSH)" ]; then $(PNGCRUSH) -q -iphone -f 0 $< $@; else cp $< $@; fi

artwork:
	python3 tools/mkassets.py

# Both checks exit non-zero. They used to print their own failure and return 0,
# so the two regressions this target exists to catch would sail through CI and
# through a person reading the log too quickly.
verify: app
	@for b in $(BINARY) $(HELPER); do \
	    echo "== $$b =="; lipo -info $$b; \
	    for a in $(ARCHS); do \
	        echo "== $$b $$a =="; \
	        otool -arch $$a -l $$b | grep -A2 LC_VERSION_MIN_IPHONEOS | head -3; \
	        v=$$(otool -arch $$a -l $$b | grep -A2 LC_VERSION_MIN_IPHONEOS | \
	            sed -n 's/^ *version *//p' | head -1); \
	        if [ "$$v" != "$(DEPLOY_TARGET)" ]; then \
	            echo "  !! deployment target is $$v, expected $(DEPLOY_TARGET)"; exit 1; \
	        fi; \
	        echo "  LC_VERSION_MIN_IPHONEOS $$v ok"; \
	        otool -arch $$a -l $$b | grep -q LC_UNIXTHREAD \
	            || { echo "  !! LC_MAIN present — will not launch on iOS 4"; exit 1; }; \
	        echo "  LC_UNIXTHREAD ok (iOS 4 dyld cannot load LC_MAIN)"; \
	        if [ "$$a" = armv6 ]; then \
	            bad=$$(otool -arch $$a -tV $$b | \
	                awk '/[ \t](movw|movt)[ \t]/ { n++ } END { print n+0 }'); \
	            if [ "$$bad" != 0 ]; then \
	                echo "  !! $$bad movw/movt in the armv6 slice — an ARM11 cannot execute those"; exit 1; \
	            fi; \
	            echo "  no movw/movt in the armv6 slice ok"; \
	        fi; \
	        if [ "$$a" = armv7 ]; then \
	            bad=$$(otool -arch $$a -ov $$b | \
	                awk '/^ *imp +0x[0-9a-f]+/ && $$2 != "0x0" && $$2 ~ /[02468ace]$$/ { n++ } END { print n+0 }'); \
	            if [ "$$bad" != 0 ]; then \
	                echo "  !! $$bad method IMPs lack the Thumb bit — category merging is back on"; exit 1; \
	            fi; \
	            echo "  method IMPs carry the Thumb bit ok"; \
	        fi; \
	    done; \
	done

ipa: app
	@rm -rf $(BUILD)/Payload $(BUILD)/$(APP_NAME).ipa
	@mkdir -p $(BUILD)/Payload
	cp -R $(APPDIR) $(BUILD)/Payload/
	cd $(BUILD) && zip -qr $(APP_NAME).ipa Payload
	@rm -rf $(BUILD)/Payload
	@echo "built $(BUILD)/$(APP_NAME).ipa"

deb: app
	# Every stale .deb goes, not only this version's: a rebuild after a version
	# bump used to leave the old package sitting in build/ for `make
	# install-device` to pick up, and installing yesterday's app over today's
	# is a confusing way to lose an afternoon.
	rm -rf $(DEBROOT) $(BUILD)/$(PACKAGE_ID)_*_iphoneos-arm.deb
	mkdir -p $(DEBROOT)/Applications $(DEBROOT)/DEBIAN
	cp -R $(APPDIR) $(DEBROOT)/Applications/
	cp Packaging/control Packaging/postinst Packaging/postrm $(DEBROOT)/DEBIAN/
	chmod 0755 $(DEBROOT)/DEBIAN/postinst $(DEBROOT)/DEBIAN/postrm
	# The app itself is an ordinary 0755 Mach-O launched by SpringBoard as
	# mobile — no setuid bit, and so no launch script in front of it either.
	# The helper beside it is the one thing installed 4755.
	chmod 0755 $(DEBROOT)/Applications/$(APP_NAME).app/$(APP_NAME)
	chmod 4755 $(DEBROOT)/Applications/$(APP_NAME).app/$(HELPER_NAME)
	$(call STAMP_MTIME,$(DEBROOT))
	COPYFILE_DISABLE=1 dpkg-deb --root-owner-group -Zgzip -z9 --build $(DEBROOT) $(DEB)
	@echo "built $(DEB)"

# Downloads and verifies every pinned package, packs Theos and the SDK
# headers, writes the install plan, and builds the payload package.
#
# gzip, not xz: the dpkg on an iOS 4 phone cannot unpack anything else. -z1
# because the contents are already-compressed archives, where a higher setting
# buys nothing and costs minutes.
payload: $(PAYLOAD_TARGETS:%=payload-%)

# Everything a phone needs, and a check that it is all there. `make` alone
# builds the app, which is what iterating on it wants; shipping wants this.
# Offline by design: every archive is already in build/payload/cache, pinned by
# sha256 in Packaging/payload.lock, so this reproduces without the network.
package: deb
	$(MAKE) payload PAYLOAD_ARGS=--offline
	@missing=""; \
	for f in $(BUILD)/$(PACKAGE_ID)_$(PACKAGE_VER)_iphoneos-arm.deb $(PAYLOAD_DEBS); do \
	    test -s "$$f" || missing="$$missing $$f"; \
	done; \
	if [ -n "$$missing" ]; then echo "package incomplete:$$missing" >&2; exit 1; fi
	@echo
	@echo "complete package:"
	@ls -lh $(BUILD)/$(PACKAGE_ID)_$(PACKAGE_VER)_iphoneos-arm.deb $(PAYLOAD_DEBS) | \
	    awk '{ printf "  %-58s %s\n", $$9, $$5 }' 

# Both trees unpack to the same /var/airbuild/bootstrap, so the app reads one
# manifest.plist whichever family it is on and ABLBootstrap needs no target
# knowledge at all. Explicit rules, not a payload-% pattern: GNU make skips
# pattern rules for targets named in .PHONY, which silently produced
# "Nothing to be done for `payload-ios4'".
define PAYLOAD_RULE
payload-$(1): DEBROOT_$(1) := $$(BUILD)/payload-debroot-$(1)
# The stub tree, because the SDK's device stubs are linked against it. Without
# this a fresh clone's first command can be `make payload`, and it stops at
# "run `make stubs` first" — which is a dependency, not an instruction.
payload-$(1): $$(STAMP)
	python3 tools/fetch_payload.py --target $(1) $$(PAYLOAD_ARGS)
	rm -rf $$(DEBROOT_$(1)) $$(BUILD)/$$(PACKAGE_ID).bootstrap$$(patsubst ios%,%,$(1))_*_iphoneos-arm.deb
	mkdir -p $$(DEBROOT_$(1))/var/airbuild $$(DEBROOT_$(1))/DEBIAN
	cp Packaging/bootstrap$$(patsubst ios%,%,$(1))-control $$(DEBROOT_$(1))/DEBIAN/control
	# The staged tree is exactly what ships; build/payload/cache holds every
	# candidate --refresh ever tried and must not end up on a phone.
	COPYFILE_DISABLE=1 cp -R $$(PAYLOAD)/$(1) $$(DEBROOT_$(1))/var/airbuild/bootstrap
	$$(call STAMP_MTIME,$$(DEBROOT_$(1)))
	COPYFILE_DISABLE=1 dpkg-deb --root-owner-group -Zgzip -z1 --build \
		$$(DEBROOT_$(1)) $$(call payload_deb,$(1))
	@echo "built $$(call payload_deb,$(1)) ($$$$(du -h $$(call payload_deb,$(1)) | cut -f1))"
endef
$(foreach t,$(PAYLOAD_TARGETS),$(eval $(call PAYLOAD_RULE,$(t))))

# Copy both packages to a real phone and install them. The payload is ~105 MB
# over 802.11g, so the script skips the copy when the device already holds a
# file of the same size.
install-device: deb payload
	$(require_device)
	tools/deploy_device.sh $(DEVICE)

# The end-to-end proof: compile, sign, package, install and launch a UIKit app
# using only the toolchain the Environment page installed on the phone. Needs
# install-device to have run and Environment to have finished.
hello-device:
	$(require_device)
	tools/hello_device.sh $(DEVICE)

# Re-resolve every package against both repositories and rewrite the pins.
# Rare, deliberate, and reviewed as a diff — this is what decides which
# compiler a phone gets.
payload-lock:
	python3 tools/fetch_payload.py --refresh

# The same, plus every package already installed on a real phone, so a wiped
# or half-broken device can be rebuilt from the payload alone.
payload-from-device:
	$(require_device)
	python3 tools/fetch_payload.py --refresh --from-device $(DEVICE)

test: $(BUILD)/JSONParserTests $(BUILD)/StreamTests $(BUILD)/ProjectStoreTests \
      $(BUILD)/StashTests $(BUILD)/ToolsTests
	$(BUILD)/JSONParserTests
	$(BUILD)/StreamTests
	$(BUILD)/ProjectStoreTests
	$(BUILD)/StashTests
	$(BUILD)/ToolsTests

$(BUILD)/JSONParserTests: tests/JSONParserTests.m src/ABLJSONParser.m src/ABLJSONParser.h
	@mkdir -p $(BUILD)
	xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Isrc \
		tests/JSONParserTests.m src/ABLJSONParser.m -framework Foundation -o $@

# Projects are plain files: the store, the round files and the working
# directory exec runs in all behave the same on the host as on the phone.
PROJECT_STORE_SOURCES := src/ABLProject.m src/ABLProjectStore.m src/ABLShell.m \
                         src/ABLPrivileged.m src/ABLStash.m

$(BUILD)/ProjectStoreTests: tests/ProjectStoreTests.m $(PROJECT_STORE_SOURCES)
	@mkdir -p $(BUILD)
	xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Isrc \
		tests/ProjectStoreTests.m $(PROJECT_STORE_SOURCES) \
		-framework Foundation -o $@

# EditFile, PatchFile and the working-tree digest. No helper exists on the
# host, so the privileged write falls back to writing as this user — which is
# exactly the path a bundle run in place takes too.
TOOLS_TEST_SOURCES := src/ABLTools.m src/ABLRepoDigest.m src/ABLTemplate.m \
                      src/ABLPrivileged.m src/ABLShell.m src/ABLStash.m src/ABLJSONParser.m

$(BUILD)/ToolsTests: tests/ToolsTests.m $(TOOLS_TEST_SOURCES)
	@mkdir -p $(BUILD)
	xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Isrc \
		tests/ToolsTests.m $(TOOLS_TEST_SOURCES) \
		-framework Foundation -framework Security -o $@

# The stash is the one part of this app that can leave a device unbootable, so
# its copy-verify-swap and its deny-list are exercised on the host, against a
# temporary tree, before any of it runs on a phone.
$(BUILD)/StashTests: tests/StashTests.m src/ABLStash.m src/ABLStash.h
	@mkdir -p $(BUILD)
	xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Isrc \
		tests/StashTests.m src/ABLStash.m -framework Foundation -o $@

# A real conversation with a real endpoint, so it spends the key's money and
# is not part of `make test`.
# Run with: make e2e E2E_ARGS="https://api.anthropic.com/v1 $$KEY [model]"
e2e: $(BUILD)/EndToEndTests
	$(BUILD)/EndToEndTests $(E2E_ARGS)

# The same conversation, built armv6 for the phone: it exercises the real
# iOS 4 TLS stack and the armv6 slice of the client. Copy build/ablchat to the
# device and run it there.
E2E_SOURCES := tests/EndToEndTests.m src/ABLChatClient.m src/ABLJSONParser.m src/ABLTrustAll.m

e2e-device: $(BUILD)/ablchat
	@echo "built $< — copy it to the device and run it there"

$(BUILD)/ablchat: ARCH := armv6
$(BUILD)/ablchat: LINK_ARCH := armv7
$(BUILD)/ablchat: $(E2E_SOURCES) tools/relabel_arch.py tools/patch_minos.py | $(STAMP)
	@mkdir -p $(OBJ)/e2e $(BUILD)
	@rm -f $(OBJ)/e2e/*.o
	@for s in $(E2E_SOURCES); do \
	    echo "  compile [armv6] $$s"; \
	    $(CC) $(CFLAGS) -c $$s -o $(OBJ)/e2e/$$(basename $$s .m).o || exit 1; \
	done
	@lipo -thin armv6 "$(LEGACY_SDK)/usr/lib/crt1.3.1.o" -output $(OBJ)/e2e/crt1.startup
	@for o in $(OBJ)/e2e/*.o; do python3 tools/relabel_arch.py $$o armv7; done; python3 tools/relabel_arch.py $(OBJ)/e2e/crt1.startup armv7
	@echo "  link    [armv6] $@"
	@rm -f $@
	@$(CC) $(LDFLAGS) $(OBJ)/e2e/crt1.startup $(OBJ)/e2e/*.o -o $@ 2>&1 | grep -v "no platform load command" || true
	@test -f $@
	@python3 tools/relabel_arch.py $@ armv6
	@python3 tools/patch_minos.py $@ $(DEPLOY_TARGET) $(SDK_VERSION) >/dev/null
ifneq ($(LDID),)
	@$(LDID) -S $@
endif

$(BUILD)/EndToEndTests: $(E2E_SOURCES) src/ABLChatClient.h src/ABLConfig.h
	@mkdir -p $(BUILD)
	xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Isrc \
		$(E2E_SOURCES) -framework Foundation -framework Security -o $@

# The reply splitter runs on the host: it is Foundation-only, and its failures
# are chunk-boundary failures that no device run reproduces on demand.
$(BUILD)/StreamTests: tests/StreamTests.m src/ABLChatClient.m src/ABLJSONParser.m src/ABLTrustAll.m src/ABLChatClient.h
	@mkdir -p $(BUILD)
	xcrun clang -fno-objc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Isrc \
		tests/StreamTests.m src/ABLChatClient.m src/ABLJSONParser.m src/ABLTrustAll.m \
		-framework Foundation -framework Security -o $@

clean:
	rm -rf $(OBJ) $(APPDIR) $(BUILD)/Payload $(BUILD)/$(APP_NAME).ipa $(DEBROOT) \
	       $(BUILD)/$(PACKAGE_ID)_*_iphoneos-arm.deb \
	       $(BUILD)/$(PACKAGE_ID).bootstrap*_iphoneos-arm.deb \
	       $(BUILD)/payload/sdkstage \
	       $(PAYLOAD_TARGETS:%=$(BUILD)/payload-debroot-%) \
	       $(BUILD)/JSONParserTests $(BUILD)/StreamTests $(BUILD)/ProjectStoreTests \
	       $(BUILD)/StashTests $(BUILD)/ToolsTests $(BUILD)/EndToEndTests $(BUILD)/ablchat
	# build/payload keeps the downloaded archives; distclean is what discards them.

distclean:
	rm -rf $(BUILD)
