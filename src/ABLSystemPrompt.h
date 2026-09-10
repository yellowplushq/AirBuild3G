#import <Foundation/Foundation.h>

@class ABLProject;

// The system prompt for one project: the device and clock as captured now, the
// project's absolute paths, the build environment's absolute paths, and every
// SKILL.md bundled with the app.
//
// Built when a project is opened rather than once per process, so the paths in
// it always belong to the project on screen.
NSString *ABLSystemPromptForProject(ABLProject *project);
