#import "ABLRepoDigest.h"

const NSUInteger ABLRepoDigestFileLimit = 24 * 1024;

// Trees that are output rather than source. Matched on a whole path
// component, so a directory called "build" is skipped and a file called
// "rebuild.sh" is not.
static NSString *const ABLSkippedDirectories[] = {
	@".git", @".svn", @"build", @"obj", @"layout", @".theos", nil
};

static BOOL ABLIsSkippedDirectory(NSString *name) {
	for (NSUInteger i = 0; ABLSkippedDirectories[i] != nil; i++) {
		if ([name isEqualToString:ABLSkippedDirectories[i]]) {
			return YES;
		}
	}
	return NO;
}

// Text, for the purpose of quoting it into a prompt: no NUL bytes and valid
// UTF-8. A .png quoted into the system prompt is 40 KB of mojibake the model
// then has to reason around.
static NSString *ABLTextContents(NSString *path) {
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (data == nil) {
		return nil;
	}
	const unsigned char *bytes = [data bytes];
	NSUInteger length = [data length];
	NSUInteger scan = length < 4096 ? length : 4096;
	for (NSUInteger i = 0; i < scan; i++) {
		if (bytes[i] == 0) {
			return nil;
		}
	}
	return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

NSString *ABLRepoDigest(NSString *root, NSUInteger budget) {
	NSFileManager *files = [NSFileManager defaultManager];
	BOOL isDirectory = NO;
	if (![files fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) {
		return @"";
	}

	NSDirectoryEnumerator *enumerator = [files enumeratorAtPath:root];
	NSMutableArray *paths = [NSMutableArray array];
	NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
	unsigned long long total = 0;
	for (NSString *relative in enumerator) {
		NSString *name = [relative lastPathComponent];
		NSDictionary *attributes = [enumerator fileAttributes];
		NSString *type = [attributes objectForKey:NSFileType];
		if ([type isEqualToString:NSFileTypeDirectory]) {
			if ([name hasPrefix:@"."] || ABLIsSkippedDirectory(name)) {
				[enumerator skipDescendants];
			}
			continue;
		}
		if (![type isEqualToString:NSFileTypeRegular] || [name hasPrefix:@"."]) {
			continue;
		}
		unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
		[paths addObject:relative];
		[sizes setObject:[NSNumber numberWithUnsignedLongLong:size] forKey:relative];
		total += size;
	}
	if ([paths count] == 0) {
		return @"";
	}
	[paths sortUsingSelector:@selector(compare:)];

	NSMutableString *out = [NSMutableString string];
	[out appendFormat:@"%lu files, %llu KB.\n\n", (unsigned long)[paths count],
		(total + 1023) / 1024];
	for (NSString *relative in paths) {
		[out appendFormat:@"  %@ (%llu B)\n", relative,
			[[sizes objectForKey:relative] unsignedLongLongValue]];
	}

	NSUInteger omitted = 0;
	for (NSString *relative in paths) {
		if ([[sizes objectForKey:relative] unsignedLongLongValue] > ABLRepoDigestFileLimit) {
			omitted++;
			continue;
		}
		NSString *text = ABLTextContents([root stringByAppendingPathComponent:relative]);
		if (text == nil) {
			omitted++;   // binary, or unreadable
			continue;
		}
		// The whole file or none of it. Half a Makefile in a prompt is worse
		// than a line saying the tree did not fit: the model cannot tell that
		// the rest exists.
		if ([out length] + [text length] + [relative length] + 32 > budget) {
			omitted++;
			continue;
		}
		[out appendFormat:@"\n=== %@ ===\n%@", relative, text];
		if (![text hasSuffix:@"\n"]) {
			[out appendString:@"\n"];
		}
	}
	if (omitted > 0) {
		[out appendFormat:@"\n(%lu file%@ listed above but not quoted here — too "
			@"large, binary, or past the size this listing is allowed. Read them "
			@"with Execute if you need them.)\n",
			(unsigned long)omitted, omitted == 1 ? @"" : @"s"];
	}
	return out;
}
