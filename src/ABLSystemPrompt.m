#import "ABLSystemPrompt.h"
#import "ABLProject.h"
#import "ABLConfig.h"
#import "ABLProjectStore.h"
#import "ABLRepoDigest.h"

#import <UIKit/UIKit.h>

#include <errno.h>
#include <string.h>
#include <sys/utsname.h>

// How much of the project's working tree is quoted into the prompt. It goes
// out with every request in the turn, so this is paid for repeatedly on a
// phone whose uplink is 802.11g at best — big enough for the template and a
// few files of the model's own, small enough not to dominate the round.
static const NSUInteger ABLRepoDigestBudget = 32 * 1024;

// Drop YAML frontmatter so the model sees the skill body, not the harness header.
static NSString *ABLMarkdownBody(NSString *text) {
	if (![text hasPrefix:@"---"]) {
		return text;
	}
	NSRange firstLine = [text rangeOfString:@"\n"];
	if (firstLine.location == NSNotFound) {
		return text;
	}
	NSRange close = [text rangeOfString:@"\n---" options:0
		range:NSMakeRange(firstLine.location, [text length] - firstLine.location)];
	if (close.location == NSNotFound) {
		return text;
	}
	NSRange rest = [text rangeOfString:@"\n" options:0
		range:NSMakeRange(close.location + 1, [text length] - close.location - 1)];
	if (rest.location == NSNotFound) {
		return @"";
	}
	return [text substringFromIndex:rest.location + 1];
}

// Every skills/<name>/SKILL.md in the app bundle, in name order. References
// stay on disk; the prompt names the directory so exec can open them.
static NSString *ABLBundledSkillsPrompt(void) {
	NSString *root = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"skills"];
	NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:NULL];
	if ([names count] == 0) {
		return @"";
	}
	names = [names sortedArrayUsingSelector:@selector(compare:)];
	NSMutableString *out = [NSMutableString string];
	[out appendString:@"\n\nSkills bundled with this app, captured at launch. "
		@"Follow them. Each skill's files stay on disk at the path given; use "
		@"Execute to read a reference when you need it.\n"];
	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;
		}
		NSString *dir = [root stringByAppendingPathComponent:name];
		BOOL isDirectory = NO;
		if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDirectory] || !isDirectory) {
			continue;
		}
		NSString *path = [dir stringByAppendingPathComponent:@"SKILL.md"];
		NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
		if ([text length] == 0) {
			continue;
		}
		[out appendFormat:@"\n### %@\nOn disk: %@\n\n%@\n", name, dir, ABLMarkdownBody(text)];
	}
	return out;
}

// The directories the model owns and the ones it must not touch, by absolute
// path. Without this the model has a working directory it cannot name.
static NSString *ABLProjectPrompt(ABLProject *project) {
	// No project: the scratch conversation behind the chat button. It has
	// the same tools, but nowhere to keep anything.
	if (project == nil) {
		return [NSString stringWithFormat:
			@"\n"
			@"This is a scratch conversation, not a project: nothing in it is "
			@"saved, and it is gone once AirBuild is closed. Tool calls run in "
			@"a temporary directory, %@, which starts empty and is not kept. "
			@"This is the place for questions. To build an app, the user starts "
			@"a project from the list instead.\n"
			@"\n"
			@"Build environment, installed by AirBuild's Environment setup:\n"
			@"  %@/toolchain/sdks/iPhoneOS4.1.sdk   SDK headers ($SDKROOT)\n"
			@"  Run `. /etc/profile.d/airbuild.sh` first if $SDKROOT is unset.\n",
			[ABLProjectStore scratchDirectory], ABLDefaultRoot];
	}
	NSString *digest = ABLRepoDigest([project workingDirectory], ABLRepoDigestBudget);
	NSString *tree = [digest length] > 0
		? [NSString stringWithFormat:
			@"\nThe project's working tree as it was when this project was opened. "
			@"You do not need to list or cat these files to find out what is there.\n"
			@"\n%@", digest]
		: @"\nThe project's working tree is empty.\n";

	return [NSString stringWithFormat:
		@"\n"
		@"Project: %@\n"
		@"Project id: %@\n"
		@"Every tool call works in the project directory below: relative paths "
		@"are resolved against it and Execute starts there.\n"
		@"\n"
		@"%@/\n"
		@"  project/          The software you are building. Your working directory. Yours.\n"
		@"  manifest.plist    Project metadata. AirBuild owns it. Do not edit.\n"
		@"  conversation/     This transcript, round_<n>.plist. AirBuild owns it. Do not edit.\n"
		@"  photos/           Photos the user attached, as JPEG files. The message names\n"
		@"                    the file; copy it into project/ if the app needs it.\n"
		@"\n"
		@"The project was started from the bundled single-view app template, so "
		@"it already has a Makefile, an Info.plist and a src/ that compile as "
		@"they stand. `CheckBuild` builds it; `CheckBuild` with target `install` "
		@"puts it on the springboard; `make run` opens it.\n"
		@"\n"
		@"Build environment, installed by AirBuild's Environment setup\n"
		@"(Settings > Environment; if a tool below is missing, say so and stop\n"
		@"rather than improvising a different toolchain):\n"
		@"  %@/toolchain/sdks/iPhoneOS4.1.sdk   SDK headers ($SDKROOT)\n"
		@"  Run `. /etc/profile.d/airbuild.sh` first if $SDKROOT is unset.\n"
		@"  Apps are plain .m compiled with gcc: there is no Theos and no\n"
		@"  Logos here, because Logos is perl and no perl runs on armv6.\n"
		@"%@",
		[project name], [project uuid], [project directory],
		ABLDefaultRoot, tree];
}

NSString *ABLSystemPromptForProject(ABLProject *project) {
	struct utsname u;
	NSString *kernel;
	if (uname(&u) == 0) {
		kernel = [NSString stringWithFormat:@"%s %s %s %s %s",
			u.sysname, u.nodename, u.release, u.version, u.machine];
	} else {
		kernel = [NSString stringWithFormat:@"(unavailable: %s)", strerror(errno)];
	}

	UIDevice *device = [UIDevice currentDevice];
	NSString *deviceLine = [NSString stringWithFormat:@"%@ · %@ · %@ %@",
		[device name], [device model], [device systemName], [device systemVersion]];

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	[formatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
	[formatter setDateFormat:@"EEEE, d MMMM yyyy, HH:mm:ss zzz"];
	NSString *when = [formatter stringFromDate:[NSDate date]];
	[formatter release];

	return [NSString stringWithFormat:
		@"You are the assistant inside AirBuild, a compact chat client that runs "
		@"on vintage hardware: iPhone 3G (armv6) and iPhone 3GS (armv7), iOS 4 "
		@"custom firmware. This is a real phone, not a simulator — about 128 MB "
		@"of RAM, a slow ARM CPU, a tiny screen, and CFNetwork TLS 1.2 via "
		@"TLSFix. Keep replies short.\n"
		@"\n"
		@"Your tools:\n"
		@"  Execute     a shell command, as root, in the project directory\n"
		@"  EditFile    write a file whole, creating it if it is not there\n"
		@"  PatchFile   replace an exact stretch of text in a file\n"
		@"  CheckBuild  make, with the toolchain environment already sourced\n"
		@"\n"
		@"Write files with EditFile and PatchFile, never by echoing a heredoc "
		@"through Execute: a turn is sixteen tool rounds and a mis-escaped "
		@"heredoc costs two of them. Build with CheckBuild after every change. "
		@"AirBuild itself runs as an ordinary app; the commands you run are "
		@"handed to a small setuid helper, so they are root while the app is "
		@"not.\n"
		@"\n"
		@"Think briefly, then edit. Thinking is for deciding the shape of the "
		@"change and the order of the files, not for writing the whole program "
		@"in your head before the first tool call: one thought that tries to "
		@"settle every file at once is long, wrong by the time the build runs, "
		@"and leaves the person watching a blank screen. Decide the next file, "
		@"write it with EditFile or PatchFile, build, read what the compiler "
		@"said, and think again about the next one. Many small rounds of "
		@"think-edit-build beat one big round of thinking; the build is the "
		@"check, not your foresight.\n"
		@"\n"
		@"This project was opened at %@. That clock, the kernel identity and the "
		@"device line below were captured then and will not change while it "
		@"stays open. Treat them as the environment for the whole session.\n"
		@"\n"
		@"Local time: %@\n"
		@"Kernel (uname):\n%@\n"
		@"Device:\n%@\n"
		@"%@%@",
		when, when, kernel, deviceLine,
		ABLProjectPrompt(project), ABLBundledSkillsPrompt()];
}
