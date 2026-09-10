# An app built on the phone. `make install` puts it on the springboard.
#
# Everything specific to this iPhone comes from /etc/profile.d/airbuild.sh, so
# there are no compiler paths or SDK flags in here to get wrong. Read it with
# `cat /etc/profile.d/airbuild.sh` if you want to see what they are.

NAME    := __NAME__
BUNDLE  := __BUNDLE__
SCHEME  := __SCHEME__
VERSION := 1.0.0

FRAMEWORKS := UIKit Foundation CoreGraphics

SOURCES := $(wildcard src/*.m)
OBJECTS := $(patsubst src/%.m,build/%.o,$(SOURCES))
DEB     := build/$(BUNDLE)_$(VERSION)_iphoneos-arm.deb

.PHONY: all package install run clean

all: build/$(NAME)

build/%.o: src/%.m | build
	@echo "  compile $<"
	@gcc -c $(IOS_CFLAGS) $< -o $@

# Compiling and linking take different flags, so they are separate steps.
# A missing -framework is a link error here, which is the point: link stubs
# with real symbol names are what make it one instead of a crash at launch.
build/$(NAME): $(OBJECTS)
	@echo "  link    $@"
	@gcc $(OBJECTS) -o $@ $(IOS_LDFLAGS) $(addprefix -framework ,$(FRAMEWORKS))
	@# Unsigned is SIGKILL at launch, not a warning.
	@ldid -S $@

build:
	@mkdir -p build

package: all
	@rm -rf build/layout
	@mkdir -p build/layout/Applications/$(NAME).app build/layout/DEBIAN
	@cp build/$(NAME) build/layout/Applications/$(NAME).app/
	@cp Info.plist build/layout/Applications/$(NAME).app/Info.plist
	@printf 'Package: %s\nName: %s\nVersion: %s\nArchitecture: iphoneos-arm\n' \
		"$(BUNDLE)" "$(NAME)" "$(VERSION)" > build/layout/DEBIAN/control
	@printf 'Description: Built on an iPhone 3G with AirBuild.\nMaintainer: AirBuild\nAuthor: AirBuild\nSection: Applications\nDepends: firmware (>= 4.0)\n' \
		>> build/layout/DEBIAN/control
	@# gzip: the dpkg on this phone cannot unpack anything else.
	@dpkg-deb -Zgzip -b build/layout $(DEB) >/dev/null
	@echo "  package $(DEB)"

install: package
	@dpkg -i $(DEB)
	@# uicache refuses root on this firmware.
	@su mobile -c uicache
	@echo "  installed — make run, or tap it on the springboard"

# uiopen takes a URL and nothing else; a bundle identifier gets an
# "unsupported URL" prompt. That is what the scheme in Info.plist is for.
run:
	@uiopen $(SCHEME)://

clean:
	@rm -rf build
