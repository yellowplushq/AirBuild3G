#import "ABLStash.h"
#import "ABLConfig.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Paths that must never move. /usr/lib and /usr/bin hold dyld's and launchd's
// own dependencies and are walked before /private/var is mounted; the rest are
// either the mount points themselves or directories SpringBoard cannot start
// without. /usr/libexec is the one we do take, because nothing in the boot path
// reads it.
// Refused as themselves, but their children may still move. /usr is here and
// /usr/libexec is not, because moving /usr/libexec is the entire point of the
// stash; /usr/lib is here for the same reason — dyld reads the dylibs sitting
// directly in it, while /usr/lib/gcc underneath is GCC's own and is the second
// path the install plan moves.
static NSString *const ABLStashDenyExact[] = {
	@"/", @"/private", @"/var", @"/etc", @"/usr", @"/usr/lib",
	@"/Applications", @"/Library", @"/cores", @"/tmp",
};
static const NSUInteger ABLStashDenyExactCount = sizeof(ABLStashDenyExact) / sizeof(ABLStashDenyExact[0]);

// Refused along with everything inside them. These are what the kernel, dyld
// and launchd walk before /private/var is mounted, so a symlink anywhere in
// here is a phone that does not boot. /System/Library/CoreServices is
// SpringBoard, which is why equality alone was not enough.
static NSString *const ABLStashDenySubtree[] = {
	@"/System", @"/bin", @"/sbin", @"/dev", @"/usr/bin", @"/usr/sbin",
	@"/usr/libexec/lockdownd", @"/Library/LaunchDaemons",
};
static const NSUInteger ABLStashDenySubtreeCount = sizeof(ABLStashDenySubtree) / sizeof(ABLStashDenySubtree[0]);

// What the original directory is renamed to before the symlink takes its
// place. Recovery is `rm <path> && mv <path>.airbuild-old <path>`.
static NSString *const ABLStashBackupSuffix = @".airbuild-old";

// Room left over on the destination after the copy. Filling the data
// partition exactly is how you end up with two half-written trees.
static const unsigned long long ABLStashHeadroom = 8ULL * 1024 * 1024;

static NSString *const ABLStashTrackedPathKey = @"path";
static NSString *const ABLStashTrackedBucketKey = @"bucket";

static NSString *ABLStashDirectoryOverride = nil;
static NSString *ABLStashTrackingOverride = nil;

// The alphabet the existing buckets on these devices use.
static NSString *ABLRandomBucketName(void) {
	static const char alphabet[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
	char name[9] = "_.";
	for (int i = 0; i < 6; i++) {
		name[2 + i] = alphabet[arc4random() % (sizeof(alphabet) - 1)];
	}
	name[8] = '\0';
	return [NSString stringWithUTF8String:name];
}

// Whether two paths name the same directory, whatever route was used to reach
// it. Spelling is not enough on these devices: /var is a symlink to
// /private/var, /Applications and /usr/share are already symlinks into
// /var/stash, and a deny-list matched on text alone would wave through
// /private/etc while refusing /etc. stat() follows the route; the device and
// inode pair is the identity.
static BOOL ABLIsSameDirectory(NSString *left, NSString *right) {
	struct stat a, b;
	if (stat([left fileSystemRepresentation], &a) != 0) {
		return NO;
	}
	if (stat([right fileSystemRepresentation], &b) != 0) {
		return NO;
	}
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

// Whether `ancestor` contains `path`, compared after both have had their
// symlinks resolved, so "is this inside the stash" cannot be dodged by
// spelling /var as /private/var.
static BOOL ABLPathIsInside(NSString *path, NSString *ancestor) {
	NSString *resolvedPath = [path stringByResolvingSymlinksInPath];
	NSString *resolvedAncestor = [ancestor stringByResolvingSymlinksInPath];
	if ([resolvedPath isEqualToString:resolvedAncestor]) {
		return YES;
	}
	return [resolvedPath hasPrefix:[resolvedAncestor stringByAppendingString:@"/"]];
}

// A tree's identity: how many entries it holds, how many bytes of regular file
// content, and a digest of "type:mode:relative-path" for every entry. The three
// together are what the copy is checked against — a short read, a half-full
// partition, a fifo copied as an empty file or a setuid bit dropped off
// something in /usr/libexec all change at least one of them.
//
// The digest replaces the set of entry strings this used to build. A stash
// verifies twice and holds two censuses side by side each time, and
// /usr/libexec is tens of thousands of entries, so the sets were several
// megabytes of live strings at the tightest moment of the install — on a phone
// with 128 MB, no swap, and dpkg about to run. Folding each entry into a
// 64-bit hash as it is seen costs nothing to hold. The per-entry hashes are
// combined by both sum and xor so the result does not depend on the order the
// two walks happen to return, which is the one property the set had that a
// running hash would not.
//
// -enumeratorAtPath: reports a symbolic link as a link and does not descend
// into it, so a directory containing a link back to one of its own ancestors
// is walked once rather than forever. -copyItemAtPath:toPath: recreates such a
// link as a link for the same reason. Both were checked rather than assumed;
// the tests below keep them honest.
static NSString *const ABLCensusCountKey = @"count";
static NSString *const ABLCensusBytesKey = @"bytes";
static NSString *const ABLCensusSumKey = @"sum";
static NSString *const ABLCensusXorKey = @"xor";

static unsigned long long ABLEntryHash(NSString *type, unsigned long mode, NSString *relative) {
	// FNV-1a over the UTF-8 of "type:mode:relative-path", read through a fixed
	// buffer so an entry of any name costs the same nothing to hash.
	unsigned long long hash = 14695981039346656037ULL;
	char header[64];
	int headerLength = snprintf(header, sizeof(header), "%s:%lo:",
		type != nil ? [type UTF8String] : "?", mode);
	for (int i = 0; i < headerLength; i++) {
		hash = (hash ^ (unsigned char)header[i]) * 1099511628211ULL;
	}
	unsigned char buffer[512];
	NSRange range = NSMakeRange(0, [relative length]);
	while (range.length > 0) {
		NSUInteger used = 0;
		NSRange remaining = NSMakeRange(NSMaxRange(range), 0);
		[relative getBytes:buffer maxLength:sizeof(buffer) usedLength:&used
			encoding:NSUTF8StringEncoding options:0 range:range remainingRange:&remaining];
		if (used == 0) {
			break;
		}
		for (NSUInteger i = 0; i < used; i++) {
			hash = (hash ^ buffer[i]) * 1099511628211ULL;
		}
		range = remaining;
	}
	return hash;
}

static NSDictionary *ABLTreeCensus(NSString *root) {
	NSFileManager *files = [NSFileManager defaultManager];
	NSDirectoryEnumerator *enumerator = [files enumeratorAtPath:root];
	if (enumerator == nil) {
		return nil;
	}
	unsigned long long bytes = 0, sum = 0, mixed = 0, count = 0;
	NSString *relative;
	// The walk autoreleases a path and a ten-key attributes dictionary per
	// entry, so the pool is drained inside the loop rather than held until the
	// caller's.
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSUInteger sinceDrain = 0;
	while ((relative = [enumerator nextObject]) != nil) {
		NSDictionary *attributes = [enumerator fileAttributes];
		NSString *type = [attributes objectForKey:NSFileType];
		unsigned long long hash = ABLEntryHash(type,
			[[attributes objectForKey:NSFilePosixPermissions] unsignedLongValue], relative);
		sum += hash;
		mixed ^= hash;
		count++;
		if ([type isEqualToString:NSFileTypeRegular]) {
			bytes += [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
		}
		if (++sinceDrain >= 512) {
			[pool release];
			pool = [[NSAutoreleasePool alloc] init];
			sinceDrain = 0;
		}
	}
	[pool release];
	return [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithUnsignedLongLong:count], ABLCensusCountKey,
		[NSNumber numberWithUnsignedLongLong:bytes], ABLCensusBytesKey,
		[NSNumber numberWithUnsignedLongLong:sum], ABLCensusSumKey,
		[NSNumber numberWithUnsignedLongLong:mixed], ABLCensusXorKey,
		nil];
}

// Whether two censuses describe the same tree. A missing census never matches.
static BOOL ABLCensusMatches(NSDictionary *left, NSDictionary *right) {
	if (left == nil || right == nil) {
		return NO;
	}
	NSString *const keys[] = {ABLCensusCountKey, ABLCensusBytesKey, ABLCensusSumKey, ABLCensusXorKey};
	for (NSUInteger i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
		if (![[left objectForKey:keys[i]] isEqualToNumber:[right objectForKey:keys[i]]]) {
			return NO;
		}
	}
	return YES;
}

@implementation ABLStash

+ (NSString *)stashDirectory {
	return ABLStashDirectoryOverride != nil ? ABLStashDirectoryOverride : @"/var/stash";
}

+ (void)setStashDirectory:(NSString *)directory {
	if (directory == ABLStashDirectoryOverride) {
		return;
	}
	[ABLStashDirectoryOverride release];
	ABLStashDirectoryOverride = [directory copy];
}

+ (NSString *)trackingPath {
	if (ABLStashTrackingOverride != nil) {
		return ABLStashTrackingOverride;
	}
	return [ABLDefaultRoot stringByAppendingPathComponent:@"stash.plist"];
}

+ (void)setTrackingPath:(NSString *)path {
	if (path == ABLStashTrackingOverride) {
		return;
	}
	[ABLStashTrackingOverride release];
	ABLStashTrackingOverride = [path copy];
}

+ (unsigned long long)freeBytesAtPath:(NSString *)path {
	NSDictionary *attributes = [[NSFileManager defaultManager]
		attributesOfFileSystemForPath:path error:NULL];
	return [[attributes objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
}

#pragma mark - Tracking

// Only buckets recorded here are ever undone. The five the jailbreak made are
// not ours to touch.
+ (NSMutableArray *)tracked {
	NSArray *stored = [NSArray arrayWithContentsOfFile:[self trackingPath]];
	return stored != nil ? [NSMutableArray arrayWithArray:stored] : [NSMutableArray array];
}

+ (BOOL)writeTracked:(NSArray *)tracked {
	NSString *path = [self trackingPath];
	[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
		withIntermediateDirectories:YES attributes:nil error:NULL];
	return [tracked writeToFile:path atomically:YES];
}

+ (NSDictionary *)trackedEntryForPath:(NSString *)path {
	for (NSDictionary *entry in [self tracked]) {
		if ([[entry objectForKey:ABLStashTrackedPathKey] isEqualToString:path]) {
			return entry;
		}
	}
	return nil;
}

+ (NSArray *)stashedPaths {
	NSMutableArray *paths = [NSMutableArray array];
	for (NSDictionary *entry in [self tracked]) {
		[paths addObject:[entry objectForKey:ABLStashTrackedPathKey]];
	}
	return paths;
}

#pragma mark - Refusals

+ (BOOL)canStashPath:(NSString *)path reason:(NSString **)reason {
	NSString *standard = [path stringByStandardizingPath];
	if (![standard isAbsolutePath]) {
		if (reason != NULL) {
			*reason = @"not an absolute path";
		}
		return NO;
	}
	// A top-level directory of / is never worth the risk, listed or not: the
	// deny-list can only name what was known when it was written. Checked on
	// both spellings, since /private/var has three components and /var has two.
	if ([[standard pathComponents] count] <= 2
			|| [[[standard stringByResolvingSymlinksInPath] pathComponents] count] <= 2) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@ is a top-level directory", standard];
		}
		return NO;
	}
	// ABLIsSameDirectory sits alongside the string compare because it is the
	// inode check that catches /USR/LIB on a case-insensitive volume;
	// ABLPathIsInside is a case-sensitive prefix compare that would not.
	for (NSUInteger i = 0; i < ABLStashDenyExactCount; i++) {
		if ([standard isEqualToString:ABLStashDenyExact[i]]
				|| ABLIsSameDirectory(standard, ABLStashDenyExact[i])) {
			if (reason != NULL) {
				*reason = [NSString stringWithFormat:@"%@ is %@ itself, which the system reads before /private/var is mounted",
					standard, ABLStashDenyExact[i]];
			}
			return NO;
		}
	}
	for (NSUInteger i = 0; i < ABLStashDenySubtreeCount; i++) {
		if ([standard isEqualToString:ABLStashDenySubtree[i]]
				|| ABLIsSameDirectory(standard, ABLStashDenySubtree[i])
				|| ABLPathIsInside(standard, ABLStashDenySubtree[i])) {
			if (reason != NULL) {
				*reason = [NSString stringWithFormat:@"%@ is inside %@, which the system reads before /private/var is mounted",
					standard, ABLStashDenySubtree[i]];
			}
			return NO;
		}
	}
	// Stashing something that contains the stash — or AirBuild's own root —
	// would move the destination out from under the copy.
	if (ABLPathIsInside(standard, [self stashDirectory])
			|| ABLPathIsInside([self stashDirectory], standard)) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@ and the stash contain each other", standard];
		}
		return NO;
	}
	if (ABLPathIsInside([self trackingPath], standard)) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@ holds AirBuild's own record of what has been stashed", standard];
		}
		return NO;
	}

	NSFileManager *files = [NSFileManager defaultManager];
	NSDictionary *attributes = [files attributesOfItemAtPath:standard error:NULL];
	if (attributes == nil) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@ does not exist", standard];
		}
		return NO;
	}
	NSString *type = [attributes objectForKey:NSFileType];
	if ([type isEqualToString:NSFileTypeSymbolicLink]) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@ is already a symlink", standard];
		}
		return NO;
	}
	if (![type isEqualToString:NSFileTypeDirectory]) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@ is not a directory", standard];
		}
		return NO;
	}
	if ([files fileExistsAtPath:[standard stringByAppendingString:ABLStashBackupSuffix]]) {
		if (reason != NULL) {
			*reason = [NSString stringWithFormat:@"%@%@ is still here from an earlier attempt", standard, ABLStashBackupSuffix];
		}
		return NO;
	}
	return YES;
}

#pragma mark - Stash

// Where `path` is already stashed, or nil. Three ways of asking, because a
// device that has been jailbroken since 2010 was stashed long before AirBuild
// existed: /Applications, /usr/include and /usr/share on the reference 3G are
// all symlinks into /var/stash that we did not create and must not duplicate.
//
//   1. our own tracking plist — the only case unstashPath: will undo
//   2. a <bucket>.lnk sidecar naming this path — the convention every stasher
//      on these devices writes, ours included
//   3. the path is simply a symlink pointing inside the stash directory,
//      which catches a stash written by a tool that skipped the sidecar
+ (NSString *)existingStashDestinationForPath:(NSString *)path {
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *standard = [path stringByStandardizingPath];

	// Whatever the sidecars and the tracking file claim, a path is only
	// actually stashed if it is a symlink pointing at content that is there.
	// Without this, a dpkg that replaced the symlink with a real directory
	// still looked "already stashed", and stashPath: reported success while
	// leaving the tree on the system partition — silently, and for good.
	NSString *link = [files destinationOfSymbolicLinkAtPath:standard error:NULL];
	if (link == nil) {
		return nil;
	}
	NSString *resolved = [link isAbsolutePath] ? link
		: [[standard stringByDeletingLastPathComponent] stringByAppendingPathComponent:link];
	resolved = [resolved stringByStandardizingPath];
	if (!ABLPathIsInside(resolved, [self stashDirectory]) || ![files fileExistsAtPath:resolved]) {
		return nil;
	}

	// It points into the stash and the content exists. Corroborate it against
	// our own record, then against the .lnk sidecar convention, and otherwise
	// accept the link itself — a bucket written by the jailbreak in 2010 need
	// not match either bookkeeping scheme to be a real stash.
	NSDictionary *entry = [self trackedEntryForPath:standard];
	if (entry != nil) {
		NSString *bucket = [entry objectForKey:ABLStashTrackedBucketKey];
		if (ABLPathIsInside(resolved, bucket)) {
			return resolved;
		}
	}
	for (NSString *name in [files contentsOfDirectoryAtPath:[self stashDirectory] error:NULL]) {
		if (![[name pathExtension] isEqualToString:@"lnk"]) {
			continue;
		}
		NSString *sidecar = [[self stashDirectory] stringByAppendingPathComponent:name];
		NSString *claimed = [[[NSString alloc] initWithData:[NSData dataWithContentsOfFile:sidecar]
			encoding:NSUTF8StringEncoding] autorelease];
		// The convention stores the path with no trailing newline, but a
		// hand-written sidecar may well have one.
		claimed = [[claimed stringByTrimmingCharactersInSet:
			[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByStandardizingPath];
		if ([claimed isEqualToString:standard]) {
			return resolved;
		}
	}
	return resolved;
}

+ (BOOL)stashPath:(NSString *)path log:(NSMutableString *)log {
	NSString *standard = [path stringByStandardizingPath];

	// Already stashed: report success and touch nothing. This has to come
	// before canStashPath:, which refuses a symlink — and a stashed path *is*
	// a symlink. Without it, Retry or a second Install would cut a second
	// bucket for the same path, orphaning the first.
	NSString *already = [self existingStashDestinationForPath:standard];
	if (already != nil) {
		[log appendFormat:@"%@ is already stashed at %@\n", standard, already];
		return YES;
	}
	NSDictionary *staleEntry = [self trackedEntryForPath:standard];
	if (staleEntry != nil) {
		// We recorded a stash but its bucket is gone. Refuse rather than stash
		// on top of a half-undone state; unstashPath: is what resolves this.
		[log appendFormat:@"%@ is tracked but its bucket is missing; not stashing again\n",
			standard];
		return NO;
	}

	NSString *reason = nil;
	if (![self canStashPath:standard reason:&reason]) {
		[log appendFormat:@"refused %@: %@\n", standard, reason];
		return NO;
	}

	NSFileManager *files = [NSFileManager defaultManager];
	NSString *stash = [self stashDirectory];
	if (![files createDirectoryAtPath:stash withIntermediateDirectories:YES attributes:nil error:NULL]) {
		[log appendFormat:@"cannot create %@\n", stash];
		return NO;
	}

	// Measured before the copy, both as the yardstick the copy is checked
	// against and as the size the destination has to have room for. Filling the
	// data partition halfway through would leave two incomplete trees.
	NSDictionary *before = ABLTreeCensus(standard);
	if (before == nil) {
		[log appendFormat:@"cannot read %@\n", standard];
		return NO;
	}
	unsigned long long needed = [[before objectForKey:ABLCensusBytesKey] unsignedLongLongValue] + ABLStashHeadroom;
	unsigned long long available = [self freeBytesAtPath:stash];
	if (available < needed) {
		[log appendFormat:@"not enough room: %@ needs %llu KB and %@ has %llu KB\n",
			standard, needed / 1024, stash, available / 1024];
		return NO;
	}

	NSString *bucket = nil;
	for (int attempt = 0; attempt < 16 && bucket == nil; attempt++) {
		NSString *candidate = [stash stringByAppendingPathComponent:ABLRandomBucketName()];
		if (![files fileExistsAtPath:candidate]
				&& [files createDirectoryAtPath:candidate withIntermediateDirectories:NO attributes:nil error:NULL]) {
			bucket = candidate;
		}
	}
	if (bucket == nil) {
		[log appendFormat:@"cannot create a bucket in %@\n", stash];
		return NO;
	}

	NSString *basename = [standard lastPathComponent];
	NSString *destination = [bucket stringByAppendingPathComponent:basename];
	[log appendFormat:@"copying %@ to %@\n", standard, destination];

	// Copy rather than move: a cross-device move is a copy and a delete
	// anyway, and this way losing power leaves the original untouched.
	NSError *error = nil;
	if (![files copyItemAtPath:standard toPath:destination error:&error]) {
		[log appendFormat:@"copy failed: %@\n", [error localizedDescription]];
		[files removeItemAtPath:bucket error:NULL];
		return NO;
	}

	NSDictionary *after = ABLTreeCensus(destination);
	if (!ABLCensusMatches(before, after)) {
		[log appendFormat:@"verify failed: %@ entries / %@ bytes became %@ entries / %@ bytes; nothing was changed\n",
			[before objectForKey:ABLCensusCountKey], [before objectForKey:ABLCensusBytesKey],
			[after objectForKey:ABLCensusCountKey], [after objectForKey:ABLCensusBytesKey]];
		[files removeItemAtPath:bucket error:NULL];
		return NO;
	}
	[log appendFormat:@"verified %@ entries, %@ bytes\n",
		[before objectForKey:ABLCensusCountKey], [before objectForKey:ABLCensusBytesKey]];

	// The swap. Each syscall is atomic; the pair is not — between the rename
	// and the symlink the path does not exist at all, and a power loss there
	// leaves the tree only at <path>.airbuild-old. That window is unavoidable
	// (rename cannot replace a non-empty directory) and is why the bucket copy
	// is made and verified first.
	NSString *backup = [standard stringByAppendingString:ABLStashBackupSuffix];
	if (rename([standard fileSystemRepresentation], [backup fileSystemRepresentation]) != 0) {
		[log appendFormat:@"rename failed: %s; nothing was changed\n", strerror(errno)];
		[files removeItemAtPath:bucket error:NULL];
		return NO;
	}
	if (symlink([destination fileSystemRepresentation], [standard fileSystemRepresentation]) != 0) {
		[log appendFormat:@"symlink failed: %s; putting %@ back\n", strerror(errno), standard];
		if (rename([backup fileSystemRepresentation], [standard fileSystemRepresentation]) != 0) {
			// Nothing is at the path now and the only copy is the backup. Say
			// so loudly and keep the bucket, because both are now evidence.
			[log appendFormat:@"COULD NOT PUT IT BACK: %@ does not exist; restore it with\n"
				@"    mv %@ %@\n", standard, backup, standard];
			return NO;
		}
		[files removeItemAtPath:bucket error:NULL];
		return NO;
	}

	// The bookkeeping has to land before the backup goes, because without it
	// unstashPath: can never undo this.
	NSString *sidecar = [bucket stringByAppendingString:@".lnk"];
	BOOL wroteSidecar = [[standard dataUsingEncoding:NSUTF8StringEncoding]
		writeToFile:sidecar atomically:YES];
	NSMutableArray *tracked = [self tracked];
	[tracked addObject:[NSDictionary dictionaryWithObjectsAndKeys:
		standard, ABLStashTrackedPathKey,
		bucket, ABLStashTrackedBucketKey,
		nil]];
	BOOL wroteTracking = [self writeTracked:tracked];

	// Read the tree back through the symlink and compare it to the original
	// once more. This is the check that earns the right to delete the backup:
	// everything before it verified the copy, this verifies the path.
	NSDictionary *through = ABLTreeCensus(standard);
	BOOL resolves = ABLCensusMatches(before, through);

	if (!resolves || !wroteSidecar || !wroteTracking) {
		[log appendFormat:@"%@ is a symlink now but %@; putting it back\n", standard,
			!resolves ? @"does not read back the same tree"
				: @"the stash record could not be written"];
		unlink([standard fileSystemRepresentation]);
		if (rename([backup fileSystemRepresentation], [standard fileSystemRepresentation]) != 0) {
			[log appendFormat:@"COULD NOT PUT IT BACK: restore it with\n    mv %@ %@\n", backup, standard];
			return NO;
		}
		[files removeItemAtPath:bucket error:NULL];
		[files removeItemAtPath:sidecar error:NULL];
		return NO;
	}

	// Only now is the space actually free. Leaving <path>.airbuild-old in
	// place would keep the whole tree on the very partition this exists to
	// empty, so the stash would report success having freed nothing — which is
	// exactly what it did on the reference 3G. The undo is the verified bucket
	// copy on /private/var, and unstashPath: restores from it.
	NSError *removeError = nil;
	if (![files removeItemAtPath:backup error:&removeError]) {
		[log appendFormat:@"warning: %@ could not be removed (%@); the stash is in place "
			@"but this partition has not been freed\n", backup, [removeError localizedDescription]];
	}

	[log appendFormat:@"%@ -> %@\n", standard, destination];
	[log appendFormat:@"undo with: AirBuild Settings > Environment, or restore from %@\n", destination];
	return YES;
}

#pragma mark - Undo

+ (BOOL)unstashPath:(NSString *)path log:(NSMutableString *)log {
	NSString *standard = [path stringByStandardizingPath];
	NSDictionary *entry = [self trackedEntryForPath:standard];
	if (entry == nil) {
		[log appendFormat:@"%@ was not stashed by AirBuild\n", standard];
		return NO;
	}
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *bucket = [entry objectForKey:ABLStashTrackedBucketKey];

	if (![[[files attributesOfItemAtPath:standard error:NULL] objectForKey:NSFileType]
			isEqualToString:NSFileTypeSymbolicLink]) {
		[log appendFormat:@"%@ is not a symlink any more; leaving it alone\n", standard];
		return NO;
	}

	// The bucket copy is the only original — stashPath: removes
	// <path>.airbuild-old once the symlink has been read back and verified,
	// because leaving it there would free nothing. So the undo is always a
	// copy back, never a cheap rename.
	NSString *source = [bucket stringByAppendingPathComponent:[standard lastPathComponent]];
	if (![files fileExistsAtPath:source]) {
		[log appendFormat:@"%@ is missing; %@ cannot be restored from this bucket\n", source, standard];
		return NO;
	}
	// Staged beside the destination and moved in, so a failed or interrupted
	// copy never leaves the path empty: the symlink is only removed once the
	// full tree is on disk.
	NSString *staging = [standard stringByAppendingString:@".airbuild-restore"];
	[files removeItemAtPath:staging error:NULL];
	NSError *error = nil;
	if (![files copyItemAtPath:source toPath:staging error:&error]) {
		[log appendFormat:@"cannot copy %@ back: %@\n", source, [error localizedDescription]];
		[files removeItemAtPath:staging error:NULL];
		return NO;
	}
	if (unlink([standard fileSystemRepresentation]) != 0) {
		[log appendFormat:@"cannot remove the symlink at %@: %s\n", standard, strerror(errno)];
		[files removeItemAtPath:staging error:NULL];
		return NO;
	}
	if (rename([staging fileSystemRepresentation], [standard fileSystemRepresentation]) != 0) {
		// Nothing is at the path. Put the symlink back rather than leaving a
		// hole, so the device is at worst where it started.
		[log appendFormat:@"cannot move %@ into place: %s\n", staging, strerror(errno)];
		if (symlink([source fileSystemRepresentation], [standard fileSystemRepresentation]) != 0) {
			[log appendFormat:@"COULD NOT PUT IT BACK: %@ does not exist; restore it with\n"
				@"    mv %@ %@\n", standard, staging, standard];
		}
		return NO;
	}
	[log appendFormat:@"restored %@ from %@\n", standard, source];

	[files removeItemAtPath:[bucket stringByAppendingString:@".lnk"] error:NULL];
	[files removeItemAtPath:bucket error:NULL];

	NSMutableArray *tracked = [self tracked];
	[tracked removeObject:entry];
	[self writeTracked:tracked];
	return YES;
}

@end
