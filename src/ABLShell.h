#import <Foundation/Foundation.h>

// The most output one command may return. 64 KB of terminal text is already
// thousands of lines on a 128 MB phone; past that the result is truncated.
extern const NSUInteger ABLShellOutputLimit;

// Combined stdout and stderr of `command`, run by /bin/sh with
// `workingDirectory` as its current directory — the process's own directory
// when that is nil or empty. Bounded by ABLShellOutputLimit, then
// "\n(truncated)"; a non-zero exit status is appended as "\n(exit N)"; empty
// output reads "(no output)".
//
// This blocks for as long as the command runs. Never call it from the main
// thread.
NSString *ABLRunCommand(NSString *command, NSString *workingDirectory);

// Whether `output` came back from a command that failed, decided from the
// suffix ABLRunCommand appends. It is the only record of the exit status, so
// this is the one place that reads it.
BOOL ABLOutputFailed(NSString *output);

// `text` as a single-quoted /bin/sh word. Exported because the bootstrap
// manifest builds command lines out of paths it did not choose.
NSString *ABLShellQuote(NSString *text);
