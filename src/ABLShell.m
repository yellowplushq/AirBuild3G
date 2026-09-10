#import "ABLShell.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

const NSUInteger ABLShellOutputLimit = 64 * 1024;

NSString *ABLShellQuote(NSString *text) {
	// Single quotes take everything literally except a single quote, which is
	// closed, escaped and reopened. Nothing else needs handling.
	NSString *escaped = [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
	return [NSString stringWithFormat:@"'%@'", escaped];
}

BOOL ABLOutputFailed(NSString *output) {
	return [output rangeOfString:@"\n(exit "].location != NSNotFound
		|| [output rangeOfString:@"\n(killed by signal "].location != NSNotFound;
}

NSString *ABLRunCommand(NSString *command, NSString *workingDirectory) {
	if ([command length] == 0) {
		return @"(empty command)";
	}
	// The braces put the redirection around the whole script rather than the
	// last command in it, and the newlines mean a trailing comment or an
	// unterminated backslash in the model's command cannot swallow the closer.
	NSMutableString *script = [NSMutableString stringWithString:@"{ "];
	if ([workingDirectory length] > 0) {
		[script appendFormat:@"cd %@ || exit 1\n", ABLShellQuote(workingDirectory)];
	}
	[script appendFormat:@"%@\n} 2>&1", command];

	FILE *pipe = popen([script UTF8String], "r");
	if (pipe == NULL) {
		// The (exit N) suffix is how both callers detect failure, so a shell
		// that never started has to carry one too. Without it the bootstrap
		// counted a step that ran nothing as a success and went on to write
		// the "environment is ready" stamp.
		return [NSString stringWithFormat:@"exec failed: %s\n(exit 127)", strerror(errno)];
	}
	NSMutableData *data = [NSMutableData data];
	char buffer[4096];
	size_t n;
	BOOL truncated = NO;
	while ((n = fread(buffer, 1, sizeof(buffer), pipe)) > 0) {
		NSUInteger room = [data length] < ABLShellOutputLimit ? ABLShellOutputLimit - [data length] : 0;
		if (room == 0) {
			truncated = YES;
			break;
		}
		size_t chunk = n < room ? n : room;
		[data appendBytes:buffer length:chunk];
		if (chunk < n) {
			truncated = YES;
			break;
		}
	}
	int status = pclose(pipe);

	// The limit is in bytes, so the cut can land inside a multi-byte sequence.
	// -initWithData:encoding: then fails for the *whole* buffer rather than
	// the tail, and 64 KB of perfectly good output came back as Latin-1
	// mojibake for the model to reason about. Back the end off to a character
	// boundary instead: a UTF-8 continuation byte is 10xxxxxx, and a sequence
	// is at most four bytes long.
	if (truncated) {
		const unsigned char *bytes = (const unsigned char *)[data bytes];
		NSUInteger length = [data length];
		NSUInteger trim = 0;
		while (length > 0 && trim < 4 && (bytes[length - 1] & 0xC0) == 0x80) {
			length--;
			trim++;
		}
		if (length > 0 && trim > 0 && (bytes[length - 1] & 0x80) != 0) {
			length--;   // the lead byte whose continuations were cut off
		}
		[data setLength:length];
	}

	NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	if (text == nil) {
		text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
	}
	if ([text length] == 0) {
		text = @"(no output)";
	}
	if (truncated) {
		text = [text stringByAppendingString:@"\n(truncated)"];
	}
	if (status != 0) {
		// A signalled child has no exit status. Reporting the raw wait value
		// made a SIGPIPE kill — which is how a truncated command usually ends
		// — read as "(exit 13)", indistinguishable from a real exit code.
		if (WIFSIGNALED(status)) {
			text = [text stringByAppendingFormat:@"\n(killed by signal %d)", WTERMSIG(status)];
		} else {
			text = [text stringByAppendingFormat:@"\n(exit %d)", WIFEXITED(status) ? WEXITSTATUS(status) : status];
		}
	}
	return text;
}
