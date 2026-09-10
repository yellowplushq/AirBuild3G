#import <UIKit/UIKit.h>

// Grouped Settings page: the endpoint this phone talks to, whether to accept
// any certificate on the way there, and the build environment.
//
// The three endpoint fields are the whole of this app's configuration. There
// is no account and no server of ours in the middle: what is typed here is
// what the phone sends its requests to, with the key typed here as the bearer
// token. Everything lives in NSUserDefaults and never leaves the device
// except as that one Authorization header.
@interface ABLSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate, UITextFieldDelegate> {
	UITableView *_tableView;
	UITextField *_baseField;
	UITextField *_keyField;
	UITextField *_modelField;
}

@end
