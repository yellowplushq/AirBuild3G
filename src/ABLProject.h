#import <Foundation/Foundation.h>

// Why a round stopped, stored in round_<n>.plist so a reopened transcript can
// still tell an answer from an interruption.
extern NSString *const ABLRoundEndReasonComplete;
extern NSString *const ABLRoundEndReasonStopped;
extern NSString *const ABLRoundEndReasonError;
extern NSString *const ABLRoundEndReasonRoundLimit;
extern NSString *const ABLRoundEndReasonInterrupted; // app killed mid-reply

// One project: a directory named by a UUID, holding the model's working tree
// and the conversation about it.
//
//   <root>/projects/<uuid>/
//     manifest.plist            name, timestamps, round count
//     conversation/round_<n>.plist
//     project/                  the working tree; cwd for every exec
//
// The conversation is append-only, one file per round, because a 3G must never
// rewrite a two-megabyte transcript to record one token. A round is one user
// message plus everything the assistant produced until it stopped, tool
// results included.
@interface ABLProject : NSObject {
	NSString *_uuid;
	NSString *_name;
	NSString *_directory;
	NSDate *_created;
	NSDate *_modified;
	NSString *_lastMessage;
	NSUInteger _roundCount;
}

@property(nonatomic, readonly) NSString *uuid;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, readonly) NSString *directory;
@property(nonatomic, readonly) NSDate *created;
@property(nonatomic, readonly) NSDate *modified;
@property(nonatomic, readonly) NSString *lastMessage; // subtitle for the list
@property(nonatomic, readonly) NSUInteger roundCount;

// Reads <directory>/manifest.plist. nil when it is missing or unreadable, so
// the list can skip one broken project instead of failing entirely.
+ (id)projectWithDirectory:(NSString *)directory;

// Builds the tree — manifest, conversation/, project/ — and writes the
// manifest. nil if any of that fails.
+ (id)createProjectNamed:(NSString *)name inDirectory:(NSString *)parent;

- (NSString *)manifestPath;
- (NSString *)conversationDirectory;
- (NSString *)workingDirectory;
- (NSString *)pathForRoundAtIndex:(NSUInteger)index;

- (BOOL)saveManifest;

// Every round in order, flattened into the transcript rows the chat page
// works with. Mutable throughout: a reopened reply is still appended to.
- (NSMutableArray *)loadMessages;

// Writes round_<index>.plist. Writing an index that already exists replaces
// it, which is what makes closing a round twice harmless. The manifest's
// round count, modified date and subtitle are updated from it.
- (BOOL)writeRoundAtIndex:(NSUInteger)index messages:(NSArray *)messages endReason:(NSString *)endReason;

@end
