#import "ABLBootstrap.h"
#import "ABLConfig.h"
#import "ABLPrivileged.h"
#import "ABLShell.h"
#import "ABLStash.h"

#import <UIKit/UIKit.h>

NSString *const ABLPhaseStash = @"stash";
NSString *const ABLPhaseInstall = @"install";
NSString *const ABLPhaseReady = @"ready";

static NSString *const ABLManifestName = @"manifest.plist";

// Where the payload lives, in the order it is looked for. Inside the app
// bundle first, so folding the payload back into the app is a packaging
// decision rather than a code change.
static NSString *const ABLPayloadSubdirectory = @"bootstrap";

// Nothing on this phone can be assumed to be on PATH: the toolchain is what we
// are installing, and even coreutils may not be there yet. Every command runs
// with a PATH spelled out, no interactive prompt, and stdin closed — a dpkg
// that stops to ask a question would hang the install thread forever.
// ABLRunCommand marks a failure with one of these two suffixes and nothing
// else does. Both callers ask here rather than each spelling out the test,
// which is how the signal case came to be missed in one of them.
// One reading of the manifest's version, used by both the readiness check and
// the loader. They had their own, and disagreed: the loader substituted "0"
// and stamped .bootstrap-0 while +isReady refused an empty version outright,
// so a completed install was never recognised.
static NSString *ABLPayloadVersion(NSDictionary *manifest) {
	NSString *version = [manifest objectForKey:@"payload_version"];
	return [version isKindOfClass:[NSString class]] && [version length] > 0 ? version : @"0";
}

// Installing a toolchain is the one thing in this app that is entirely
// privileged: dpkg writes /usr, the stash edits /, and the profile script goes
// in /etc. All of it goes through the helper, so this process stays mobile
// while it happens.
static NSString *const ABLCommandPreamble =
	@"PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/airbuild/toolchain/bin; export PATH; "
	@"DEBIAN_FRONTEND=noninteractive; export DEBIAN_FRONTEND; "
	@"exec </dev/null; ";

// "4.2.1" against "5.0", numerically and component by component, so that
// 4.10 sorts after 4.9 the way a string compare would not.
static NSComparisonResult ABLCompareVersions(NSString *left, NSString *right) {
	NSArray *a = [left componentsSeparatedByString:@"."];
	NSArray *b = [right componentsSeparatedByString:@"."];
	NSUInteger count = MAX([a count], [b count]);
	for (NSUInteger i = 0; i < count; i++) {
		NSInteger x = i < [a count] ? [[a objectAtIndex:i] integerValue] : 0;
		NSInteger y = i < [b count] ? [[b objectAtIndex:i] integerValue] : 0;
		if (x != y) {
			return x < y ? NSOrderedAscending : NSOrderedDescending;
		}
	}
	return NSOrderedSame;
}

#pragma mark - Step

// The raw manifest entry stays inside this file: the table shows a step, the
// runner reads its definition, and nothing outside needs the difference.
@interface ABLBootstrapStep (ABLBootstrapPrivate)
- (NSDictionary *)definition;
@end

@implementation ABLBootstrapStep

@synthesize state = _state;

- (id)initWithDefinition:(NSDictionary *)definition {
	self = [super init];
	if (self != nil) {
		_definition = [definition retain];
		_log = [[NSMutableString alloc] init];
		_status = @"";
		_lock = [[NSLock alloc] init];
	}
	return self;
}

// One writer (the runner's thread) and one reader (the main thread), a dozen
// announcements per install, and critical sections that are a copy or an
// append. The status getter hands back a retained-autoreleased string because
// the setter releases the previous one the moment the lock is dropped.
- (NSString *)status {
	[_lock lock];
	NSString *value = [[_status retain] autorelease];
	[_lock unlock];
	return value;
}

- (void)setStatus:(NSString *)status {
	[_lock lock];
	if (_status != status) {
		[_status release];
		_status = [status copy];
	}
	[_lock unlock];
}

- (void)appendLog:(NSString *)text {
	if ([text length] == 0) {
		return;
	}
	[_lock lock];
	[_log appendString:text];
	[_lock unlock];
}

- (void)clearLog {
	[_lock lock];
	[_log setString:@""];
	[_lock unlock];
}

- (NSString *)logSnapshot {
	[_lock lock];
	NSString *value = [[_log copy] autorelease];
	[_lock unlock];
	return value;
}

- (BOOL)hasLog {
	[_lock lock];
	BOOL any = [_log length] > 0;
	[_lock unlock];
	return any;
}

- (NSString *)identifier { return [_definition objectForKey:@"id"]; }
- (NSString *)phase { return [_definition objectForKey:@"phase"]; }
- (NSString *)title { return [_definition objectForKey:@"title"]; }
- (NSString *)detail { return [_definition objectForKey:@"detail"]; }
- (NSString *)kind { return [_definition objectForKey:@"kind"]; }
- (NSDictionary *)definition { return _definition; }

- (void)dealloc {
	[_definition release];
	[_log release];
	[_status release];
	[_lock release];
	[super dealloc];
}

@end

#pragma mark - Bootstrap

@interface ABLBootstrap ()
- (void)runInBackground:(NSNumber *)generation;
- (void)announceStep:(ABLBootstrapStep *)step;
- (void)announceFinish:(ABLBootstrapStep *)failedStep;
@end

@implementation ABLBootstrap

@synthesize delegate = _delegate;
@synthesize running = _running;
@synthesize payloadDirectory = _payloadDirectory;

+ (ABLBootstrap *)shared {
	static ABLBootstrap *shared = nil;
	if (shared == nil) {
		shared = [[ABLBootstrap alloc] init];
	}
	return shared;
}

+ (NSString *)locatePayloadDirectory {
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *inBundle = [[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:ABLPayloadSubdirectory];
	if ([files fileExistsAtPath:[inBundle stringByAppendingPathComponent:ABLManifestName]]) {
		return inBundle;
	}
	NSString *installed = [ABLDefaultRoot stringByAppendingPathComponent:ABLPayloadSubdirectory];
	if ([files fileExistsAtPath:[installed stringByAppendingPathComponent:ABLManifestName]]) {
		return installed;
	}
	return nil;
}

+ (NSString *)stampPathForVersion:(NSString *)version {
	return [ABLDefaultRoot stringByAppendingPathComponent:
		[NSString stringWithFormat:@".bootstrap-%@", version]];
}

+ (BOOL)isReady {
	NSString *directory = [self locatePayloadDirectory];
	if (directory == nil) {
		return NO;
	}
	NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:
		[directory stringByAppendingPathComponent:ABLManifestName]];
	return [[NSFileManager defaultManager] fileExistsAtPath:
		[self stampPathForVersion:ABLPayloadVersion(manifest)]];
}

- (BOOL)loadWithError:(NSString **)error {
	NSString *directory = [ABLBootstrap locatePayloadDirectory];
	if (directory == nil) {
		if (error != NULL) {
			// Name the one package this firmware takes. The two Conflict, so
			// telling someone to "install the bootstrap package" when there
			// are two of them and one will not install is not help.
			BOOL iOS4 = ABLCompareVersions([[UIDevice currentDevice] systemVersion], @"5.0")
				== NSOrderedAscending;
			*error = [NSString stringWithFormat:
				@"The build environment package is not installed.\n\n"
				@"Install com.apple.airbuild.oss.bootstrap%@ on this iPhone — "
				@"scp the .deb over and run dpkg -i — then open Environment again.",
				iOS4 ? @"4" : @"6"];
		}
		return NO;
	}
	NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:
		[directory stringByAppendingPathComponent:ABLManifestName]];
	NSArray *definitions = [manifest objectForKey:@"steps"];
	if (![definitions isKindOfClass:[NSArray class]] || [definitions count] == 0) {
		if (error != NULL) {
			*error = @"The build environment package is damaged. Reinstall it, then open Environment again.";
		}
		return NO;
	}

	[_payloadDirectory release];
	_payloadDirectory = [directory copy];
	[_payloadVersion release];
	_payloadVersion = [ABLPayloadVersion(manifest) copy];

	NSMutableArray *steps = [NSMutableArray arrayWithCapacity:[definitions count]];
	NSMutableArray *phases = [NSMutableArray array];
	for (NSDictionary *definition in definitions) {
		if (![definition isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		ABLBootstrapStep *step = [[ABLBootstrapStep alloc] initWithDefinition:definition];
		[steps addObject:step];
		[step release];
		NSString *phase = [step phase];
		if (phase != nil && ![phases containsObject:phase]) {
			[phases addObject:phase];
		}
	}
	[_steps release];
	_steps = [steps copy];
	[_phases release];
	_phases = [phases copy];
	return YES;
}

- (NSArray *)phases {
	return _phases;
}

- (NSArray *)stepsInPhase:(NSString *)phase {
	NSMutableArray *steps = [NSMutableArray array];
	for (ABLBootstrapStep *step in _steps) {
		if ([[step phase] isEqualToString:phase]) {
			[steps addObject:step];
		}
	}
	return steps;
}

// A phase is as far along as its least-finished step: running if any step is,
// failed if any failed, done only when every one of them is settled.
- (ABLStepState)stateOfPhase:(NSString *)phase {
	BOOL sawPending = NO;
	for (ABLBootstrapStep *step in [self stepsInPhase:phase]) {
		switch ([step state]) {
			case ABLStepRunning: return ABLStepRunning;
			case ABLStepFailed: return ABLStepFailed;
			case ABLStepPending: sawPending = YES; break;
			default: break;
		}
	}
	return sawPending ? ABLStepPending : ABLStepDone;
}

- (BOOL)isFinished {
	for (NSString *phase in _phases) {
		if ([self stateOfPhase:phase] != ABLStepDone) {
			return NO;
		}
	}
	return [_phases count] > 0;
}

#pragma mark - Running

- (void)start {
	[self startReinstalling:NO];
}

- (void)reinstall {
	[self startReinstalling:YES];
}

- (void)startReinstalling:(BOOL)reinstalling {
	if (_running || [_steps count] == 0) {
		return;
	}
	_reinstalling = reinstalling;
	if (reinstalling) {
		// Every step goes back to pending, so the runner's "already done"
		// skip and the table both start from nothing.
		for (ABLBootstrapStep *step in _steps) {
			if ([step state] != ABLStepManual) {
				[step setState:ABLStepPending];
				[step setStatus:nil];
				[step clearLog];
			}
		}
	}
	_running = YES;
	_generation++;
	[self performSelectorInBackground:@selector(runInBackground:)
		withObject:[NSNumber numberWithUnsignedInteger:_generation]];
}

// Delivered in common modes so the table keeps updating while it is being
// scrolled — the same contract the chat stream uses.
//
// Waited on, unlike a streamed token: a step is handed across as a live object
// whose status string this thread is about to replace, and there are only a
// dozen or so of these in a whole install. Blocking until the table has read
// it is what makes one writer and one reader safe without a lock.
- (void)announceStep:(ABLBootstrapStep *)step {
	[self performSelectorOnMainThread:@selector(deliverStepUpdate:) withObject:step
		waitUntilDone:YES modes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
}

- (void)deliverStepUpdate:(ABLBootstrapStep *)step {
	[_delegate bootstrap:self didUpdateStep:step];
}

- (void)announceFinish:(ABLBootstrapStep *)failedStep {
	_running = NO;
	[self performSelectorOnMainThread:@selector(deliverFinish:) withObject:failedStep
		waitUntilDone:NO modes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
}

- (void)deliverFinish:(ABLBootstrapStep *)failedStep {
	[_delegate bootstrap:self didFinishWithFailure:failedStep];
}

- (void)runInBackground:(NSNumber *)generation {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	ABLBootstrapStep *failed = nil;
	for (NSString *phase in _phases) {
		if (failed != nil) {
			break;
		}
		for (ABLBootstrapStep *step in [self stepsInPhase:phase]) {
			if ([generation unsignedIntegerValue] != _generation) {
				[pool release];
				return; // a newer run replaced this one
			}
			if ([step state] == ABLStepDone || [step state] == ABLStepSkipped
					|| [step state] == ABLStepManual) {
				continue;
			}
			NSAutoreleasePool *stepPool = [[NSAutoreleasePool alloc] init];
			[step setState:ABLStepRunning];
			[step setStatus:@"Running…"];
			[self announceStep:step];
			[self executeStep:step];
			[self announceStep:step];
			BOOL stepFailed = [step state] == ABLStepFailed;
			[stepPool release];
			if (stepFailed) {
				failed = step;
				break;
			}
		}
	}
	if (failed == nil && [self isFinished]) {
		NSString *stamp = [ABLBootstrap stampPathForVersion:_payloadVersion];
		[[NSFileManager defaultManager] createDirectoryAtPath:ABLDefaultRoot
			withIntermediateDirectories:YES attributes:nil error:NULL];
		if (![[[NSDate date] description] writeToFile:stamp
				atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
			// The normal path on a phone: /var/airbuild belongs to root, so
			// that the payload the installer feeds to dpkg cannot be swapped
			// out by anything running as the app's user. Only the projects
			// directory below it is the app's. The direct write above is for
			// the host, where there is no helper at all.
			ABLRunPrivilegedCommand([NSString stringWithFormat:@"date > %@",
				ABLShellQuote(stamp)], nil);
		}
	}
	[self announceFinish:failed];
	[pool release];
}

#pragma mark - Steps

// Absolute paths of this step's payload files, and the first one that is not
// actually there.
- (NSArray *)payloadFilesForStep:(ABLBootstrapStep *)step missing:(NSMutableArray *)missing {
	NSMutableArray *paths = [NSMutableArray array];
	NSFileManager *manager = [NSFileManager defaultManager];
	for (NSString *name in [[step definition] objectForKey:@"files"]) {
		NSString *path = [_payloadDirectory stringByAppendingPathComponent:name];
		if ([manager fileExistsAtPath:path]) {
			[paths addObject:path];
		} else {
			[missing addObject:name];
		}
	}
	return paths;
}

- (BOOL)step:(ABLBootstrapStep *)step isGatedOutBy:(NSString *)systemVersion {
	NSDictionary *definition = [step definition];
	NSString *minimum = [definition objectForKey:@"minFirmware"];
	NSString *maximum = [definition objectForKey:@"maxFirmware"];
	if ([minimum length] > 0 && ABLCompareVersions(systemVersion, minimum) == NSOrderedAscending) {
		[step setStatus:[NSString stringWithFormat:@"Needs iOS %@", minimum]];
		return YES;
	}
	if ([maximum length] > 0 && ABLCompareVersions(systemVersion, maximum) == NSOrderedDescending) {
		[step setStatus:[NSString stringWithFormat:@"iOS %@ and older", maximum]];
		return YES;
	}
	return NO;
}

- (void)executeStep:(ABLBootstrapStep *)step {
	NSDictionary *definition = [step definition];
	NSString *kind = [step kind];

	if ([self step:step isGatedOutBy:[[UIDevice currentDevice] systemVersion]]) {
		[step appendLog:[NSString stringWithFormat:@"skipped: %@\n", [step status]]];
		[step setState:ABLStepSkipped];
		return;
	}

	if ([kind isEqualToString:@"manual"]) {
		[step appendLog:[step detail] != nil ? [step detail] : @""];
		[step setStatus:[definition objectForKey:@"note"] != nil ? [definition objectForKey:@"note"] : @"Not installed"];
		[step setState:ABLStepManual];
		return;
	}
	if ([kind isEqualToString:@"space"]) {
		[self runSpaceStep:step];
		return;
	}
	if ([kind isEqualToString:@"mkdir"]) {
		[self runMakeDirectoriesStep:step];
		return;
	}
	if ([kind isEqualToString:@"stash"]) {
		[self runStashStep:step];
		return;
	}
	if ([kind isEqualToString:@"dpkg"] || [kind isEqualToString:@"extract"]
			|| [kind isEqualToString:@"tar"]) {
		[self runPayloadStep:step];
		return;
	}
	if ([kind isEqualToString:@"shell"]) {
		[self runShellStep:step];
		return;
	}
	[step appendLog:[NSString stringWithFormat:@"unknown step kind: %@\n", kind]];
	[step setStatus:@"Unknown step"];
	[step setState:ABLStepFailed];
}

- (void)runSpaceStep:(ABLBootstrapStep *)step {
	unsigned long long system = [ABLStash freeBytesAtPath:@"/"];
	unsigned long long data = [ABLStash freeBytesAtPath:@"/private/var"];
	[step appendLog:[NSString stringWithFormat:@"/          %llu KB free\n/private/var %llu KB free\n",
		system / 1024, data / 1024]];
	[step setStatus:[NSString stringWithFormat:@"/ %llu MB · /var %llu MB",
		system / (1024 * 1024), data / (1024 * 1024)]];
	[step setState:ABLStepDone];
}

// /var/airbuild belongs to the app's own user after ABLProjectStore's prepare,
// so these are ordinary mkdirs; the privileged retry is for the one case that
// is not — a payload package installed since launch, which hands the folder
// back to root.
- (void)runMakeDirectoriesStep:(ABLBootstrapStep *)step {
	NSFileManager *files = [NSFileManager defaultManager];
	for (NSString *path in [[step definition] objectForKey:@"paths"]) {
		if ([files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL]
				|| [files fileExistsAtPath:path]) {
			[step appendLog:[NSString stringWithFormat:@"%@\n", path]];
			continue;
		}
		NSString *output = ABLRunPrivilegedCommand(
			[@"mkdir -p " stringByAppendingString:ABLShellQuote(path)], nil);
		if (!ABLOutputFailed(output)) {
			[step appendLog:[NSString stringWithFormat:@"%@ (as root)\n", path]];
			continue;
		}
		[step appendLog:[NSString stringWithFormat:@"cannot create %@\n%@\n", path, output]];
		[step setStatus:@"Cannot create directory"];
		[step setState:ABLStepFailed];
		return;
	}
	[step setStatus:@"Ready"];
	[step setState:ABLStepDone];
}

// Skipped outright when the system partition already has room: this is the one
// step that edits /, and not needing to is always the better outcome.
- (void)runStashStep:(ABLBootstrapStep *)step {
	NSDictionary *definition = [step definition];
	unsigned long long threshold = [[definition objectForKey:@"skipIfFreeKB"] unsignedLongLongValue] * 1024;
	unsigned long long free = [ABLStash freeBytesAtPath:@"/"];
	if (threshold > 0 && free >= threshold) {
		[step appendLog:[NSString stringWithFormat:@"/ already has %llu KB free; nothing moved\n", free / 1024]];
		[step setStatus:@"Not needed"];
		[step setState:ABLStepSkipped];
		return;
	}
	NSArray *paths = [definition objectForKey:@"paths"];
	NSUInteger moved = 0;
	for (NSString *path in paths) {
		// stashPath: is asked directly, never pre-screened with canStashPath:.
		// An already-stashed path is a symlink, canStashPath: refuses every
		// symlink, and screening on it meant the idempotence and
		// jailbreak-recognition logic inside stashPath: was unreachable from
		// the only caller that ships: a rerun logged "already a symlink",
		// counted nothing, and reported "Nothing to move".
		NSMutableString *entry = [NSMutableString string];
		BOOL ok = ABLPrivilegedStash(path, entry);
		[step appendLog:entry];
		if (ok) {
			moved++;
			continue;
		}
		// Refusals are reported by stashPath: into the log. A path this is not
		// allowed to touch is a plan problem, not a device failure, so the
		// step carries on and the count at the end tells the truth.
		if ([entry rangeOfString:@"refused"].location != NSNotFound) {
			continue;
		}
		[step setStatus:@"Could not move files"];
		[step setState:ABLStepFailed];
		return;
	}
	if (moved == 0) {
		[step setStatus:@"Nothing to move"];
		[step setState:ABLStepSkipped];
		return;
	}
	[step setStatus:[NSString stringWithFormat:@"Moved %lu of %lu",
		(unsigned long)moved, (unsigned long)[paths count]]];
	[step setState:ABLStepDone];
}

// "coreutils_8.12-13_iphoneos-arm.deb" -> "coreutils". Just for the row: the
// log always carries the whole filename.
static NSString *ABLPackageNameFromFile(NSString *path) {
	NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
	NSRange underscore = [name rangeOfString:@"_"];
	return underscore.location == NSNotFound
		? name : [name substringToIndex:underscore.location];
}

// What dpkg already has, as name -> version, read straight from its status
// file. Asking dpkg itself would mean a process and a full database parse per
// package; the file is one read and the same answer. Only fully installed
// packages count — a half-configured one has to be installed again.
//
// Scanned a line at a time rather than split on newlines: a jailbroken phone's
// status file is a megabyte or more, and -componentsSeparatedByString: turns
// that into tens of thousands of NSStrings all alive at once, several
// megabytes of them, on a device with 128 MB. Here one line exists at a time
// and the pool is drained as the scan moves.
static NSDictionary *ABLInstalledPackages(void) {
	NSString *status = [NSString stringWithContentsOfFile:@"/var/lib/dpkg/status"
		encoding:NSUTF8StringEncoding error:NULL];
	NSMutableDictionary *installed = [NSMutableDictionary dictionary];
	NSUInteger length = [status length];
	if (length == 0) {
		return installed;
	}
	NSString *name = nil, *version = nil;
	BOOL usable = NO;
	NSUInteger start = 0;
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSUInteger sinceDrain = 0;
	while (start <= length) {
		NSRange search = NSMakeRange(start, length - start);
		NSRange newline = [status rangeOfString:@"\n" options:NSLiteralSearch range:search];
		NSRange lineRange = newline.location == NSNotFound
			? search : NSMakeRange(start, newline.location - start);
		NSString *line = [status substringWithRange:lineRange];
		if ([line length] == 0) {
			if (usable && name != nil && version != nil) {
				// Retained across the drain below by the dictionary itself.
				[installed setObject:version forKey:name];
			}
			name = version = nil;
			usable = NO;
		} else if ([line hasPrefix:@"Package: "]) {
			name = [line substringFromIndex:9];
		} else if ([line hasPrefix:@"Version: "]) {
			version = [line substringFromIndex:9];
		} else if ([line hasPrefix:@"Status: "]) {
			usable = [line hasSuffix:@" installed"];
		}
		if (newline.location == NSNotFound) {
			break;
		}
		start = NSMaxRange(newline);
		// A stanza's name and version are autoreleased substrings, so the pool
		// can only be drained between stanzas — never while one is half read.
		if (++sinceDrain >= 512 && name == nil && version == nil) {
			[pool release];
			pool = [[NSAutoreleasePool alloc] init];
			sinceDrain = 0;
		}
	}
	if (usable && name != nil && version != nil) {
		[installed setObject:version forKey:name];
	}
	[pool release];
	return installed;
}

- (void)runPayloadStep:(ABLBootstrapStep *)step {
	NSDictionary *definition = [step definition];
	NSString *kind = [step kind];
	BOOL optional = [[definition objectForKey:@"optional"] boolValue];
	NSMutableArray *missing = [NSMutableArray array];
	NSArray *paths = [self payloadFilesForStep:step missing:missing];

	if ([missing count] > 0) {
		[step appendLog:[NSString stringWithFormat:@"not in the payload: %@\n",
			[missing componentsJoinedByString:@", "]]];
		// Any shortfall fails a required step, not only a total one. Installing
		// 19 of 20 packages and reporting "19 installed" wrote the readiness
		// stamp for a toolchain with a hole in it.
		if (!optional) {
			[step setStatus:[NSString stringWithFormat:@"%lu files missing",
				(unsigned long)[missing count]]];
			[step setState:ABLStepFailed];
			return;
		}
	}
	if ([paths count] == 0) {
		[step setStatus:@"Nothing to install"];
		[step setState:optional ? ABLStepSkipped : ABLStepFailed];
		return;
	}

	NSString *destination = [definition objectForKey:@"dest"];
	if ([destination length] > 0) {
		[[NSFileManager defaultManager] createDirectoryAtPath:destination
			withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	if ([kind isEqualToString:@"dpkg"]) {
		[self installPackages:paths forStep:step optional:optional];
		return;
	}

	// tar and extract stay one file at a time: there are two of them, each is
	// tens of megabytes, and the row should name the one that is unpacking.
	NSUInteger failures = 0;
	NSUInteger index = 0;
	for (NSString *path in paths) {
		index++;
		[step setStatus:[NSString stringWithFormat:@"%lu of %lu · %@",
			(unsigned long)index, (unsigned long)[paths count],
			ABLPackageNameFromFile(path)]];
		[self announceStep:step];

		NSString *command;
		if ([kind isEqualToString:@"extract"]) {
			command = [NSString stringWithFormat:@"%@dpkg-deb -x %@ %@",
				ABLCommandPreamble, ABLShellQuote(path), ABLShellQuote(destination)];
		} else {
			command = [NSString stringWithFormat:@"%@tar xzf %@ -C %@",
				ABLCommandPreamble, ABLShellQuote(path), ABLShellQuote(destination)];
		}
		[step appendLog:[NSString stringWithFormat:@"\n$ %@\n", [path lastPathComponent]]];
		NSString *output = ABLRunPrivilegedCommand(command, nil);
		[step appendLog:output];
		[step appendLog:@"\n"];
		if (ABLOutputFailed(output)) {
			failures++;
		}
	}

	if (failures == 0) {
		[step setStatus:[NSString stringWithFormat:@"%lu installed", (unsigned long)[paths count]]];
		[step setState:ABLStepDone];
		return;
	}
	[step setStatus:[NSString stringWithFormat:@"%lu of %lu failed",
		(unsigned long)failures, (unsigned long)[paths count]]];
	[step setState:optional ? ABLStepSkipped : ABLStepFailed];
}

// Everything dpkg has to do goes into one call.
//
// It was one call per package, so the row could name what was going in. That
// cost more than it was worth: dpkg reads and rewrites its whole database on
// every invocation, and on a 3G, two dozen packages meant two dozen full
// database passes and several minutes of a phone doing almost nothing else.
// Packages already installed at the pinned version are dropped first, from a
// single read of dpkg's status file, so a second run of Environment has
// nothing to do rather than reinstalling the toolchain over itself.
- (void)installPackages:(NSArray *)paths forStep:(ABLBootstrapStep *)step
		optional:(BOOL)optional {
	NSDictionary *installed = _reinstalling ? nil : ABLInstalledPackages();
	NSArray *manifest = [[step definition] objectForKey:@"packages"];
	NSMutableDictionary *wanted = [NSMutableDictionary dictionary];
	for (NSDictionary *entry in manifest) {
		NSString *file = [entry objectForKey:@"file"];
		NSString *name = [entry objectForKey:@"name"];
		NSString *version = [entry objectForKey:@"version"];
		if ([file isKindOfClass:[NSString class]] && [name isKindOfClass:[NSString class]]
				&& [version isKindOfClass:[NSString class]]) {
			[wanted setObject:[NSArray arrayWithObjects:name, version, nil]
				forKey:[file lastPathComponent]];
		}
	}

	NSMutableArray *pending = [NSMutableArray array];
	NSUInteger present = 0;
	for (NSString *path in paths) {
		NSArray *entry = [wanted objectForKey:[path lastPathComponent]];
		// No manifest entry means no way to tell, so it goes in.
		if (entry) {
			NSString *have = [installed objectForKey:[entry objectAtIndex:0]];
			if (have && [have isEqualToString:[entry objectAtIndex:1]]) {
				present++;
				continue;
			}
		}
		[pending addObject:path];
	}

	if ([pending count] == 0) {
		[step setStatus:[NSString stringWithFormat:@"%lu already installed",
			(unsigned long)present]];
		[step appendLog:@"every package is already installed at the pinned version\n"];
		[step setState:ABLStepDone];
		return;
	}

	[step setStatus:present > 0
		? [NSString stringWithFormat:@"Installing %lu; %lu already installed",
			(unsigned long)[pending count], (unsigned long)present]
		: [NSString stringWithFormat:@"Installing %lu packages",
			(unsigned long)[pending count]]];
	[self announceStep:step];

	NSMutableString *command = [NSMutableString stringWithFormat:
		@"%@dpkg -i --force-all", ABLCommandPreamble];
	for (NSString *path in pending) {
		[command appendFormat:@" %@", ABLShellQuote(path)];
		[step appendLog:[NSString stringWithFormat:@"  %@\n", [path lastPathComponent]]];
	}
	[step appendLog:@"\n$ dpkg -i --force-all …\n"];
	NSString *output = ABLRunPrivilegedCommand(command, nil);
	[step appendLog:output];

	if (ABLOutputFailed(output)) {
		[step setStatus:[NSString stringWithFormat:@"Unable to install %lu packages",
			(unsigned long)[pending count]]];
		[step setState:optional ? ABLStepSkipped : ABLStepFailed];
		return;
	}
	[step setStatus:present > 0
		? [NSString stringWithFormat:@"%lu installed; %lu already installed",
			(unsigned long)[pending count], (unsigned long)present]
		: [NSString stringWithFormat:@"%lu installed", (unsigned long)[pending count]]];
	[step setState:ABLStepDone];
}

- (void)runShellStep:(ABLBootstrapStep *)step {
	NSString *command = [[step definition] objectForKey:@"command"];
	if ([command length] == 0) {
		[step setStatus:@"Nothing to run"];
		[step setState:ABLStepSkipped];
		return;
	}
	NSString *output = ABLRunPrivilegedCommand(
		[ABLCommandPreamble stringByAppendingString:command], nil);
	[step appendLog:output];
	BOOL optional = [[[step definition] objectForKey:@"optional"] boolValue];
	BOOL failed = ABLOutputFailed(output);
	// The row shows the last line the command printed, which for a verify step
	// is the answer and for a failure is usually the reason.
	NSArray *lines = [output componentsSeparatedByString:@"\n"];
	NSString *last = @"";
	for (NSString *line in lines) {
		if ([[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] > 0) {
			last = line;
		}
	}
	[step setStatus:failed ? last : ([last length] > 0 ? last : @"Done")];
	// A row must not show a green tick for a command that exited non-zero,
	// even when the plan says the step is optional. Skipped is what
	// runPayloadStep reports for the same case.
	[step setState:failed ? (optional ? ABLStepSkipped : ABLStepFailed) : ABLStepDone];
}

- (void)dealloc {
	[_payloadDirectory release];
	[_payloadVersion release];
	[_steps release];
	[_phases release];
	[super dealloc];
}

@end
