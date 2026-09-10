#import <Foundation/Foundation.h>

@class ABLProject;

// Where projects live and how they are listed. One directory per project,
// named by its UUID; a directory without a readable manifest is skipped, so a
// half-written project never costs the list.
@interface ABLProjectStore : NSObject

// <root>/projects. Defaults to ABLDefaultRoot; the tests point it somewhere
// writable instead.
+ (NSString *)root;
+ (void)setRoot:(NSString *)root;
+ (NSString *)projectsDirectory;

// Where the scratch conversation's tool calls run: a directory under the
// app's temporary directory, made on demand. Nothing in it is a project and
// nothing in it is kept.
+ (NSString *)scratchDirectory;

// Makes the root and its projects directory exist and belong to the user the
// app runs as. Called once at launch and again before a project is made: the
// payload package owns /var/airbuild and puts it back under root every time it
// is installed, and the app is not root any more.
+ (BOOL)prepare;

// Newest activity first, which is the order the list wants.
+ (NSArray *)projects;

+ (ABLProject *)createProjectNamed:(NSString *)name;
+ (BOOL)deleteProject:(ABLProject *)project;

@end
