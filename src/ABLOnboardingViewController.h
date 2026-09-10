#import <UIKit/UIKit.h>
#import "ABLBootstrap.h"

// The Environment page: one grouped section per phase — Stash, Install,
// Ready — and one row per step, updated as the runner walks them.
//
// It is pushed automatically before the project list on a device that has
// never finished a run, and reachable from Settings afterwards.
//
// Pushed with -reinstall to run everything again, which is the repair path:
// an ordinary run skips whatever dpkg already reports as installed.
@interface ABLOnboardingViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, ABLBootstrapDelegate, UIAlertViewDelegate> {
	UITableView *_tableView;
	ABLBootstrap *_bootstrap;
	UIBarButtonItem *_installItem;
	UIBarButtonItem *_runningItem;
	NSString *_loadError;
	NSMutableDictionary *_headerMarks; // phase -> the mark its header last showed
}

// Starts a run that ignores every "already installed": for a toolchain that is
// damaged rather than missing. Call it after pushing the page.
- (void)reinstall;

@end
