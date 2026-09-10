#import <Foundation/Foundation.h>

#import "ABLStash.h"

#include <stdlib.h>
#include <unistd.h>

static void require(BOOL condition, NSString *message) {
	if (!condition) {
		NSLog(@"FAIL: %@", message);
		exit(1);
	}
}

static NSFileManager *files(void) {
	return [NSFileManager defaultManager];
}

static void writeFile(NSString *path, NSString *text) {
	[files() createDirectoryAtPath:[path stringByDeletingLastPathComponent]
		withIntermediateDirectories:YES attributes:nil error:NULL];
	require([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL],
		([NSString stringWithFormat:@"should write %@", path]));
}

static BOOL isSymlink(NSString *path) {
	NSDictionary *attributes = [files() attributesOfItemAtPath:path error:NULL];
	return [[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink];
}

static NSString *bucketIn(NSString *stash) {
	for (NSString *entry in [files() contentsOfDirectoryAtPath:stash error:NULL]) {
		if (![entry hasSuffix:@".lnk"]) {
			return entry;
		}
	}
	return nil;
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"ablstash-%d", (int)getpid()]];
	[files() removeItemAtPath:root error:NULL];
	NSString *stash = [root stringByAppendingPathComponent:@"stash"];
	[ABLStash setStashDirectory:stash];
	[ABLStash setTrackingPath:[root stringByAppendingPathComponent:@"stash.plist"]];

	// --- The deny-list is the whole point of this class, so check all of it.
	NSArray *denied = [NSArray arrayWithObjects:@"/", @"/usr", @"/usr/lib", @"/usr/bin",
		@"/usr/sbin", @"/System", @"/Applications", @"/Library", @"/var", @"/private",
		@"/etc", @"/bin", @"/sbin", @"/dev", @"/tmp", @"/opt", @"/nonexistent-top-level", nil];
	for (NSString *path in denied) {
		NSString *reason = nil;
		require(![ABLStash canStashPath:path reason:&reason],
			([NSString stringWithFormat:@"%@ must be refused", path]));
		require([reason length] > 0, @"a refusal should say why");
	}
	require(![ABLStash canStashPath:@"usr/libexec" reason:NULL], @"a relative path must be refused");

	// --- Spelling is not identity on these devices: /var is a symlink to
	//     /private/var, and a deny-list matched on text alone would wave
	//     through the same directory reached by its other name.
	NSArray *aliases = [NSArray arrayWithObjects:@"/private/etc", @"/private/var",
		@"/private/tmp", @"/usr/lib/../lib", @"/usr/./bin", @"/System/", nil];
	for (NSString *path in aliases) {
		require(![ABLStash canStashPath:path reason:NULL],
			([NSString stringWithFormat:@"%@ must be refused as an alias of a denied path", path]));
	}

	// --- A tree shaped like the one this exists for.
	NSString *subject = [root stringByAppendingPathComponent:@"system/libexec"];
	writeFile([subject stringByAppendingPathComponent:@"cc1obj"], @"one");
	writeFile([subject stringByAppendingPathComponent:@"gcc/arm-apple-darwin9/4.2/cc1"], @"two");
	writeFile([subject stringByAppendingPathComponent:@"日本語.txt"], @"三");
	// A real /usr/libexec is full of links, including ones that point back up
	// their own tree and ones whose target no longer exists. Neither may turn
	// the walk or the copy into a loop.
	require(symlink("../..", [[subject stringByAppendingPathComponent:@"gcc/loop"] fileSystemRepresentation]) == 0,
		@"should be able to plant a symlink loop");
	require(symlink("/etc/hosts", [[subject stringByAppendingPathComponent:@"absolute"] fileSystemRepresentation]) == 0,
		@"should be able to plant an absolute symlink");
	require(symlink("gone", [[subject stringByAppendingPathComponent:@"dangling"] fileSystemRepresentation]) == 0,
		@"should be able to plant a dangling symlink");
	require([ABLStash canStashPath:subject reason:NULL], @"an ordinary directory should be stashable");

	// --- Nothing may stash the stash, by either spelling.
	require(![ABLStash canStashPath:root reason:NULL], @"a directory containing the stash must be refused");
	[files() createDirectoryAtPath:[stash stringByAppendingPathComponent:@"_.AAAAAA/x"]
		withIntermediateDirectories:YES attributes:nil error:NULL];
	require(![ABLStash canStashPath:[stash stringByAppendingPathComponent:@"_.AAAAAA/x"] reason:NULL],
		@"a directory inside the stash must be refused");
	[files() removeItemAtPath:[stash stringByAppendingPathComponent:@"_.AAAAAA"] error:NULL];

	// --- A stash that cannot even begin must leave the path exactly as it was.
	[files() removeItemAtPath:stash error:NULL];
	writeFile(stash, @"not a directory");
	NSMutableString *log = [NSMutableString string];
	require(![ABLStash stashPath:subject log:log], @"an unusable stash directory should fail the stash");
	require(!isSymlink(subject), @"a failed stash must not have swapped anything");
	require(![files() fileExistsAtPath:[subject stringByAppendingString:@".airbuild-old"]],
		@"a failed stash must not have renamed anything");
	require([[ABLStash stashedPaths] count] == 0, @"a failed stash must not be tracked");
	[files() removeItemAtPath:stash error:NULL];

	// --- The real thing.
	log = [NSMutableString string];
	require([ABLStash stashPath:subject log:log], ([NSString stringWithFormat:@"stash should succeed: %@", log]));
	require([log rangeOfString:@"verified"].location != NSNotFound, @"the copy should be verified before the swap");
	require(isSymlink(subject), @"the original path should be a symlink now");
	require([[NSString stringWithContentsOfFile:[subject stringByAppendingPathComponent:@"gcc/arm-apple-darwin9/4.2/cc1"]
		encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"two"],
		@"reading through the symlink should give the original content");
	// The whole point of a stash is that the source partition ends up emptier.
	// Keeping <path>.airbuild-old beside the original leaves the tree exactly
	// where it was, which is what happened on the reference 3G: the step
	// reported success and `df` had not moved. The verified bucket copy is the
	// undo, and unstashPath: restores from it.
	NSString *backup = [subject stringByAppendingString:@".airbuild-old"];
	require(![files() fileExistsAtPath:backup],
		@"the backup must be removed once the symlink reads back, or nothing is freed");

	// The links came across as links, which is the only reason the walk and the
	// copy both terminated.
	NSDictionary *loop = [files() attributesOfItemAtPath:[subject stringByAppendingPathComponent:@"gcc/loop"] error:NULL];
	require([[loop objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink],
		@"a symlink loop must be copied as a link, not followed");
	require([[files() destinationOfSymbolicLinkAtPath:[subject stringByAppendingPathComponent:@"dangling"] error:NULL]
		isEqualToString:@"gone"], @"a dangling symlink must survive as it was");

	// --- Bucket and sidecar follow the convention already on these devices.
	NSString *bucket = bucketIn(stash);
	require(bucket != nil && [bucket hasPrefix:@"_."] && [bucket length] == 8,
		@"the bucket should be _. plus six characters");
	NSString *sidecar = [stash stringByAppendingPathComponent:[bucket stringByAppendingString:@".lnk"]];
	require([[NSData dataWithContentsOfFile:sidecar] isEqualToData:[subject dataUsingEncoding:NSUTF8StringEncoding]],
		@"the sidecar holds the original path with no trailing newline");
	require([[ABLStash stashedPaths] count] == 1, @"the stash should be tracked");
	require(![ABLStash canStashPath:subject reason:NULL], @"an already-stashed path should be refused");

	// --- Undo restores the original exactly.
	log = [NSMutableString string];
	require([ABLStash unstashPath:subject log:log], ([NSString stringWithFormat:@"unstash should succeed: %@", log]));
	require(!isSymlink(subject), @"the path should be a real directory again");
	require([[NSString stringWithContentsOfFile:[subject stringByAppendingPathComponent:@"日本語.txt"]
		encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"三"], @"content should survive the undo");
	require(![files() fileExistsAtPath:[stash stringByAppendingPathComponent:bucket]], @"the bucket should be gone");
	require(![files() fileExistsAtPath:sidecar], @"the sidecar should be gone");
	require([[ABLStash stashedPaths] count] == 0, @"the tracking file should be empty again");
	require(![ABLStash unstashPath:subject log:log], @"a path AirBuild did not stash is never undone");

	// --- Stashing is idempotent: the plan is re-runnable (Retry, or a second
	//     Install), and a second bucket for one path would orphan the first.
	log = [NSMutableString string];
	require([ABLStash stashPath:subject log:log], @"the path should stash again");
	bucket = bucketIn(stash);
	log = [NSMutableString string];
	require([ABLStash stashPath:subject log:log], @"stashing an already-stashed path should succeed");
	require([[ABLStash stashedPaths] count] == 1, @"a second stash must not add a second bucket");
	require([bucketIn(stash) isEqualToString:bucket], @"the bucket must be the one already there");
	require(isSymlink(subject), @"the symlink should be untouched");
	require([[NSString stringWithContentsOfFile:[subject stringByAppendingPathComponent:@"cc1obj"]
		encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"one"],
		@"an idempotent stash must not disturb the content");

	// --- A stash somebody else made is recognised, not duplicated. Every one of
	//     these devices was stashed by its jailbreak years before AirBuild:
	//     /Applications and /usr/share are already symlinks into /var/stash.
	NSString *foreign = [root stringByAppendingPathComponent:@"Applications"];
	NSString *foreignBucket = [stash stringByAppendingPathComponent:@"_.Zz9Qb1"];
	require([files() createDirectoryAtPath:[foreignBucket stringByAppendingPathComponent:@"Applications"]
		withIntermediateDirectories:YES attributes:nil error:NULL], @"the foreign bucket should be created");
	[[foreign dataUsingEncoding:NSUTF8StringEncoding]
		writeToFile:[foreignBucket stringByAppendingString:@".lnk"] atomically:YES];
	require(symlink([[foreignBucket stringByAppendingPathComponent:@"Applications"] fileSystemRepresentation],
		[foreign fileSystemRepresentation]) == 0, @"the foreign symlink should be planted");
	require([ABLStash existingStashDestinationForPath:foreign] != nil,
		@"a bucket written by the jailbreak should be recognised");
	log = [NSMutableString string];
	require([ABLStash stashPath:foreign log:log],
		@"an already-stashed path should report success rather than being stashed twice");
	require([[ABLStash stashedPaths] count] == 1,
		@"recognising somebody else's stash must not add it to our tracking file");
	require(![ABLStash unstashPath:foreign log:log],
		@"a bucket AirBuild did not create is never undone");

	[files() removeItemAtPath:root error:NULL];
	NSLog(@"PASS: stash");
	[pool release];
	return 0;
}
