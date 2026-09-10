#import "ABLTools.h"
#import "ABLJSONParser.h"
#import "ABLPrivileged.h"
#import "ABLShell.h"

const NSUInteger ABLCheckBuildOutputLimit = 8 * 1024;

// Model output, so every one of these is a message the model can act on: it
// is the only participant in a position to fix a bad call, and an exception or
// a silent empty result costs it the round without telling it why.
static NSString *ABLToolError(NSString *format, ...) {
	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
	va_end(arguments);
	return [message stringByAppendingString:@"\n(exit 1)"];
}

// Tool-call arguments always arrive as the JSON string ABLChatClient froze
// them into. A model that sent something else gets nil and an error naming
// what it should have sent.
static NSDictionary *ABLToolArguments(NSDictionary *call) {
	NSString *arguments = [call objectForKey:@"arguments"];
	if ([arguments length] == 0) {
		return [NSDictionary dictionary];
	}
	id object = [ABLJSONParser objectWithData:[arguments dataUsingEncoding:NSUTF8StringEncoding]
		errorDescription:NULL];
	return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSString *ABLStringArgument(NSDictionary *arguments, NSString *key) {
	id value = [arguments objectForKey:key];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

// The name the app dispatches on. `exec` is what the tool was called before
// this build, and a conversation reopened from disk still has rounds full of
// it — those calls are replayed to the model as history, and a model that
// copies the older shape must not be told it does not exist.
NSString *ABLCanonicalToolName(NSString *name) {
	if ([name isEqualToString:@"exec"] || [name isEqualToString:@"shell"]) {
		return @"Execute";
	}
	return [name length] > 0 ? name : @"Execute";
}

static NSString *ABLToolName(NSDictionary *call) {
	return ABLCanonicalToolName([call objectForKey:@"name"]);
}

// The command out of an Execute call. A model that sent a bare command string
// instead of an arguments object gets it run as it stands; one that sent an
// object with no command in it gets nil, and is told so rather than watching
// /bin/sh report that `{}` is not a command.
static NSString *ABLExecuteCommand(NSDictionary *call) {
	NSDictionary *arguments = ABLToolArguments(call);
	NSString *command = ABLStringArgument(arguments, @"command");
	if (command != nil) {
		return command;
	}
	return arguments != nil ? nil : [call objectForKey:@"arguments"];
}

// Relative paths belong to the project. An absolute one is taken at its word:
// the model is expected to read /etc/profile.d/airbuild.sh and the SDK, and
// refusing to would only send it back through Execute for the same file.
static NSString *ABLResolvePath(NSString *path, NSString *workingDirectory) {
	if ([path hasPrefix:@"/"]) {
		return [path stringByStandardizingPath];
	}
	return [[workingDirectory stringByAppendingPathComponent:path] stringByStandardizingPath];
}

// How a path is spelled back into the transcript and to the model: the way it
// was asked for. The project directory is a UUID under /var/airbuild/projects,
// so a resolved path is sixty characters of prefix nobody reads, on a row
// 320 points wide — and the model addressed the file as `src/Thing.m`, so
// that is the name it recognises in the answer. An absolute path is left
// alone: it is outside the project, and the whole of it is what identifies it.
static NSString *ABLDisplayPath(NSString *requested, NSString *resolved) {
	return [requested hasPrefix:@"/"] ? resolved : requested;
}

// Writing goes through the helper, for the same reason reading does not: the
// model builds as root, so a directory it made with Execute belongs to root
// and this process — which is not root any more — cannot write into it. The
// content reaches the helper as a file rather than as an argument, because a
// source file is tens of kilobytes and argv is not.
static NSString *ABLWriteFile(NSString *path, NSString *content, NSString *shown) {
	NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
	if (data == nil) {
		return ABLToolError(@"%@ could not be encoded as UTF-8.", shown);
	}
	NSString *error = nil;
	if (!ABLPrivilegedWriteFile(path, data, &error)) {
		return ABLToolError(@"%@", error);
	}
	return [NSString stringWithFormat:@"Wrote %lu bytes to %@.",
		(unsigned long)[data length], shown];
}

static NSString *ABLRunEditFile(NSDictionary *arguments, NSString *workingDirectory) {
	NSString *path = ABLStringArgument(arguments, @"path");
	NSString *content = ABLStringArgument(arguments, @"content");
	if ([path length] == 0) {
		return ABLToolError(@"EditFile needs a path.");
	}
	if (content == nil) {
		return ABLToolError(@"EditFile needs content. To empty a file, pass an empty string.");
	}
	NSString *resolved = ABLResolvePath(path, workingDirectory);
	return ABLWriteFile(resolved, content, ABLDisplayPath(path, resolved));
}

static NSString *ABLRunPatchFile(NSDictionary *arguments, NSString *workingDirectory) {
	NSString *path = ABLStringArgument(arguments, @"path");
	NSString *old = ABLStringArgument(arguments, @"old");
	NSString *replacement = ABLStringArgument(arguments, @"new");
	if ([path length] == 0 || old == nil || replacement == nil) {
		return ABLToolError(@"PatchFile needs path, old and new.");
	}
	if ([old length] == 0) {
		return ABLToolError(@"PatchFile's old text cannot be empty. Use EditFile to write a whole file.");
	}
	NSString *resolved = ABLResolvePath(path, workingDirectory);
	NSString *shown = ABLDisplayPath(path, resolved);
	NSString *text = [NSString stringWithContentsOfFile:resolved encoding:NSUTF8StringEncoding error:NULL];
	if (text == nil) {
		return ABLToolError(@"%@ does not exist or is not UTF-8 text. Use EditFile to create it.", shown);
	}

	// Counted before anything is replaced, so "appears twice" is something the
	// model is told rather than something it discovers in the next build.
	NSUInteger occurrences = 0;
	NSRange search = NSMakeRange(0, [text length]);
	while (search.length > 0) {
		NSRange found = [text rangeOfString:old options:NSLiteralSearch range:search];
		if (found.location == NSNotFound) {
			break;
		}
		occurrences++;
		search = NSMakeRange(NSMaxRange(found), [text length] - NSMaxRange(found));
	}
	if (occurrences == 0) {
		return ABLToolError(@"That text is not in %@. Read the file and match it exactly, "
			@"whitespace included.", shown);
	}
	BOOL all = [[arguments objectForKey:@"replace_all"] boolValue];
	if (occurrences > 1 && !all) {
		return ABLToolError(@"That text appears %lu times in %@. Include enough surrounding "
			@"lines to make it unique, or pass replace_all.", (unsigned long)occurrences, shown);
	}

	NSString *patched;
	if (all) {
		patched = [text stringByReplacingOccurrencesOfString:old withString:replacement
			options:NSLiteralSearch range:NSMakeRange(0, [text length])];
	} else {
		NSRange found = [text rangeOfString:old options:NSLiteralSearch];
		patched = [text stringByReplacingCharactersInRange:found withString:replacement];
	}
	NSString *result = ABLWriteFile(resolved, patched, shown);
	if (ABLOutputFailed(result)) {
		return result;
	}
	return [NSString stringWithFormat:@"Replaced %lu occurrence%@ in %@.",
		(unsigned long)(all ? occurrences : 1), (all && occurrences != 1) ? @"s" : @"", shown];
}

static NSString *ABLRunCheckBuild(NSDictionary *arguments, NSString *workingDirectory) {
	NSString *target = ABLStringArgument(arguments, @"target");
	// The profile is sourced here rather than left to the model: exec does not
	// run a login shell, and a build without $IOS_CFLAGS fails in a way that
	// reads as the code being wrong.
	NSString *command = [NSString stringWithFormat:
		@". /etc/profile.d/airbuild.sh >/dev/null 2>&1; make -j1 %@",
		[target length] > 0 ? ABLShellQuote(target) : @""];
	NSString *output = ABLRunPrivilegedCommand(command, workingDirectory);
	if ([output length] <= ABLCheckBuildOutputLimit) {
		return output;
	}
	// The tail, because that is where the first error and the exit status are.
	return [NSString stringWithFormat:@"(the first %lu bytes of this build are not shown)\n%@",
		(unsigned long)([output length] - ABLCheckBuildOutputLimit),
		[output substringFromIndex:[output length] - ABLCheckBuildOutputLimit]];
}

NSString *ABLRunToolCall(NSDictionary *call, NSString *workingDirectory) {
	NSString *name = ABLToolName(call);
	if ([name isEqualToString:@"Execute"]) {
		NSString *command = ABLExecuteCommand(call);
		if ([command length] == 0) {
			return ABLToolError(@"Execute needs a command.");
		}
		return ABLRunPrivilegedCommand(command, workingDirectory);
	}
	NSDictionary *arguments = ABLToolArguments(call);
	if (arguments == nil) {
		return ABLToolError(@"%@'s arguments were not a JSON object.", name);
	}
	if ([name isEqualToString:@"EditFile"]) {
		return ABLRunEditFile(arguments, workingDirectory);
	}
	if ([name isEqualToString:@"PatchFile"]) {
		return ABLRunPatchFile(arguments, workingDirectory);
	}
	if ([name isEqualToString:@"CheckBuild"]) {
		return ABLRunCheckBuild(arguments, workingDirectory);
	}
	return ABLToolError(@"There is no tool called %@. The tools here are Execute, EditFile, "
		@"PatchFile and CheckBuild.", name);
}
