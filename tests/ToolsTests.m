// EditFile, PatchFile and the working-tree digest, on the host.
//
// These are the two pieces of the tool loop whose failures are silent: a
// PatchFile that matched the wrong occurrence leaves a file that still
// compiles, and a digest that quotes the wrong thing costs the model a turn
// finding out. Both are pure enough to run here, with no helper present, so
// the privileged path falls back to writing as this user.

#import <Foundation/Foundation.h>

#import "ABLRepoDigest.h"
#import "ABLShell.h"
#import "ABLTemplate.h"
#import "ABLTools.h"

#include <stdlib.h>
#include <unistd.h>

static void require(BOOL condition, NSString *message) {
	if (!condition) {
		NSLog(@"FAIL: %@", message);
		exit(1);
	}
}

// One tool call in the shape ABLChatClient freezes them into.
static NSDictionary *call(NSString *name, NSString *arguments) {
	return [NSDictionary dictionaryWithObjectsAndKeys:
		@"call_0", @"id", name, @"name", arguments, @"arguments", nil];
}

static NSString *contents(NSString *path) {
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"abltools-%d", (int)getpid()]];
	[files removeItemAtPath:root error:NULL];
	[files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];

	// --- the names a project turns into
	require([ABLTemplateAppName(@"Tip Calc (v2)") isEqualToString:@"TipCalcv2"],
		@"an app name keeps only what a file name and a Makefile variable can hold");
	require([ABLTemplateScheme(@"Tip Calc") isEqualToString:@"tipcalc"],
		@"the URL scheme is the app name, lowercased");
	require([ABLTemplateBundleIdentifier(@"Tip Calc") isEqualToString:@"com.airbuild.tipcalc"],
		@"the bundle identifier is derived, not invented");
	require([ABLTemplateAppName(@"日本語") isEqualToString:@"App"],
		@"a name with nothing ASCII in it still has to produce a usable one");
	require([ABLTemplateAppName(@"3G Tool") isEqualToString:@"App3GTool"],
		@"a leading digit is a legal file name and an illegal identifier");

	// --- EditFile creates, including the directories above it
	NSString *source = [root stringByAppendingPathComponent:@"src/Thing.m"];
	NSString *result = ABLRunToolCall(call(@"EditFile",
		@"{\"path\":\"src/Thing.m\",\"content\":\"one\\ntwo\\nthree\\n\"}"), root);
	require(!ABLOutputFailed(result), @"EditFile should create a file under a new directory");
	require([contents(source) isEqualToString:@"one\ntwo\nthree\n"], @"EditFile writes what it was given");

	// --- PatchFile replaces exactly one occurrence
	result = ABLRunToolCall(call(@"PatchFile",
		@"{\"path\":\"src/Thing.m\",\"old\":\"two\",\"new\":\"2\"}"), root);
	require(!ABLOutputFailed(result), @"a unique match should patch");
	require([contents(source) isEqualToString:@"one\n2\nthree\n"], @"only the match changes");

	// --- and refuses an ambiguous one rather than guessing
	ABLRunToolCall(call(@"EditFile", @"{\"path\":\"src/Thing.m\",\"content\":\"x\\nx\\n\"}"), root);
	result = ABLRunToolCall(call(@"PatchFile",
		@"{\"path\":\"src/Thing.m\",\"old\":\"x\",\"new\":\"y\"}"), root);
	require(ABLOutputFailed(result), @"two matches without replace_all is an error, not a coin toss");
	require([contents(source) isEqualToString:@"x\nx\n"], @"a refused patch changes nothing");
	require([result rangeOfString:@"2 times"].location != NSNotFound,
		@"the model is told how many matches there were");

	result = ABLRunToolCall(call(@"PatchFile",
		@"{\"path\":\"src/Thing.m\",\"old\":\"x\",\"new\":\"y\",\"replace_all\":true}"), root);
	require(!ABLOutputFailed(result), @"replace_all takes both");
	require([contents(source) isEqualToString:@"y\ny\n"], @"replace_all takes both");

	// --- a patch that does not match says so, and says why
	result = ABLRunToolCall(call(@"PatchFile",
		@"{\"path\":\"src/Thing.m\",\"old\":\"nowhere\",\"new\":\"z\"}"), root);
	require(ABLOutputFailed(result), @"text that is not there is an error");
	result = ABLRunToolCall(call(@"PatchFile",
		@"{\"path\":\"src/Missing.m\",\"old\":\"a\",\"new\":\"b\"}"), root);
	require(ABLOutputFailed(result), @"PatchFile does not create files");

	// --- an unknown tool is a message to the model, never a lost round
	result = ABLRunToolCall(call(@"Frobnicate", @"{}"), root);
	require(ABLOutputFailed(result), @"an unknown tool fails");
	require([result rangeOfString:@"Execute"].location != NSNotFound,
		@"and names the tools that do exist");

	// --- exec is still Execute, because reopened transcripts are full of it
	result = ABLRunToolCall(call(@"exec", @"{\"command\":\"echo hello\"}"), root);
	require([result rangeOfString:@"hello"].location != NSNotFound,
		@"the old tool name still runs");
	require([ABLCanonicalToolName(@"exec") isEqualToString:@"Execute"],
		@"and a row reopened from disk is titled by the tool, not by that round's spelling");
	require([ABLCanonicalToolName(@"EditFile") isEqualToString:@"EditFile"],
		@"a name this build knows is its own title");

	// --- what a written file is called back: the path the model asked for
	result = ABLRunToolCall(call(@"EditFile",
		@"{\"path\":\"src/Thing.m\",\"content\":\"one\\n\"}"), root);
	require([result rangeOfString:@"to src/Thing.m"].location != NSNotFound,
		@"a result names the file relative to the project, not by its UUID path");
	require([result rangeOfString:root].location == NSNotFound,
		@"which means the project directory is not in it at all");
	result = ABLRunToolCall(call(@"PatchFile",
		@"{\"path\":\"src/Thing.m\",\"old\":\"nowhere\",\"new\":\"z\"}"), root);
	require([result rangeOfString:root].location == NSNotFound,
		@"and neither is it when the patch fails");

	// --- an Execute with nothing to run says so, rather than asking the shell
	result = ABLRunToolCall(call(@"Execute", @"{}"), root);
	require(ABLOutputFailed(result), @"Execute with no command is an error");
	require([result rangeOfString:@"needs a command"].location != NSNotFound,
		@"and says which argument is missing");

	// --- the digest: the tree, the text, and nothing that is output
	[files createDirectoryAtPath:[root stringByAppendingPathComponent:@"build"]
		withIntermediateDirectories:YES attributes:nil error:NULL];
	[@"object code" writeToFile:[root stringByAppendingPathComponent:@"build/Thing.o"]
		atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	unsigned char nul[] = { 'P', 'N', 'G', 0, 1, 2 };
	[[NSData dataWithBytes:nul length:sizeof(nul)]
		writeToFile:[root stringByAppendingPathComponent:@"Icon.png"] atomically:YES];
	[@"all:\n\techo hi\n" writeToFile:[root stringByAppendingPathComponent:@"Makefile"]
		atomically:YES encoding:NSUTF8StringEncoding error:NULL];

	NSString *digest = ABLRepoDigest(root, 32 * 1024);
	require([digest rangeOfString:@"src/Thing.m"].location != NSNotFound, @"the tree lists source");
	require([digest rangeOfString:@"echo hi"].location != NSNotFound, @"and quotes it");
	require([digest rangeOfString:@"build/Thing.o"].location == NSNotFound,
		@"build output is not part of the project");
	require([digest rangeOfString:@"Icon.png"].location != NSNotFound, @"a binary is still listed");
	require([digest rangeOfString:@"PNG"].location == NSNotFound, @"but never quoted");

	// --- and it stays inside its budget rather than truncating a file
	NSMutableString *big = [NSMutableString string];
	while ([big length] < 4000) {
		[big appendString:@"a line of a file that will not fit in the budget below\n"];
	}
	[big writeToFile:[root stringByAppendingPathComponent:@"Big.txt"]
		atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	NSString *bounded = ABLRepoDigest(root, 2048);
	require([bounded rangeOfString:@"Big.txt"].location != NSNotFound, @"an unquoted file is still listed");
	require([bounded rangeOfString:@"not quoted here"].location != NSNotFound,
		@"and the model is told the listing was cut short");

	[files removeItemAtPath:root error:NULL];
	NSLog(@"PASS: tools, template names and repo digest");
	[pool release];
	return 0;
}
