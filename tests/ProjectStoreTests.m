#import <Foundation/Foundation.h>

#import "ABLProject.h"
#import "ABLProjectStore.h"
#import "ABLShell.h"

#include <stdlib.h>

static void require(BOOL condition, NSString *message) {
	if (!condition) {
		NSLog(@"FAIL: %@", message);
		exit(1);
	}
}

// A transcript row shaped exactly like the chat page's, mutable content and all.
static NSMutableDictionary *row(NSString *role, NSString *content) {
	return [NSMutableDictionary dictionaryWithObjectsAndKeys:
		role, @"role", [NSMutableString stringWithString:content], @"content", nil];
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"ablstore-%d", (int)getpid()]];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	[ABLProjectStore setRoot:root];

	require([[ABLProjectStore projects] count] == 0, @"an empty root should list nothing");

	// --- create
	ABLProject *project = [ABLProjectStore createProjectNamed:@"日本語 / Tweak"];
	require(project != nil, @"a project with unicode and a slash in its name should be created");
	require([[project uuid] length] > 0, @"a project should have a uuid");
	require([[[project directory] lastPathComponent] isEqualToString:[project uuid]],
		@"the directory is named by the uuid, never by the name");
	NSFileManager *files = [NSFileManager defaultManager];
	require([files fileExistsAtPath:[project manifestPath]], @"manifest should exist");
	require([files fileExistsAtPath:[project workingDirectory]], @"working directory should exist");
	require([files fileExistsAtPath:[project conversationDirectory]], @"conversation directory should exist");

	// --- rounds round-trip
	for (NSUInteger index = 0; index < 3; index++) {
		NSArray *messages = [NSArray arrayWithObjects:
			row(@"user", ([NSString stringWithFormat:@"ask %lu", (unsigned long)index])),
			row(@"thinking", @"…"),
			row(@"tool", @"total 0\n"),
			row(@"assistant", ([NSString stringWithFormat:@"answer %lu — 日本語", (unsigned long)index])),
			nil];
		require([project writeRoundAtIndex:index messages:messages endReason:ABLRoundEndReasonComplete],
			@"a round should be written");
	}
	require([project roundCount] == 3, @"three rounds should be counted");

	ABLProject *reopened = [ABLProject projectWithDirectory:[project directory]];
	require(reopened != nil, @"a written project should reopen");
	require([[reopened name] isEqualToString:@"日本語 / Tweak"], @"the name should survive");
	require([reopened roundCount] == 3, @"the round count should survive");
	require([[reopened lastMessage] isEqualToString:@"answer 2 — 日本語"],
		@"the subtitle is the newest thing either side said, not the tool output");

	NSMutableArray *messages = [reopened loadMessages];
	require([messages count] == 12, @"every row of every round should load");
	require([[[messages objectAtIndex:0] objectForKey:@"content"] isEqualToString:@"ask 0"],
		@"rounds should load oldest first");
	// The chat page appends to the last row as tokens arrive, so a reloaded
	// transcript has to hand back mutable strings.
	[[[messages lastObject] objectForKey:@"content"] appendString:@"!"];
	require([[[messages lastObject] objectForKey:@"content"] isEqualToString:@"answer 2 — 日本語!"],
		@"a reloaded row should still be mutable");

	// --- rewriting a round in place is how closing one twice stays harmless
	NSArray *closed = [NSArray arrayWithObjects:row(@"user", @"ask 2"), row(@"assistant", @"final"), nil];
	require([project writeRoundAtIndex:2 messages:closed endReason:ABLRoundEndReasonStopped],
		@"a round should be rewritable");
	require([project roundCount] == 3, @"rewriting must not add a round");
	require([[[ABLProject projectWithDirectory:[project directory]] loadMessages] count] == 10,
		@"the rewritten round should replace the old one");

	// --- listing
	// The storage format is the invariant this whole design rests on: an XML
	// plist rounds NSDate to the whole second, so two projects touched in the
	// same second cannot be ordered and the list shuffles. Flipping
	// ABLWritePropertyList to XML still passed this suite roughly two runs in
	// three, because the only assertion that noticed did so by coincidence.
	// Pin the bytes instead.
	NSData *manifestData = [NSData dataWithContentsOfFile:[project manifestPath]];
	require([manifestData length] >= 8, @"the manifest should have been written");
	require([[[[NSString alloc] initWithData:[manifestData subdataWithRange:NSMakeRange(0, 8)]
		encoding:NSASCIIStringEncoding] autorelease] isEqualToString:@"bplist00"],
		@"manifest.plist must be a binary plist, not XML");
	NSData *roundData = [NSData dataWithContentsOfFile:[project pathForRoundAtIndex:0]];
	require([roundData length] >= 8, @"the round should have been written");
	require([[[[NSString alloc] initWithData:[roundData subdataWithRange:NSMakeRange(0, 8)]
		encoding:NSASCIIStringEncoding] autorelease] isEqualToString:@"bplist00"],
		@"round_0.plist must be a binary plist, not XML");

	ABLProject *second = [ABLProjectStore createProjectNamed:@"Second"];
	require(second != nil, @"a second project should be created");
	NSArray *listed = [ABLProjectStore projects];
	require([listed count] == 2, @"both projects should list");
	require([[[listed objectAtIndex:0] name] isEqualToString:@"Second"],
		@"the most recently modified project should sort first");

	// --- a broken project costs itself, not the list
	NSString *broken = [[ABLProjectStore projectsDirectory] stringByAppendingPathComponent:@"not-a-project"];
	[files createDirectoryAtPath:broken withIntermediateDirectories:YES attributes:nil error:NULL];
	[@"garbage" writeToFile:[broken stringByAppendingPathComponent:@"manifest.plist"]
		atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	require([[ABLProjectStore projects] count] == 2, @"an unreadable manifest should be skipped");

	// --- delete
	require([ABLProjectStore deleteProject:second], @"a project should delete");
	require([[ABLProjectStore projects] count] == 1, @"the deleted project should be gone");
	require(![files fileExistsAtPath:[second directory]], @"the tree should be gone with it");

	// --- exec runs where the project says it does
	NSString *output = ABLRunCommand(@"pwd", [project workingDirectory]);
	require([output rangeOfString:[project uuid]].location != NSNotFound,
		@"a command should run inside the project's working directory");
	require([ABLRunCommand(@"echo hi; exit 3", nil) hasSuffix:@"(exit 3)"],
		@"a non-zero exit should be reported");
	require([ABLRunCommand(@"printf ''", nil) isEqualToString:@"(no output)"],
		@"silence should read as no output");
	require([ABLRunCommand(@"echo oops >&2", nil) hasPrefix:@"oops"],
		@"stderr should be combined into the result");
	require([ABLRunCommand(@"pwd", @"/no/such/directory") hasSuffix:@"(exit 1)"],
		@"a missing working directory should fail the command, not run it elsewhere");

	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	NSLog(@"PASS: project store");
	[pool release];
	return 0;
}
