#import <Foundation/Foundation.h>

// The one door to root. AirBuild itself runs as mobile, the way every other
// app on the phone does; the small setuid binary beside it in the bundle is
// the only thing that ever holds uid 0, and it holds it for exactly as long
// as one command takes.
//
// The app used to be setuid root itself, with a launch script in front of it
// because SpringBoard SIGKILLs a setuid Mach-O. That put UIKit, CFNetwork,
// the photo picker, an HTTP client talking to a remote endpoint and a model's
// shell commands all in one uid-0 process. Everything that needs root now
// goes through here and nothing else does.
//
// The helper is `airbuildhelper` in the app bundle, installed root:wheel mode
// 4755 by Packaging/postinst. When it is missing — the host tests, a bundle
// run in place — these fall back to running unprivileged, which is what those
// environments want anyway.

// Absolute path of the helper, or nil when the bundle has none.
NSString *ABLHelperPath(void);

// Whether a privileged call will actually be privileged. NO means the calls
// below still work, as this process's own user.
BOOL ABLHelperIsAvailable(void);

// Combined stdout and stderr of `command`, run by /bin/sh as root with
// `workingDirectory` as its current directory. Identical contract to
// ABLRunCommand — the same 64 KB bound, the same "(exit N)" suffix — because
// it is that function with the helper in front. Blocks; never call it from
// the main thread.
NSString *ABLRunPrivilegedCommand(NSString *command, NSString *workingDirectory);

// Makes `root` (/var/airbuild) and its projects directory exist and belong to
// the user the app runs as, so everything the app itself writes — projects,
// transcripts, the readiness stamp — needs no privilege at all. Idempotent and
// cheap on every run after the first. Appends what it did to `log`.
//
// Called once at launch: installing the payload package puts /var/airbuild
// back under root, and this is what takes it back.
BOOL ABLPrepareRoot(NSString *root, NSMutableString *log);

// Puts `data` at `path`, creating the directories above it. Root, because the
// model builds as root and a directory it made with Execute is root's — this
// process cannot write into one as itself. Returns NO with `error` set to
// something the model can read.
BOOL ABLPrivilegedWriteFile(NSString *path, NSData *data, NSString **error);

// ABLStash's two mutating operations, run as root. The read-only queries
// (+freeBytesAtPath:, +stashedPaths) need no privilege and stay in-process.
BOOL ABLPrivilegedStash(NSString *path, NSMutableString *log);
BOOL ABLPrivilegedUnstash(NSString *path, NSMutableString *log);
