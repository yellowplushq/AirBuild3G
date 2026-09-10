#!/bin/sh
# One line per tool, saying whether it actually works.
#
# Run this first when a build fails for no clear reason. It answers the
# questions that are otherwise several rounds of guessing: is the environment
# installed, does the compiler run, are the SDK headers the ones GCC can read,
# and are the link stubs in place.

. /etc/profile.d/airbuild.sh 2>/dev/null

report() {
	printf "%-28s %s\n" "$1" "$2"
}

if [ -z "$SDKROOT" ]; then
	echo "environment not installed — Settings > Environment, then Install"
	exit 1
fi

for tool in gcc ld ldid make dpkg-deb git; do
	path=$(command -v $tool 2>/dev/null)
	report "$tool" "${path:-MISSING}"
done

report "gcc version" "$(gcc -dumpversion 2>&1 | head -1)"
report "SDKROOT" "$SDKROOT"

# The things that are specific to this phone, each checked rather than assumed.
# A "no" in any of them is the whole reason a build fails.
#
# Present is not enough: a stub with no symbols resolves nothing, so no
# LC_LOAD_DYLIB is recorded, a link that forgot a -framework succeeds, and the
# app dies at launch with "Symbol not found". Ask whether it exports anything.
#
# grep, not nm: odcctools' nm is from 2008 and rejects these stubs outright as
# "malformed object (unknown load command 4)". ld reads them perfectly well.
# A symbol name is plain text in the string table, so grep answers it.
stub=$SDKROOT/System/Library/Frameworks/Foundation.framework/Foundation
if [ ! -f "$stub" ]; then
	report "link stubs" "MISSING — reinstall the environment"
elif grep -q 'OBJC_CLASS_\$_NSAutoreleasePool' "$stub" 2>/dev/null; then
	report "link stubs" "carry symbols, as they must"
else
	report "link stubs" "EMPTY — reinstall the environment"
fi
case "$IOS_LDFLAGS" in
	*dynamic_lookup*) report "link flags" "STALE — reinstall the environment" ;;
	*-lobjc*) report "link flags" "ok" ;;
	*) report "link flags" "no -lobjc — reinstall the environment" ;;
esac
if grep -q '(\^' "$SDKROOT/System/Library/Frameworks/UIKit.framework/Headers/UIView.h" 2>/dev/null; then
	report "headers" "STILL DECLARE BLOCKS — reinstall the environment"
else
	report "headers" "no blocks, as GCC 4.2 needs"
fi
[ -n "$CPATH" ] && report "CPATH" "$CPATH"

# And then the only check that counts: does it build?
tmp=/tmp/ablcheck.$$
mkdir -p "$tmp"
printf '#import <UIKit/UIKit.h>\nint main(void){return 7;}\n' > "$tmp/t.m"
if gcc -c $IOS_CFLAGS "$tmp/t.m" -o "$tmp/t.o" 2>"$tmp/err" &&
   gcc "$tmp/t.o" -o "$tmp/t" $IOS_LDFLAGS -framework UIKit -framework Foundation \
       -framework CoreGraphics 2>>"$tmp/err" &&
   ldid -S "$tmp/t" 2>>"$tmp/err"; then
	"$tmp/t"; [ $? -eq 7 ] && report "build a UIKit binary" "works" \
		|| report "build a UIKit binary" "built, but did not run"
else
	report "build a UIKit binary" "FAILED"
	tail -5 "$tmp/err"
fi

# The other half of the same question: a framework left off the link must be
# an error. When it is not, every app built here installs and then dies at
# launch, and nothing before this line would have noticed.
printf '#import <UIKit/UIKit.h>\nint main(void){[[UIScreen mainScreen] bounds];return 0;}\n' > "$tmp/u.m"
if gcc -c $IOS_CFLAGS "$tmp/u.m" -o "$tmp/u.o" 2>/dev/null &&
   gcc "$tmp/u.o" -o "$tmp/u" $IOS_LDFLAGS 2>/dev/null; then
	report "missing framework" "LINKS ANYWAY — apps will crash at launch"
else
	report "missing framework" "is a link error, as it should be"
fi
rm -rf "$tmp"
