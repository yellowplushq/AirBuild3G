#import <UIKit/UIKit.h>

@class ABLChatViewController;

// The app's root screen: every project on the device, newest activity first.
// Settings (the gear) is the top-left button; top-right is a pair — the
// scratch conversation and a new project.
@interface ABLProjectListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate> {
	UITableView *_tableView;
	NSArray *_projects;
	NSUInteger _pendingDeletionRow;
	// The chat/+ pair and the spinner that stands in for it while a project
	// is being made. Making one copies the app template in and resolves its
	// placeholders, which is a few dozen file operations — fast, but not
	// instant on a 3G, and it happens with the list already back on screen.
	UIBarButtonItem *_actionsItem;
	UIBarButtonItem *_creatingItem;
	BOOL _creating;
	// The scratch conversation: one per process, kept here so coming back to
	// it shows the same transcript, and gone with the process — it has no
	// project and writes nothing to disk.
	ABLChatViewController *_scratchChat;
}

// Creates the project, seeds it from the bundled app template, opens it and
// pushes its transcript. Returns immediately: the work runs on a thread of its
// own with a progress indicator in the top-right slot. Called by the New
// Project page once it has a name.
- (void)createProjectNamed:(NSString *)name;

@end
