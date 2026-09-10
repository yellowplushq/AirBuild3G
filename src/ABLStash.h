#import <Foundation/Foundation.h>

// Moving a directory off the small system partition and leaving a symlink
// behind — the trick old jailbreaks used, because everything a package installs
// under /usr lands on a partition with megabytes free while /private/var has
// gigabytes.
//
// The convention is the one already on these devices: a bucket
// /var/stash/_.XXXXXX holding the directory under its original basename, and a
// sibling <bucket>.lnk file naming the original absolute path with no trailing
// newline.
//
// What the originals lacked, and this has: a deny-list that refuses anything
// dyld or launchd walks before /private/var is mounted, a full compare of both
// trees before the swap, and the original kept as <path>.airbuild-old for
// good. A dangling symlink where the system expects a directory is a phone
// that will not boot, so nothing here ever deletes an original — the undo
// below stays available for the life of the device.
//
// All of it is NSFileManager rather than shell: the stash runs before the
// coreutils package is installed, so cp, du and wc may not exist yet.
@interface ABLStash : NSObject

// Free bytes on the volume holding `path`. 0 when it cannot be read.
+ (unsigned long long)freeBytesAtPath:(NSString *)path;

// Whether `path` may be stashed at all, and why not when it may not.
+ (BOOL)canStashPath:(NSString *)path reason:(NSString **)reason;

// Copy, verify, then swap in the symlink. Appends what it did to `log`.
//
// Idempotent: a path this already stashed reports success and touches
// nothing. That matters because the install plan is re-runnable — Retry after
// a failed step, or a second Install — and a second bucket for one path would
// orphan the first and leave two claims on the same original.
+ (BOOL)stashPath:(NSString *)path log:(NSMutableString *)log;

// Where `path` is already stashed, or nil — by AirBuild or by the jailbreak
// that stashed /Applications and /usr/share years earlier. Checked before
// stashing so an existing stash is recognised rather than duplicated.
+ (NSString *)existingStashDestinationForPath:(NSString *)path;

// Puts `path` back and forgets the bucket. Only ever offered for a bucket
// AirBuild wrote — the ones the jailbreak made are not ours to undo.
+ (BOOL)unstashPath:(NSString *)path log:(NSMutableString *)log;

// The paths AirBuild has stashed, oldest first.
+ (NSArray *)stashedPaths;

// /var/stash and /var/airbuild/stash.plist by default; the tests point both
// somewhere writable.
+ (void)setStashDirectory:(NSString *)directory;
+ (void)setTrackingPath:(NSString *)path;
+ (NSString *)stashDirectory;
+ (NSString *)trackingPath;

@end
