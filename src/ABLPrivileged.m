#import "ABLPrivileged.h"
#import "ABLConfig.h"
#import "ABLShell.h"
#import "ABLStash.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

NSString *ABLHelperPath(void) {
	NSString *path = [[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:@"airbuildhelper"];
	return [[NSFileManager defaultManager] isExecutableFileAtPath:path] ? path : nil;
}

BOOL ABLHelperIsAvailable(void) {
	// Already root — the host tests run this way, and so does anything started
	// from an SSH session. There is nothing for the helper to add.
	return geteuid() != 0 && ABLHelperPath() != nil;
}

// One helper invocation as a /bin/sh word list, so ABLRunCommand can run it
// with the bounds and the exit-status reporting it already implements.
static NSString *ABLHelperCommand(NSArray *arguments) {
	NSString *helper = ABLHelperPath();
	if (helper == nil) {
		return nil;
	}
	NSMutableString *command = [NSMutableString stringWithString:ABLShellQuote(helper)];
	for (NSString *argument in arguments) {
		[command appendFormat:@" %@", ABLShellQuote(argument)];
	}
	return command;
}

NSString *ABLRunPrivilegedCommand(NSString *command, NSString *workingDirectory) {
	if (!ABLHelperIsAvailable()) {
		return ABLRunCommand(command, workingDirectory);
	}
	// The working directory is the helper's business, not the shell's: it
	// chdir()s before it drops into /bin/sh, so a command that starts with a
	// `cd` of its own still behaves the way the model expects.
	NSString *line = ABLHelperCommand([NSArray arrayWithObjects:@"run",
		[workingDirectory length] > 0 ? workingDirectory : @"", command, nil]);
	return ABLRunCommand(line, nil);
}

// A helper verb that reports by exit status and prints its reasons. The output
// goes into `log` whether it worked or not: a refusal is the interesting case.
static BOOL ABLRunHelperVerb(NSArray *arguments, NSMutableString *log) {
	NSString *line = ABLHelperCommand(arguments);
	if (line == nil) {
		return NO;
	}
	NSString *output = ABLRunCommand(line, nil);
	if (log != nil && [output length] > 0 && ![output isEqualToString:@"(no output)"]) {
		[log appendString:output];
		if (![output hasSuffix:@"\n"]) {
			[log appendString:@"\n"];
		}
	}
	return !ABLOutputFailed(output);
}

BOOL ABLPrepareRoot(NSString *root, NSMutableString *log) {
	if (!ABLHelperIsAvailable()) {
		// Unprivileged, this is an ordinary mkdir -p, and on the host tests
		// that is all it ever needed to be.
		return [[NSFileManager defaultManager]
			createDirectoryAtPath:[root stringByAppendingPathComponent:@"projects"]
			withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	return ABLRunHelperVerb([NSArray arrayWithObjects:@"prepare", root, nil], log);
}

BOOL ABLPrivilegedWriteFile(NSString *path, NSData *data, NSString **error) {
	NSFileManager *files = [NSFileManager defaultManager];
	if (!ABLHelperIsAvailable()) {
		NSString *parent = [path stringByDeletingLastPathComponent];
		[files createDirectoryAtPath:parent withIntermediateDirectories:YES
			attributes:nil error:NULL];
		if ([data writeToFile:path atomically:NO]) {
			return YES;
		}
		if (error != NULL) {
			*error = [NSString stringWithFormat:@"Could not write %@.", path];
		}
		return NO;
	}
	// The contents reach the helper as a file rather than as an argument: a
	// source file is tens of kilobytes and argv is not.
	//
	// Not /tmp, and not a name of our own choosing. /tmp is world-writable, so
	// a root process would be reading an input at a path anybody could have
	// got to first; ABLPrepareRoot makes this directory 0700 and ours, inside
	// a root-owned parent. mkstemp, because a name built from the pid is not
	// unique within one: a tool round abandoned by Stop keeps running into a
	// turn nobody is listening to, and the next one must not be able to write
	// the file it is about to read.
	char staged[PATH_MAX];
	NSString *template = [NSString stringWithFormat:@"%@/staging/write-XXXXXX", ABLDefaultRoot];
	strlcpy(staged, [template fileSystemRepresentation], sizeof(staged));
	int fd = mkstemp(staged);
	if (fd < 0) {
		if (error != NULL) {
			*error = [NSString stringWithFormat:@"Could not stage the new contents of %@ "
				@"in %@/staging.", path, ABLDefaultRoot];
		}
		return NO;
	}
	const char *bytes = [data bytes];
	NSUInteger remaining = [data length];
	BOOL staging_ok = YES;
	while (remaining > 0) {
		ssize_t wrote = write(fd, bytes, remaining);
		if (wrote <= 0) {
			staging_ok = NO;
			break;
		}
		bytes += wrote;
		remaining -= (NSUInteger)wrote;
	}
	close(fd);
	NSString *staging = [files stringWithFileSystemRepresentation:staged length:strlen(staged)];
	if (!staging_ok) {
		[files removeItemAtPath:staging error:NULL];
		if (error != NULL) {
			*error = [NSString stringWithFormat:@"Could not stage the new contents of %@.", path];
		}
		return NO;
	}
	NSMutableString *log = [NSMutableString string];
	BOOL ok = ABLRunHelperVerb([NSArray arrayWithObjects:@"install", staging, path, nil], log);
	[files removeItemAtPath:staging error:NULL];
	if (!ok && error != NULL) {
		*error = [log length] > 0 ? [log stringByTrimmingCharactersInSet:
			[NSCharacterSet whitespaceAndNewlineCharacterSet]]
			: [NSString stringWithFormat:@"Could not write %@.", path];
	}
	return ok;
}

BOOL ABLPrivilegedStash(NSString *path, NSMutableString *log) {
	if (!ABLHelperIsAvailable()) {
		return [ABLStash stashPath:path log:log];
	}
	return ABLRunHelperVerb([NSArray arrayWithObjects:@"stash", path, nil], log);
}

BOOL ABLPrivilegedUnstash(NSString *path, NSMutableString *log) {
	if (!ABLHelperIsAvailable()) {
		return [ABLStash unstashPath:path log:log];
	}
	return ABLRunHelperVerb([NSArray arrayWithObjects:@"unstash", path, nil], log);
}
