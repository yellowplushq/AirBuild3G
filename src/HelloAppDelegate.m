#import "HelloAppDelegate.h"
#import "ABLBootstrap.h"
#import "ABLChatViewController.h"
#import "ABLConfig.h"
#import "ABLOnboardingViewController.h"
#import "ABLProject.h"
#import "ABLProjectListViewController.h"
#import "ABLProjectStore.h"

// The project whose transcript was on screen when the app last stopped, or nil
// — because it was never opened, because the list was the last thing showing,
// or because the project has since been deleted.
static ABLProject *ABLRememberedProject(void) {
	NSString *uuid = [[NSUserDefaults standardUserDefaults] stringForKey:ABLDefaultsOpenProjectKey];
	if ([uuid length] == 0) {
		return nil;
	}
	return [ABLProject projectWithDirectory:
		[[ABLProjectStore projectsDirectory] stringByAppendingPathComponent:uuid]];
}

@implementation HelloAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
	// Read before anything is on screen: the project list clears this key as
	// soon as it appears, which is how going back to it means "nothing is
	// open" rather than "restore me next time".
	ABLProject *remembered = ABLRememberedProject();

	// /var/airbuild and a projects directory this app can write as itself.
	// Installing the payload package hands /var/airbuild back to root every
	// time, and AirBuild is not root any more.
	[ABLProjectStore prepare];

	_window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	_viewController = [[ABLProjectListViewController alloc] init];
	_navigationController = [[UINavigationController alloc] initWithRootViewController:_viewController];

	// -setRootViewController: is iOS 4.0 and newer. The 3.x fallback keeps the
	// app runnable anywhere that implements only the 2.x/3.0 API surface.
	if ([_window respondsToSelector:@selector(setRootViewController:)]) {
		[_window setRootViewController:_navigationController];
	} else {
		[_window addSubview:[_navigationController view]];
	}
	[_window makeKeyAndVisible];

	// The screen stays awake for as long as AirBuild is in front. An install
	// is twenty minutes of dpkg and a build is minutes of gcc, both of them
	// driven from this process — letting the display sleep suspends the work
	// and drops the Wi-Fi association the model is streaming over.
	[application setIdleTimerDisabled:YES];

	// A device that has never finished an install lands on the Environment page
	// with the project list already behind it, so the back button goes where a
	// back button should. Once the toolchain is in, launching goes straight to
	// the projects and Environment lives in Settings.
	if (![ABLBootstrap isReady]) {
		ABLOnboardingViewController *environment = [[ABLOnboardingViewController alloc] init];
		[_navigationController pushViewController:environment animated:NO];
		[environment release];
		return YES;
	}

	// iOS 4 has no background execution: leaving AirBuild for a phone call or
	// the home screen ends the process, and a 128 MB phone ends it sooner than
	// that. Coming back into the conversation that was open is the difference
	// between an app that was interrupted and one that was closed.
	if (remembered != nil) {
		ABLChatViewController *chat = [[ABLChatViewController alloc] initWithProject:remembered];
		[_navigationController pushViewController:chat animated:NO];
		[chat release];
	}
	return YES;
}

// Backgrounding clears the assertion by itself, but saying so is what keeps
// the phone sleeping normally once AirBuild is not the app in front.
- (void)applicationWillResignActive:(UIApplication *)application {
	[application setIdleTimerDisabled:NO];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	[application setIdleTimerDisabled:YES];
}

- (void)dealloc {
	[_navigationController release];
	[_viewController release];
	[_window release];
	[super dealloc];
}

@end
