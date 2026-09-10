#import <Foundation/Foundation.h>

// The four tools the model is given, and what each one does when it is called.
//
// Editing used to be Execute's problem: every change to a file was a shell
// command the model had to write, which on this phone means a heredoc it has
// to escape correctly on the first try, inside a 16-round turn. EditFile and
// PatchFile make the two things it actually wants — write this file, change
// this line — one call each, and CheckBuild makes the third one a call rather
// than a remembered incantation.

// The `tools` array of the request, verbatim. A macro rather than a symbol so
// ABLChatClient can carry the wire format without linking the implementation
// of the tools, which pulls in the whole privileged path.
#define ABLToolsJSONLiteral \
	@"[" \
	@"{\"type\":\"function\",\"function\":{\"name\":\"Execute\"," \
	@"\"description\":\"Run a shell command on this iPhone, as root, in the project directory. " \
	@"Returns combined stdout and stderr, capped at 64 KB. Use it to inspect the device, " \
	@"install packages, run git, or launch what you built.\"," \
	@"\"parameters\":{\"type\":\"object\",\"properties\":{" \
	@"\"command\":{\"type\":\"string\",\"description\":\"The shell command to run.\"}}," \
	@"\"required\":[\"command\"]}}}," \
	@"{\"type\":\"function\",\"function\":{\"name\":\"EditFile\"," \
	@"\"description\":\"Write a file whole. Creates it, and any missing directories, if it " \
	@"does not exist. Use this to create a file or replace one completely; use PatchFile to " \
	@"change part of one. Never write a file by echoing it through Execute.\"," \
	@"\"parameters\":{\"type\":\"object\",\"properties\":{" \
	@"\"path\":{\"type\":\"string\",\"description\":\"Path to the file. Relative paths are " \
	@"resolved against the project directory.\"}," \
	@"\"content\":{\"type\":\"string\",\"description\":\"The complete new contents of the file.\"}}," \
	@"\"required\":[\"path\",\"content\"]}}}," \
	@"{\"type\":\"function\",\"function\":{\"name\":\"PatchFile\"," \
	@"\"description\":\"Replace an exact stretch of text in a file that already exists. The " \
	@"old text must match byte for byte, indentation included, and must appear exactly once " \
	@"unless replace_all is true.\"," \
	@"\"parameters\":{\"type\":\"object\",\"properties\":{" \
	@"\"path\":{\"type\":\"string\",\"description\":\"Path to the file. Relative paths are " \
	@"resolved against the project directory.\"}," \
	@"\"old\":{\"type\":\"string\",\"description\":\"The exact text to replace.\"}," \
	@"\"new\":{\"type\":\"string\",\"description\":\"The text to put in its place.\"}," \
	@"\"replace_all\":{\"type\":\"boolean\",\"description\":\"Replace every occurrence instead " \
	@"of requiring exactly one. Default false.\"}}," \
	@"\"required\":[\"path\",\"old\",\"new\"]}}}," \
	@"{\"type\":\"function\",\"function\":{\"name\":\"CheckBuild\"," \
	@"\"description\":\"Build the project: runs make in the project directory with " \
	@"/etc/profile.d/airbuild.sh already sourced, and returns the tail of the output. Run it " \
	@"after every change you make to source. Pass target to run something other than the " \
	@"default, for example install.\"," \
	@"\"parameters\":{\"type\":\"object\",\"properties\":{" \
	@"\"target\":{\"type\":\"string\",\"description\":\"The make target. Default: the first one.\"}}," \
	@"\"required\":[]}}}" \
	@"]"

// How much of a build CheckBuild hands back. A failing compile puts the error
// at the end, and a succeeding one has nothing to say — 64 KB of gcc chatter
// costs the turn more than it tells anyone.
extern const NSUInteger ABLCheckBuildOutputLimit;

// Runs one tool call and returns the text the model gets back. Blocks for as
// long as the tool takes; never call it from the main thread.
//
// `call` is a frozen tool call: `name`, and `arguments` as a JSON string.
// Anything malformed comes back as a message addressed to the model rather
// than as a failure of the turn — it is the one participant that can fix it.
NSString *ABLRunToolCall(NSDictionary *call, NSString *workingDirectory);

// The tool a call names, spelled the way this app dispatches on it — `exec`
// and `shell` come back as `Execute`. The transcript titles a result row with
// it, so a row reopened from disk is labelled by what ran, not by what the
// model happened to call it that round.
NSString *ABLCanonicalToolName(NSString *name);
