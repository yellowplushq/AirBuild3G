#import <UIKit/UIKit.h>

@class ABLProjectListViewController;

@interface HelloAppDelegate : NSObject <UIApplicationDelegate> {
	UIWindow *_window;
	ABLProjectListViewController *_viewController;
	UINavigationController *_navigationController;
}

@end
