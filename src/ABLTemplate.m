#import "ABLTemplate.h"

static NSString *const ABLTemplateSubpath = @"skills/airbuild-iphone-3g/template";

// Kept as its own file, because it is the one thing in the template tree that
// is addressed to a person reading the repository rather than to the model.
static NSString *const ABLTemplateOmitted = @"README.md";

// Everything outside [A-Za-z0-9] goes: this becomes CFBundleExecutable, a
// Makefile variable and the name of a binary, and a project called
// "Tip Calc (v2)" must not produce any of the three with a space in it.
NSString *ABLTemplateAppName(NSString *projectName) {
	NSMutableString *name = [NSMutableString string];
	NSUInteger length = [projectName length];
	for (NSUInteger i = 0; i < length; i++) {
		unichar c = [projectName characterAtIndex:i];
		if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
			[name appendFormat:@"%C", c];
		}
	}
	// A leading digit is a legal file name and an illegal C identifier; the
	// template uses the name in neither, but a bundle identifier component
	// that starts with one is refused by some tools, so prefix it.
	if ([name length] == 0) {
		return @"App";
	}
	unichar first = [name characterAtIndex:0];
	return (first >= '0' && first <= '9') ? [@"App" stringByAppendingString:name] : name;
}

NSString *ABLTemplateScheme(NSString *projectName) {
	return [ABLTemplateAppName(projectName) lowercaseString];
}

NSString *ABLTemplateBundleIdentifier(NSString *projectName) {
	return [@"com.airbuild." stringByAppendingString:ABLTemplateScheme(projectName)];
}

// One pass over one file. Text only: the template has no binary in it today,
// and quietly rewriting one if it ever does would be worse than leaving it.
static void ABLResolvePlaceholders(NSString *path, NSDictionary *values) {
	NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
	if (text == nil) {
		return;
	}
	NSString *resolved = text;
	for (NSString *placeholder in values) {
		resolved = [resolved stringByReplacingOccurrencesOfString:placeholder
			withString:[values objectForKey:placeholder]];
	}
	if (![resolved isEqualToString:text]) {
		[resolved writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	}
}

NSString *ABLSeedProjectTemplate(NSString *workingDirectory, NSString *projectName,
		NSString **error) {
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *template = [[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:ABLTemplateSubpath];
	if (![files fileExistsAtPath:template]) {
		if (error != NULL) {
			*error = @"The app template is missing. Reinstall AirBuild to restore it.";
		}
		return nil;
	}
	for (NSString *taken in [NSArray arrayWithObjects:@"Makefile", @"src", nil]) {
		if ([files fileExistsAtPath:[workingDirectory stringByAppendingPathComponent:taken]]) {
			if (error != NULL) {
				*error = @"This project already has source in it.";
			}
			return nil;
		}
	}

	NSArray *entries = [files contentsOfDirectoryAtPath:template error:NULL];
	for (NSString *name in entries) {
		if ([name hasPrefix:@"."] || [name isEqualToString:ABLTemplateOmitted]) {
			continue;
		}
		NSString *destination = [workingDirectory stringByAppendingPathComponent:name];
		if (![files copyItemAtPath:[template stringByAppendingPathComponent:name]
				toPath:destination error:NULL]) {
			if (error != NULL) {
				*error = [NSString stringWithFormat:@"Could not copy %@ into the project.", name];
			}
			return nil;
		}
	}

	NSString *appName = ABLTemplateAppName(projectName);
	NSDictionary *values = [NSDictionary dictionaryWithObjectsAndKeys:
		appName, @"__NAME__",
		ABLTemplateBundleIdentifier(projectName), @"__BUNDLE__",
		ABLTemplateScheme(projectName), @"__SCHEME__", nil];
	// Every file, not the three new-app.sh knew about: the substitution is
	// harmless where the placeholders do not appear, and a template that grows
	// a fourth file must not need this list edited to go with it.
	NSDirectoryEnumerator *enumerator = [files enumeratorAtPath:workingDirectory];
	for (NSString *relative in enumerator) {
		if ([[[enumerator fileAttributes] objectForKey:NSFileType] isEqualToString:NSFileTypeRegular]) {
			ABLResolvePlaceholders([workingDirectory stringByAppendingPathComponent:relative], values);
		}
	}
	return appName;
}
