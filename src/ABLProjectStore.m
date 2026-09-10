#import "ABLProjectStore.h"
#import "ABLProject.h"
#import "ABLConfig.h"
#import "ABLPrivileged.h"
#import "ABLShell.h"

static NSString *ABLRootOverride = nil;

// Sorting is the store's business, not the project's, so it lives here.
@interface ABLProject (ABLProjectStoreSorting)
- (NSComparisonResult)compareByRecency:(ABLProject *)other;
@end

@implementation ABLProjectStore

+ (NSString *)root {
	return ABLRootOverride != nil ? ABLRootOverride : ABLDefaultRoot;
}

+ (void)setRoot:(NSString *)root {
	if (root == ABLRootOverride) {
		return;
	}
	[ABLRootOverride release];
	ABLRootOverride = [root copy];
}

+ (NSString *)projectsDirectory {
	return [[self root] stringByAppendingPathComponent:@"projects"];
}

+ (NSString *)scratchDirectory {
	NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"airbuild-scratch"];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory
		withIntermediateDirectories:YES attributes:nil error:NULL];
	return directory;
}

+ (BOOL)prepare {
	NSMutableString *log = [NSMutableString string];
	return ABLPrepareRoot([self root], log);
}

+ (NSArray *)projects {
	NSString *parent = [self projectsDirectory];
	NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:NULL];
	NSMutableArray *projects = [NSMutableArray arrayWithCapacity:[names count]];
	for (NSString *name in names) {
		if ([name hasPrefix:@"."]) {
			continue;
		}
		ABLProject *project = [ABLProject projectWithDirectory:[parent stringByAppendingPathComponent:name]];
		if (project != nil) {
			[projects addObject:project];
		}
	}
	[projects sortUsingSelector:@selector(compareByRecency:)];
	return projects;
}

+ (ABLProject *)createProjectNamed:(NSString *)name {
	NSString *parent = [self projectsDirectory];
	if (![[NSFileManager defaultManager] fileExistsAtPath:parent] && ![self prepare]) {
		return nil;
	}
	if (![[NSFileManager defaultManager] createDirectoryAtPath:parent
			withIntermediateDirectories:YES attributes:nil error:NULL]) {
		return nil;
	}
	return [ABLProject createProjectNamed:name inDirectory:parent];
}

+ (BOOL)deleteProject:(ABLProject *)project {
	NSString *directory = [project directory];
	// Refuse anything that is not one of ours. -removeItemAtPath: on a path
	// assembled from a bad manifest would be an unrecoverable mistake.
	if ([[directory stringByDeletingLastPathComponent] isEqualToString:[self projectsDirectory]] == NO) {
		return NO;
	}
	// The model builds as root, so a project holds directories this process
	// cannot empty as itself — the working tree it compiled in is the usual
	// one. The guard above is what makes handing the path to rm -rf as root
	// something other than reckless: it is a directory this class made, one
	// level below a directory this class owns.
	if (ABLHelperIsAvailable()) {
		NSString *output = ABLRunPrivilegedCommand(
			[@"rm -rf " stringByAppendingString:ABLShellQuote(directory)], nil);
		return !ABLOutputFailed(output);
	}
	return [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

@end

@implementation ABLProject (ABLProjectStoreSorting)

// Newest first, and a project that has never been written to still sorts by
// when it was made.
- (NSComparisonResult)compareByRecency:(ABLProject *)other {
	return [[other modified] compare:[self modified]];
}

@end
