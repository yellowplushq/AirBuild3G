#import <Foundation/Foundation.h>

@class ABLBootstrap;

// The three phases, in the order they must run. Nothing in a phase starts
// until the phase above it has finished cleanly: a stash that failed must
// never be followed by an install that then fills the system partition.
extern NSString *const ABLPhaseStash;
extern NSString *const ABLPhaseInstall;
extern NSString *const ABLPhaseReady;

typedef enum {
	ABLStepPending = 0,
	ABLStepRunning,
	ABLStepDone,
	ABLStepSkipped, // a firmware gate, or nothing to do
	ABLStepManual,  // nothing to run; the row explains why
	ABLStepFailed
} ABLStepState;

// One row of the install plan, as written into the payload's manifest.plist
// and as shown in the Environment table.
@interface ABLBootstrapStep : NSObject {
	NSDictionary *_definition;
	NSMutableString *_log;
	NSString *_status;
	ABLStepState _state;
	// NSLock, not @synchronized: the latter needs the SjLj unwinder, which
	// this armv6 toolchain does not link.
	NSLock *_lock;
}

@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) NSString *phase;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSString *detail;
@property(nonatomic, readonly) NSString *kind;
@property(nonatomic, assign) ABLStepState state;

// The runner writes these from its worker thread while the table reads them on
// the main thread, on every scroll and every reload. They are the only mutable
// state that crosses that line, so all four go through the step's own lock.
// The log is never handed out as the live NSMutableString: -logSnapshot is a
// copy taken under the lock, because copying a string another thread is
// appending to is not a synchronization primitive.
- (NSString *)status;             // the one line the row shows
- (void)setStatus:(NSString *)status;
- (void)appendLog:(NSString *)text;
- (void)clearLog;                 // a reinstall starts the step's log over
- (NSString *)logSnapshot;        // everything the step printed, so far
- (BOOL)hasLog;

- (id)initWithDefinition:(NSDictionary *)definition;

@end

@protocol ABLBootstrapDelegate <NSObject>
// Both always on the main thread.
- (void)bootstrap:(ABLBootstrap *)bootstrap didUpdateStep:(ABLBootstrapStep *)step;
- (void)bootstrap:(ABLBootstrap *)bootstrap didFinishWithFailure:(ABLBootstrapStep *)failedStep;
@end

// Installs the on-device build environment from a payload of Debian packages
// and tarballs: stash room free, install, then prove it works.
//
// The plan is data — the payload's manifest.plist — so which packages exist and
// in what order is a build-time decision, not a compiled-in one. The runner
// walks it on a thread of its own; nothing here blocks the main thread.
@interface ABLBootstrap : NSObject {
	NSString *_payloadDirectory;
	NSString *_payloadVersion;
	NSArray *_steps;
	NSArray *_phases;
	id<ABLBootstrapDelegate> _delegate;
	BOOL _running;
	BOOL _reinstalling;
	NSUInteger _generation;
}

@property(nonatomic, assign) id<ABLBootstrapDelegate> delegate;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) NSString *payloadDirectory;

// The one installer. There is one build environment on the device and one
// dpkg database, so there is one runner: a view controller that owned its own
// meant Back-then-Settings-then-Install ran two of them against the same /usr
// at once, and neither instance's `running` guard could see the other.
+ (ABLBootstrap *)shared;

// Where the payload was found: the app bundle first, then /var/airbuild.
// nil when neither has one.
+ (NSString *)locatePayloadDirectory;

// Whether a previous run finished. Read at launch to decide whether the
// Environment page is pushed before the project list.
+ (BOOL)isReady;

// Reads the manifest. NO — with `error` filled in — when no payload is
// installed, which is the normal state of a fresh app on a phone that has not
// had the payload deb copied over yet.
- (BOOL)loadWithError:(NSString **)error;

- (NSArray *)phases;                          // ordered phase identifiers
- (NSArray *)stepsInPhase:(NSString *)phase;  // ordered steps
- (ABLStepState)stateOfPhase:(NSString *)phase;
- (BOOL)isFinished;

// Runs from the first step that is not already done, and lets dpkg skip any
// package already installed at the pinned version. Returns immediately.
- (void)start;

// Runs every step again and installs every package again, whatever dpkg's
// status file says. The repair path: -start is idempotent by design, so it is
// exactly the wrong thing when the toolchain on disk is damaged rather than
// missing — dpkg still reports the packages as installed, and a run does
// nothing. Returns immediately.
- (void)reinstall;

@end
