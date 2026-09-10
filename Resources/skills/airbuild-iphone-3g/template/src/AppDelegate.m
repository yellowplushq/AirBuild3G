#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)options {
	_window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

	_root = [[RootViewController alloc] init];
	_navigation = [[UINavigationController alloc] initWithRootViewController:_root];

	// -setRootViewController: is iOS 4.0. Probe rather than assume, the way
	// everything else on this phone does for a 4.0-only selector, so the same
	// source still runs under a 3.x-era simulator.
	if ([_window respondsToSelector:@selector(setRootViewController:)]) {
		[_window setRootViewController:_navigation];
	} else {
		[_window addSubview:[_navigation view]];
	}

	[_window makeKeyAndVisible];
	return YES;
}

- (void)dealloc {
	[_root release];
	[_navigation release];
	[_window release];
	[super dealloc];
}

@end
