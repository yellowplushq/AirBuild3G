#import <UIKit/UIKit.h>

@class ABLChatClient;
@class ABLLogViewController;
@class ABLProject;

// One project's transcript: a table of rows with an input bar that follows the
// keyboard, the way Messages did on iOS 4.
//
// The transcript is both the view model and the wire payload, and it is
// persisted a round at a time — one user message plus everything the assistant
// produced until it stopped — into the project's conversation directory.
@interface ABLChatViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate,
	UIActionSheetDelegate, UINavigationControllerDelegate, UIImagePickerControllerDelegate> {
	UITableView *_tableView;
	UIView *_inputBar;
	UITextField *_inputField;
	UIButton *_sendButton;
	UIButton *_photoButton;  // left of the field: take or choose a photo
	NSData *_pendingImage;   // JPEG waiting to go out with the next message
	NSData *_pendingThumbnail;
	NSString *_pendingPhotoPath;   // where that JPEG was saved, relative to the project directory
	// The thinking page on screen, if any, and the row it shows — so a reply
	// still streaming keeps updating it.
	ABLLogViewController *_detailPage;   // an abridged row, opened in full
	NSMutableDictionary *_detailRow;
	UIBarButtonItem *_loadingItem;
	UIBarButtonItem *_cleanupItem; // right slot when idle: compact or start over
	BOOL _compacting;              // the reply in flight is a summary, not a turn
	ABLProject *_project;
	NSMutableArray *_messages;
	NSString *_systemPrompt; // frozen when the project opens; prepended to every request
	ABLChatClient *_client;
	NSTimer *_transcriptTimer;
	// One cached wrapped body height per row, kept the same length as
	// _messages. Measuring a row costs a full text layout of its content, and
	// an empty -beginUpdates/-endUpdates asks for every row's height — five
	// times a second while a reply streams. A transcript of any size cannot
	// afford to remeasure itself that often on a 3G, and the measurement
	// allocates. Only the last row ever changes, so only the last entry is
	// ever thrown away. Dropped whole on a memory warning.
	NSMutableArray *_bodyHeights;
	// Which rows of _messages the table shows, in order. The transcript is
	// also the wire payload, so it holds rows a reader has no use for: an
	// assistant turn that went straight to a tool is an empty row carrying
	// the calls, and drawing it would be a blank bubble above the result.
	// Rebuilt whenever the table is reloaded, which is the only moment the
	// mapping can change.
	NSMutableArray *_visibleRows;
	BOOL _transcriptNeedsRefresh;
	BOOL _loading;
	NSUInteger _turn;
	NSUInteger _loopCount;
	// The round being written: where in _messages it began, which file it is,
	// and whether one is open at all.
	NSUInteger _roundStart;
	NSUInteger _roundIndex;
	BOOL _roundOpen;
	BOOL _didRestoreScroll; // a reopened transcript is scrolled to its tail once
}

- (id)initWithProject:(ABLProject *)project;

@end
