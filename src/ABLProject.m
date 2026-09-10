#import "ABLProject.h"

NSString *const ABLRoundEndReasonComplete = @"complete";
NSString *const ABLRoundEndReasonStopped = @"stopped";
NSString *const ABLRoundEndReasonError = @"error";
NSString *const ABLRoundEndReasonRoundLimit = @"round_limit";
NSString *const ABLRoundEndReasonInterrupted = @"interrupted";

// Bumped only if a future layout cannot be read by this code. A manifest from
// a newer version is skipped rather than misread.
static const NSInteger ABLProjectFormatVersion = 1;

static NSString *const ABLManifestVersionKey = @"format_version";
static NSString *const ABLManifestUUIDKey = @"uuid";
static NSString *const ABLManifestNameKey = @"name";
static NSString *const ABLManifestCreatedKey = @"created";
static NSString *const ABLManifestModifiedKey = @"modified";
static NSString *const ABLManifestRoundCountKey = @"round_count";
static NSString *const ABLManifestLastMessageKey = @"last_message";

static NSString *const ABLRoundIndexKey = @"index";
static NSString *const ABLRoundStartedKey = @"started";
static NSString *const ABLRoundFinishedKey = @"finished";
static NSString *const ABLRoundEndReasonKey = @"end_reason";
static NSString *const ABLRoundMessagesKey = @"messages";

// How much of a message the project list shows under the name.
static const NSUInteger ABLSubtitleLimit = 80;

// Binary rather than XML, for two reasons that both matter here: an XML plist
// stores dates to the whole second, which is far too coarse to order projects
// by when they were last touched, and a transcript of any size parses and
// writes noticeably faster in binary on a 128 MB phone.
static BOOL ABLWritePropertyList(id plist, NSString *path) {
	NSString *error = nil;
	NSData *data = [NSPropertyListSerialization dataFromPropertyList:plist
		format:NSPropertyListBinaryFormat_v1_0 errorDescription:&error];
	// This method hands back an owned string, unusually for a getter.
	[error release];
	if (data == nil) {
		return NO;
	}
	return [data writeToFile:path atomically:YES];
}

// Reads a plist with every container and string mutable, which is what lets a
// reopened transcript keep growing its last row in place.
static id ABLMutablePropertyListAtPath(NSString *path) {
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (data == nil) {
		return nil;
	}
	NSString *error = nil;
	NSPropertyListFormat format;
	id plist = [NSPropertyListSerialization propertyListFromData:data
		mutabilityOption:NSPropertyListMutableContainersAndLeaves
		format:&format errorDescription:&error];
	// This method hands back an owned string, unusually for a getter.
	[error release];
	return plist;
}

// The one line the project list shows: the newest thing either side said.
// Thinking and command output are skipped — neither identifies a project.
static NSString *ABLSubtitleForMessages(NSArray *messages) {
	for (NSInteger i = (NSInteger)[messages count] - 1; i >= 0; i--) {
		NSDictionary *message = [messages objectAtIndex:(NSUInteger)i];
		NSString *role = [message objectForKey:@"role"];
		if (![role isEqualToString:@"user"] && ![role isEqualToString:@"assistant"]) {
			continue;
		}
		NSString *content = [message objectForKey:@"content"];
		content = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if ([content length] == 0) {
			continue;
		}
		content = [content stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
		if ([content length] > ABLSubtitleLimit) {
			content = [[content substringToIndex:ABLSubtitleLimit] stringByAppendingString:@"…"];
		}
		return content;
	}
	return @"";
}

@implementation ABLProject

@synthesize uuid = _uuid;
@synthesize name = _name;
@synthesize directory = _directory;
@synthesize created = _created;
@synthesize modified = _modified;
@synthesize lastMessage = _lastMessage;
@synthesize roundCount = _roundCount;

+ (id)projectWithDirectory:(NSString *)directory {
	NSString *path = [directory stringByAppendingPathComponent:@"manifest.plist"];
	NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:path];
	if (manifest == nil) {
		return nil;
	}
	if ([[manifest objectForKey:ABLManifestVersionKey] integerValue] > ABLProjectFormatVersion) {
		return nil;
	}
	NSString *identifier = [manifest objectForKey:ABLManifestUUIDKey];
	NSString *name = [manifest objectForKey:ABLManifestNameKey];
	if (![identifier isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]]) {
		return nil;
	}

	ABLProject *project = [[[self alloc] init] autorelease];
	project->_directory = [directory copy];
	project->_uuid = [identifier copy];
	project->_name = [name copy];
	// Every remaining field is type-checked, not just read. A manifest can be
	// syntactically valid and still hold the wrong class in a key — the system
	// prompt tells the model where this file is, and an exec runs as root — and
	// -unsignedIntegerValue on an NSString is an unrecognized selector that
	// takes the whole project list down on the app's root screen, where the
	// user has no way to recover. The contract is that one bad project is
	// skipped, so a wrong type is treated exactly like a missing value.
	id created = [manifest objectForKey:ABLManifestCreatedKey];
	id modified = [manifest objectForKey:ABLManifestModifiedKey];
	id lastMessage = [manifest objectForKey:ABLManifestLastMessageKey];
	id roundCount = [manifest objectForKey:ABLManifestRoundCountKey];

	project->_created = [([created isKindOfClass:[NSDate class]] ? created : [NSDate date]) retain];
	project->_modified = [([modified isKindOfClass:[NSDate class]] ? modified : project->_created) retain];
	project->_lastMessage = [([lastMessage isKindOfClass:[NSString class]] ? lastMessage : @"") copy];
	project->_roundCount = [roundCount isKindOfClass:[NSNumber class]]
		? (NSUInteger)[roundCount unsignedIntegerValue] : 0;
	return project;
}

+ (id)createProjectNamed:(NSString *)name inDirectory:(NSString *)parent {
	CFUUIDRef reference = CFUUIDCreate(kCFAllocatorDefault);
	NSString *identifier = [(NSString *)CFUUIDCreateString(kCFAllocatorDefault, reference) autorelease];
	CFRelease(reference);

	ABLProject *project = [[[self alloc] init] autorelease];
	project->_uuid = [identifier copy];
	project->_name = [name copy];
	project->_directory = [[parent stringByAppendingPathComponent:identifier] copy];
	project->_created = [[NSDate date] retain];
	project->_modified = [project->_created retain];
	project->_lastMessage = @"";
	project->_roundCount = 0;

	NSFileManager *files = [NSFileManager defaultManager];
	if (![files createDirectoryAtPath:[project conversationDirectory]
			withIntermediateDirectories:YES attributes:nil error:NULL]) {
		return nil;
	}
	if (![files createDirectoryAtPath:[project workingDirectory]
			withIntermediateDirectories:YES attributes:nil error:NULL]) {
		return nil;
	}
	if (![project saveManifest]) {
		return nil;
	}
	return project;
}

- (NSString *)manifestPath {
	return [_directory stringByAppendingPathComponent:@"manifest.plist"];
}

- (NSString *)conversationDirectory {
	return [_directory stringByAppendingPathComponent:@"conversation"];
}

- (NSString *)workingDirectory {
	return [_directory stringByAppendingPathComponent:@"project"];
}

- (NSString *)pathForRoundAtIndex:(NSUInteger)index {
	return [[self conversationDirectory] stringByAppendingPathComponent:
		[NSString stringWithFormat:@"round_%lu.plist", (unsigned long)index]];
}

- (void)setName:(NSString *)name {
	if (name == _name) {
		return;
	}
	[_name release];
	_name = [name copy];
}

- (BOOL)saveManifest {
	// Built key by key rather than with +dictionaryWithObjectsAndKeys:, which
	// stops at the first nil value. A nil _name dropped name, created,
	// modified, round_count and last_message and then wrote the two-key
	// remainder successfully, leaving a project directory that could never be
	// reopened and never appeared in the list.
	NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
	[manifest setObject:[NSNumber numberWithInteger:ABLProjectFormatVersion] forKey:ABLManifestVersionKey];
	[manifest setObject:_uuid != nil ? _uuid : @"" forKey:ABLManifestUUIDKey];
	[manifest setObject:_name != nil ? _name : @"" forKey:ABLManifestNameKey];
	[manifest setObject:_created != nil ? _created : [NSDate date] forKey:ABLManifestCreatedKey];
	[manifest setObject:_modified != nil ? _modified : [NSDate date] forKey:ABLManifestModifiedKey];
	[manifest setObject:[NSNumber numberWithUnsignedInteger:_roundCount] forKey:ABLManifestRoundCountKey];
	[manifest setObject:_lastMessage != nil ? _lastMessage : @"" forKey:ABLManifestLastMessageKey];
	return ABLWritePropertyList(manifest, [self manifestPath]);
}

- (NSMutableArray *)loadMessages {
	NSMutableArray *messages = [NSMutableArray array];
	for (NSUInteger index = 0; index < _roundCount; index++) {
		id round = ABLMutablePropertyListAtPath([self pathForRoundAtIndex:index]);
		if (![round isKindOfClass:[NSDictionary class]]) {
			continue; // one lost round, not a lost project
		}
		NSArray *rows = [round objectForKey:ABLRoundMessagesKey];
		if ([rows isKindOfClass:[NSArray class]]) {
			[messages addObjectsFromArray:rows];
		}
	}
	return messages;
}

- (BOOL)writeRoundAtIndex:(NSUInteger)index messages:(NSArray *)messages endReason:(NSString *)endReason {
	NSString *path = [self pathForRoundAtIndex:index];
	// Rewriting a round keeps the moment it opened; only a first write stamps
	// one. That is what makes the round survive the app being killed with a
	// real start time rather than the time it was recovered.
	NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
	NSDate *now = [NSDate date];
	NSDate *started = [existing objectForKey:ABLRoundStartedKey];
	if (![started isKindOfClass:[NSDate class]]) {
		started = now;
	}

	NSDictionary *round = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithUnsignedInteger:index], ABLRoundIndexKey,
		started, ABLRoundStartedKey,
		now, ABLRoundFinishedKey,
		endReason, ABLRoundEndReasonKey,
		messages, ABLRoundMessagesKey,
		nil];
	if (!ABLWritePropertyList(round, path)) {
		return NO;
	}

	if (index + 1 > _roundCount) {
		_roundCount = index + 1;
	}
	[_modified release];
	_modified = [now retain];
	NSString *subtitle = ABLSubtitleForMessages(messages);
	if ([subtitle length] > 0) {
		[_lastMessage release];
		_lastMessage = [subtitle copy];
	}
	return [self saveManifest];
}

- (void)dealloc {
	[_uuid release];
	[_name release];
	[_directory release];
	[_created release];
	[_modified release];
	[_lastMessage release];
	[super dealloc];
}

@end
