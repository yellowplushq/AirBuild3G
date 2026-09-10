// airbuildhelper — the only part of AirBuild that runs as root.
//
// Installed root:wheel mode 4755 beside the app. It raises its own privilege
// on the first two lines of main() and does exactly one thing before exiting,
// so the window in which anything here is uid 0 is one command long.
//
// The app is an ordinary mobile app again because of this: UIKit, the photo
// picker, an HTTPS client talking to a remote inference endpoint and 60 KB of
// model-authored JSON all used to run in the same uid-0 process, for the sake
// of the handful of operations below.
//
// Verbs:
//   run <cwd> <command>   /bin/sh -c, as root, in <cwd> ("" for this one)
//   install <src> <dest>  put a staged file in place, making its directories
//   prepare <root>        /var/airbuild, with a projects directory the app owns
//   stash <path>          move a directory off / and leave a symlink
//   unstash <path>        put it back
//
// `run` is a root shell by design: it is what the model's Execute tool is, and
// what dpkg needs. Any process running as mobile can therefore reach root
// through this binary — as it could through the 4755 app binary this replaces,
// on a phone whose owner has an SSH root login anyway. That is the one thing
// here that cannot be narrowed without removing the feature, so everything
// else is: `prepare` will only prepare one path, `install` is a copy and
// nothing else, and no verb takes a shell fragment.

#import <Foundation/Foundation.h>
#import "ABLConfig.h"
#import "ABLStash.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void ABLFail(NSString *message) {
	fprintf(stderr, "%s\n", [message UTF8String]);
	exit(1);
}

// Hand `path` to the app's user, leaving its mode alone. Only ever used on a
// project made back when the app was root, whose transcript it can no longer
// write.
static BOOL ABLAdopt(NSString *path, uid_t uid, gid_t gid) {
	const char *c = [path fileSystemRepresentation];
	struct stat info;
	if (lstat(c, &info) != 0) {
		return NO;
	}
	return info.st_uid == uid || lchown(c, uid, gid) == 0;
}

// The whole tree under `path`, which is only ever used on a project's
// metadata: the manifest and the conversation directory. A project's own
// working tree is left alone — the model builds in it as root, and rewriting
// the ownership of a build directory at every launch is minutes of a 3G.
static void ABLAdoptTree(NSString *path, uid_t uid, gid_t gid) {
	NSFileManager *files = [NSFileManager defaultManager];
	if (![files fileExistsAtPath:path]) {
		return;
	}
	ABLAdopt(path, uid, gid);
	for (NSString *relative in [files subpathsAtPath:path]) {
		ABLAdopt([path stringByAppendingPathComponent:relative], uid, gid);
	}
}

// Make sure `path` exists, and say so usefully when it cannot.
static void ABLMakeDirectory(NSString *path, mode_t mode) {
	NSFileManager *files = [NSFileManager defaultManager];
	if (![files fileExistsAtPath:path]
			&& ![files createDirectoryAtPath:path withIntermediateDirectories:YES
				attributes:nil error:NULL]) {
		ABLFail([NSString stringWithFormat:@"cannot create %@: %s", path, strerror(errno)]);
	}
	chmod([path fileSystemRepresentation], mode);
}

// The caller names the root, and this is where that stops being taken on
// trust. A setuid binary must not chown a directory chosen by whoever ran it:
// `prepare /` would hand the caller the root of the filesystem.
static BOOL ABLIsPreparableRoot(NSString *root) {
	return [root isEqualToString:ABLDefaultRoot]
		|| [root isEqualToString:[@"/private" stringByAppendingString:ABLDefaultRoot]];
}

static int ABLPrepare(NSString *root, uid_t uid, gid_t gid) {
	NSFileManager *files = [NSFileManager defaultManager];
	if (!ABLIsPreparableRoot(root)) {
		ABLFail([NSString stringWithFormat:@"refusing to prepare %@: only %@ is ours",
			root, ABLDefaultRoot]);
	}

	// The root itself stays root's, and is put back if something made it the
	// app's. It holds bootstrap/ — the payload archives the installer hands to
	// dpkg as root — and toolchain/. A root-owned directory inside a
	// caller-writable one is not protected: the *entry* can be renamed and
	// replaced, so a directory the app can write is a directory in which the
	// app can swap out what a root installer is about to read.
	ABLMakeDirectory(root, 0755);
	if (lchown([root fileSystemRepresentation], 0, 0) != 0) {
		ABLFail([NSString stringWithFormat:@"cannot take %@ back: %s", root, strerror(errno)]);
	}

	// These two are the app's, and are the only reason this verb exists:
	// projects and transcripts are then written with no privilege at all, and
	// staging is where EditFile puts a file for `install` to pick up — 0700 so
	// that what a root process is about to read is not in a directory anyone
	// else can write.
	NSString *projects = [root stringByAppendingPathComponent:@"projects"];
	NSString *staging = [root stringByAppendingPathComponent:@"staging"];
	ABLMakeDirectory(projects, 0755);
	ABLMakeDirectory(staging, 0700);
	for (NSString *path in [NSArray arrayWithObjects:projects, staging, nil]) {
		if (lchown([path fileSystemRepresentation], uid, gid) != 0) {
			ABLFail([NSString stringWithFormat:@"cannot take ownership of %@: %s",
				path, strerror(errno)]);
		}
	}

	// Projects made while the app was still running as root belong to root,
	// and it can no longer write their transcripts. Converting one costs a
	// handful of chowns and happens once; after that every project already
	// passes the owner check and this loop is a stat per project.
	for (NSString *name in [files contentsOfDirectoryAtPath:projects error:NULL]) {
		if ([name hasPrefix:@"."]) {
			continue;
		}
		NSString *directory = [projects stringByAppendingPathComponent:name];
		struct stat info;
		if (lstat([directory fileSystemRepresentation], &info) != 0 || info.st_uid == uid) {
			continue;
		}
		ABLAdopt(directory, uid, gid);
		ABLAdopt([directory stringByAppendingPathComponent:@"manifest.plist"], uid, gid);
		ABLAdoptTree([directory stringByAppendingPathComponent:@"conversation"], uid, gid);
		printf("adopted %s\n", [name UTF8String]);
	}
	return 0;
}

// EditFile and PatchFile hand their new contents over as a staged file rather
// than as an argument — a source file is tens of kilobytes and argv is not —
// and this is what puts it where it belongs. As root, because the model builds
// as root and the directory it is writing into may well be root's.
static int ABLInstall(NSString *source, NSString *destination) {
	NSData *data = [NSData dataWithContentsOfFile:source];
	if (data == nil) {
		ABLFail([NSString stringWithFormat:@"Could not read %@: %s.", source, strerror(errno)]);
	}
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *parent = [destination stringByDeletingLastPathComponent];
	if ([parent length] > 0 && ![files fileExistsAtPath:parent]
			&& ![files createDirectoryAtPath:parent withIntermediateDirectories:YES
				attributes:nil error:NULL]) {
		ABLFail([NSString stringWithFormat:@"Could not create %@: %s.", parent, strerror(errno)]);
	}
	// Written in place rather than swapped in: a file the model is editing may
	// be a symlink into the SDK or a target something else already holds open,
	// and replacing the directory entry would quietly break both.
	if (![data writeToFile:destination atomically:NO]) {
		ABLFail([NSString stringWithFormat:@"Could not write %@: %s.", destination, strerror(errno)]);
	}
	return 0;
}

static int ABLRun(NSString *workingDirectory, NSString *command) {
	if ([workingDirectory length] > 0
			&& chdir([workingDirectory fileSystemRepresentation]) != 0) {
		ABLFail([NSString stringWithFormat:@"Could not use %@ as the working directory: %s.",
			workingDirectory, strerror(errno)]);
	}
	// execv, not popen: the caller already has a pipe around this process, and
	// handing the shell our own stdout keeps the command's exit status as the
	// helper's own — which is the only thing that tells the app it failed.
	char *const argv[] = { (char *)"sh", (char *)"-c", (char *)[command UTF8String], NULL };
	execv("/bin/sh", argv);
	ABLFail([NSString stringWithFormat:@"Could not start the command: %s.", strerror(errno)]);
	return 127;
}

int main(int argc, char *argv[]) {
	// The s bit is what makes this work: exec'd by a process running as
	// mobile, this binary starts with euid 0 and these two lines make it the
	// real uid too, so everything below — including /bin/sh — is root. setgid
	// first: after setuid(0) there is no privilege left to change the group
	// with.
	//
	// Checked, because a helper that has lost its s bit — restored from a
	// backup, copied rather than installed, chmod'd by something else — runs
	// as mobile and fails every command with a permission error that reads
	// like the command being wrong.
	uid_t caller = getuid();
	gid_t callerGroup = getgid();
	if ((setgid(0) != 0 || setuid(0) != 0) && caller != 0) {
		fprintf(stderr, "AirBuild cannot run commands as root. "
			"Reinstall AirBuild and try again. (%s)\n", strerror(errno));
		return 1;
	}

	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *verb = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
	NSString *first = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"";
	NSString *second = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
	int status = 2;

	if ([verb isEqualToString:@"run"] && argc > 3) {
		status = ABLRun(first, second);
	} else if ([verb isEqualToString:@"install"] && argc > 3) {
		status = ABLInstall(first, second);
	} else if ([verb isEqualToString:@"prepare"] && argc > 2) {
		status = ABLPrepare(first, caller, callerGroup);
	} else if (([verb isEqualToString:@"stash"] || [verb isEqualToString:@"unstash"])
			&& argc > 2) {
		NSMutableString *log = [NSMutableString string];
		BOOL ok = [verb isEqualToString:@"stash"]
			? [ABLStash stashPath:first log:log]
			: [ABLStash unstashPath:first log:log];
		fputs([log UTF8String], stdout);
		status = ok ? 0 : 1;
	} else {
		fprintf(stderr, "usage: airbuildhelper run <cwd> <command> | "
			"install <source> <destination> | prepare <root> | "
			"stash <path> | unstash <path>\n");
	}
	[pool release];
	return status;
}
