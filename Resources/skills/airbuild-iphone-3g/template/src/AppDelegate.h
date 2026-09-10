#import <UIKit/UIKit.h>

@class RootViewController;

// Manual retain/release: this toolchain is GCC 4.2 and has no ARC.
@interface AppDelegate : NSObject <UIApplicationDelegate> {
	UIWindow *_window;
	UINavigationController *_navigation;
	RootViewController *_root;
}

@end
