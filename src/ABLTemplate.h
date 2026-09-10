#import <Foundation/Foundation.h>

// The single-view app template that ships in the bundle, copied into a new
// project's working tree with its placeholders resolved.
//
// A project used to start empty, so the first turn of every conversation went
// on writing a Makefile and a main.m from scratch — on a phone where a turn is
// sixteen tool rounds and a round trip is seconds. The template already gets
// right the things that fail at runtime rather than at compile time here
// (manual retain/release, no blocks, iOS 4.0 selectors, a URL scheme so uiopen
// works, gzip debs), so it is copied in when the project is made and the model
// starts from a tree that builds.

// Copies <bundle>/skills/airbuild-iphone-3g/template into `workingDirectory`
// and replaces __NAME__, __BUNDLE__ and __SCHEME__ throughout, once. Returns
// the app name it settled on, or nil with `error` set.
//
// Refuses a working directory that already holds a Makefile or a src/: a
// second seeding would overwrite the model's work.
NSString *ABLSeedProjectTemplate(NSString *workingDirectory, NSString *projectName,
	NSString **error);

// The identifiers a project name turns into: "Tip Calc" -> "TipCalc",
// "com.airbuild.tipcalc", "tipcalc". Exported for the tests.
NSString *ABLTemplateAppName(NSString *projectName);
NSString *ABLTemplateScheme(NSString *projectName);
NSString *ABLTemplateBundleIdentifier(NSString *projectName);
