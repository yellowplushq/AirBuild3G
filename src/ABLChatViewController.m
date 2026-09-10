#import "ABLChatViewController.h"
#import "ABLChatClient.h"
#import "ABLConfig.h"
#import "ABLLogViewController.h"
#import "ABLProject.h"
#import "ABLShell.h"
#import "ABLProjectStore.h"
#import "ABLSystemPrompt.h"
#import "ABLTools.h"

static const CGFloat ABLInputBarHeight = 44.0f;
static const CGFloat ABLCellPadding = 8.0f;
static const CGFloat ABLRoleLabelHeight = 16.0f;
static const NSUInteger ABLHistoryLimit = 20;
static const NSUInteger ABLToolLoopLimit = 16;
static const CGFloat ABLBodyFontSize = 15.0f;
static const CGFloat ABLTerminalFontSize = 13.0f;
static const NSInteger ABLRoleLabelTag = 1;
static const NSInteger ABLBodyLabelTag = 2;
static const NSInteger ABLPhotoViewTag = 3;   // first of ABLPhotosPerRow consecutive tags
static const NSInteger ABLPhotosPerRow = 3;
// A photo goes to the model at most this many pixels on its long edge: enough
// for it to read, small enough that a 3G can encode and upload it. The
// transcript keeps a separate thumbnail so a row never decodes the full one.
static const CGFloat ABLPhotoSendEdge = 640.0f;
// And at most this many bytes as JPEG. A 640-pixel camera frame at quality
// 0.7 came out at 85 KB, which is 113 KB as base64 and a minute of a 3G's
// upload for every turn it is re-sent with. Quality steps down, then the
// edge, until the photo fits.
static const NSUInteger ABLPhotoSendBytes = 64 * 1024;
// The transcript draws every photo as an ABLPhotoSquare square on a 320-point
// screen with no scale factor, so a thumbnail wider than that is bytes stored,
// decoded and thrown away. A little headroom over the square is all
// scale-aspect-fill needs.
static const CGFloat ABLPhotoThumbnailEdge = 96.0f;
static const CGFloat ABLPhotoSquare = 80.0f;   // every photo is shown as this square
static const CGFloat ABLPhotoGap = 6.0f;
static const CGFloat ABLPhotoButtonWidth = 36.0f;
static const NSUInteger ABLPhotosResent = 2;
static const NSInteger ABLPhotoSheetTag = 1;
static const NSInteger ABLCleanupSheetTag = 2;
static NSString *ABLCompactPrompt = @"Summarize this conversation so far for your own later use. Cover what the user asked for, what has been done (files, commands, results), what remains, and any decisions or constraints. Be concise and concrete. Reply with the summary only.";   // newest photos re-uploaded with every request
// A streamed reply grows its row's content string on every token; the table is
// remeasured and rescrolled on this interval instead. A 3G cannot remeasure and
// rescroll a table at token rate.
static const NSTimeInterval ABLTranscriptRefreshInterval = 0.2;
// The tallest a row's body may be. 64 KB of command output is thousands of
// lines; a label that tall is tens of megabytes of backing store on a 128 MB
// phone. Prose has always been capped here — so is the terminal now.
static const CGFloat ABLMaximumBodyHeight = 4000.0f;
// A reply's thinking shows this many lines in the transcript; the rest is a
// disclosure away. Room is kept on the right for that indicator whether or
// not it is drawn, so the row does not rewrap when it appears.
// Thinking and command output are both abridged to this many lines in the
// transcript; the row answers a tap with the whole thing. The model still
// receives every byte — this bounds the label, not the transcript.
static const NSInteger ABLAbridgedLines = 3;
// How much of a thinking row is ever looked at. It is drawn as at most
// ABLAbridgedLines and its ends are all that is shown, so measuring or
// scanning the whole reasoning block is work thrown away — and it was thrown
// away five times a second, on a string the model was still appending to.
// Past this many characters the height is the cap whatever the text says:
// three lines hold well under a hundred at this width, and a word too long
// for a line is wrapped rather than left to overflow.
//
// Measured on the 3G before this existed: a reasoning block that reached
// 59 KB held the app at 86% CPU while it streamed and 7% the moment it
// stopped growing, because every refresh laid out all 59 KB to draw 3 lines.
static const NSUInteger ABLThinkingWindow = 512;
static const CGFloat ABLDisclosureWidth = 24.0f;
// How far from the bottom still counts as following the reply, measured before
// the row grows, so it only has to absorb rounding.
static const CGFloat ABLTailSlack = 4.0f;

@interface ABLChatViewController () <ABLChatClientDelegate>

@end

// Lines a command printed. Scanned rather than split: 64 KB of output would
// otherwise become an array of thousands of strings just to be counted.
static NSInteger ABLLineCount(NSString *content) {
	NSUInteger length = [content length];
	// Command output almost always ends in a newline; it closes the last line
	// rather than opening a blank one.
	if (length > 0 && [content characterAtIndex:length - 1] == '\n') {
		length--;
	}
	NSUInteger start = 0;
	NSInteger lines = 1;
	while (start < length) {
		NSRange found = [content rangeOfString:@"\n" options:NSLiteralSearch
			range:NSMakeRange(start, length - start)];
		if (found.location == NSNotFound) {
			break;
		}
		lines++;
		start = NSMaxRange(found);
	}
	return lines;
}

// The first row of an empty transcript. Short: it is read once, on a small
// screen, and the model is one message away.
static NSString *ABLWelcomeMessage(ABLProject *project) {
	NSMutableString *text = [NSMutableString stringWithString:project != nil
		? @"Welcome to AirBuild. Say what the app should do, and it gets written, built and installed on this iPhone."
		: @"Welcome to AirBuild. This is a scratch conversation: ask anything here; it is not kept once AirBuild closes. Apps are built from a project on the list."];
	if ([[[NSUserDefaults standardUserDefaults] stringForKey:ABLDefaultsAPIKeyKey] length] == 0) {
		[text appendString:@"\n\nThere is no API key yet. Put one in Settings first — this build talks to your own endpoint with your own key."];
	}
	return text;
}

@implementation ABLChatViewController

// The transcript, the client and the round bookkeeping are built here rather
// than in -loadView. -loadView runs again whenever a memory warning unloads the
// view of an off-screen controller, and this page spends its time with a
// thinking or output page pushed on top of it — so building them there leaked
// the whole previous transcript and left a second ABLChatClient streaming into
// an array nobody was reading any more.
- (id)initWithProject:(ABLProject *)project {
	self = [super initWithNibName:nil bundle:nil];
	if (self != nil) {
		_project = [project retain];
		// Per project open, not per process: the prompt names this project's
		// absolute paths, so it cannot outlive the project on screen.
		_systemPrompt = [ABLSystemPromptForProject(project) copy];
		_messages = [[_project loadMessages] retain];
		if (_messages == nil) {
			_messages = [[NSMutableArray alloc] init];
		}
		// An empty transcript opens with a word from the app. A system row
		// is drawn but never sent — the request builder skips the role — and
		// it sits before _roundStart, so it is never written to disk either:
		// a project that has had a conversation opens on that instead.
		if ([_messages count] == 0) {
			[_messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:
				@"system", @"role", ABLWelcomeMessage(project), @"content", nil]];
		}
		[self forgetOldPhotoData];
		[self restoreTerminalRowFlags];
		_bodyHeights = [[NSMutableArray alloc] init];
		_visibleRows = [[NSMutableArray alloc] init];
		[self rebuildVisibleRows];
		_roundIndex = [_project roundCount];
		_roundStart = [_messages count];
		_client = [[ABLChatClient alloc] init];
		[_client setDelegate:self];
	}
	return self;
}

// A reopened project has every photo it ever carried in memory at full send
// size. Only the newest ABLPhotosResent are ever uploaded again, and the
// transcript draws thumbnails rather than these, so the rest are dead weight —
// tens of kilobytes each, and they are what a long project pays for reopening.
// The bytes stay in the round files on disk; only this copy is released, and
// the row is marked so a request still says a photo was there.
- (void)forgetOldPhotoData {
	NSUInteger kept = 0;
	for (NSUInteger i = [_messages count]; i > 0; i--) {
		NSMutableDictionary *message = [_messages objectAtIndex:i - 1];
		if (![[message objectForKey:@"image"] isKindOfClass:[NSData class]]) {
			continue;
		}
		if (kept < ABLPhotosResent) {
			kept++;
			continue;
		}
		[message removeObjectForKey:@"image"];
		[message setObject:[NSNumber numberWithBool:YES] forKey:@"image_dropped"];
	}
}

// Rows written by an older build have the line count but not the failed flag,
// and a row that reaches the table without one would have its 64 KB of output
// scanned for the exit suffix on every pass. Filled in once, here.
- (void)restoreTerminalRowFlags {
	for (NSMutableDictionary *message in _messages) {
		if (![self isTerminalRole:[message objectForKey:@"role"]]) {
			continue;
		}
		NSString *content = [message objectForKey:@"content"];
		if ([message objectForKey:@"line_count"] == nil) {
			[message setObject:[NSNumber numberWithInteger:ABLLineCount(content)] forKey:@"line_count"];
		}
		if ([message objectForKey:@"failed"] == nil) {
			[message setObject:[NSNumber numberWithBool:ABLOutputFailed(content)] forKey:@"failed"];
		}
	}
}

- (void)loadView {
	// Released first, and every one of these is nil-checked nowhere else: a
	// memory warning unloads this view while a pushed page is on screen, and
	// -loadView then runs a second time. Assigning straight over the ivars
	// leaked a whole table and input bar each time it happened.
	[self releaseViewOwnedObjects];

	UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
	[view setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[view setBackgroundColor:[UIColor whiteColor]];
	CGRect bounds = [view bounds];

	_tableView = [[UITableView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, bounds.size.width, bounds.size.height - ABLInputBarHeight) style:UITableViewStylePlain];
	[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[_tableView setDataSource:self];
	[_tableView setDelegate:self];
	[_tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
	[_tableView setSeparatorColor:[UIColor colorWithWhite:0.88f alpha:1.0f]];
	// An empty footer stops the plain table from ruling the empty space.
	UIView *footer = [[UIView alloc] initWithFrame:CGRectZero];
	[_tableView setTableFooterView:footer];
	[footer release];
	// A tap anywhere in the transcript puts the keyboard away. Recognizers are
	// iOS 3.2 and newer. Where the class is absent the return key remains the
	// way out, so this degrades rather than crashing.
	Class recognizerClass = NSClassFromString(@"UITapGestureRecognizer");
	if (recognizerClass != nil) {
		UITapGestureRecognizer *tap = [[recognizerClass alloc] initWithTarget:self action:@selector(dismissKeyboard)];
		[tap setCancelsTouchesInView:NO]; // rows and scrolling still get the touch
		[_tableView addGestureRecognizer:tap];
		[tap release];
	}
	[view addSubview:_tableView];

	// Input bar: the flat grey strip with a rounded text field and a Send
	// button, as in Messages.
	_inputBar = [[UIView alloc] initWithFrame:CGRectMake(0.0f, bounds.size.height - ABLInputBarHeight, bounds.size.width, ABLInputBarHeight)];
	[_inputBar setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin];
	[_inputBar setBackgroundColor:[UIColor colorWithRed:0.86f green:0.87f blue:0.89f alpha:1.0f]];
	UIView *rule = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, bounds.size.width, 1.0f)];
	[rule setBackgroundColor:[UIColor colorWithWhite:0.65f alpha:1.0f]];
	[rule setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
	[_inputBar addSubview:rule];
	[rule release];

	_photoButton = [[UIButton buttonWithType:UIButtonTypeRoundedRect] retain];
	[_photoButton setFrame:CGRectMake(6.0f, 7.0f, ABLPhotoButtonWidth, 31.0f)];
	[_photoButton setAutoresizingMask:UIViewAutoresizingFlexibleRightMargin];
	[[_photoButton titleLabel] setFont:[UIFont boldSystemFontOfSize:20.0f]];
	[_photoButton addTarget:self action:@selector(choosePhoto) forControlEvents:UIControlEventTouchUpInside];
	[_inputBar addSubview:_photoButton];
	[self updatePhotoButton];

	CGFloat fieldX = 6.0f + ABLPhotoButtonWidth + 6.0f;
	_inputField = [[UITextField alloc] initWithFrame:CGRectMake(fieldX, 7.0f, bounds.size.width - fieldX - 70.0f, 31.0f)];
	[_inputField setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
	[_inputField setBorderStyle:UITextBorderStyleRoundedRect];
	[_inputField setFont:[UIFont systemFontOfSize:16.0f]];
	[_inputField setPlaceholder:@"Message"];
	[_inputField setReturnKeyType:UIReturnKeySend];
	[_inputField setEnablesReturnKeyAutomatically:YES];
	[_inputField setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter];
	[_inputField setDelegate:self];
	[_inputBar addSubview:_inputField];

	_sendButton = [[UIButton buttonWithType:UIButtonTypeRoundedRect] retain];
	[_sendButton setFrame:CGRectMake(bounds.size.width - 64.0f, 7.0f, 58.0f, 31.0f)];
	[_sendButton setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
	[_sendButton setTitle:@"Send" forState:UIControlStateNormal];
	[[_sendButton titleLabel] setFont:[UIFont boldSystemFontOfSize:15.0f]];
	[_sendButton addTarget:self action:@selector(sendOrStop) forControlEvents:UIControlEventTouchUpInside];
	[_inputBar addSubview:_sendButton];
	[view addSubview:_inputBar];

	[self setView:view];
	[view release];

	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	[spinner startAnimating];
	_loadingItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
	[spinner release];
	// No "more" system item in 4.0; a bordered text button carries the glyph.
	_cleanupItem = [[UIBarButtonItem alloc] initWithTitle:@"\u2022\u2022\u2022" style:UIBarButtonItemStyleBordered
		target:self action:@selector(cleanupConversation)];
	[[self navigationItem] setRightBarButtonItem:_cleanupItem];
	// The left slot is the back button to the project list; the right side is
	// the progress indicator's, and stopping is the Send button, which is where
	// the thumb already is.
	[self setTitle:_project != nil ? [_project name] : @"Chat"];
	[self reloadTranscript];
	// The bar reflects whatever the client is doing, which on a second
	// -loadView is a reply already in flight.
	[self setLoading:_loading];
}

// Everything -loadView builds, in one place, so unloading and rebuilding the
// view cannot leave half of it behind.
- (void)releaseViewOwnedObjects {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[_inputField setDelegate:nil];
	[_inputField release];
	_inputField = nil;
	[_inputBar release];
	_inputBar = nil;
	[_sendButton release];
	_sendButton = nil;
	[_photoButton release];
	_photoButton = nil;
	[_loadingItem release];
	_loadingItem = nil;
	[_cleanupItem release];
	_cleanupItem = nil;
}

- (void)viewDidUnload {
	[self stopTranscriptRefresh];
	[self releaseViewOwnedObjects];
	[_bodyHeights removeAllObjects];
	// The rebuilt transcript is a fresh table at the top of a conversation the
	// reader was at the end of, so the one-shot scroll to the tail is owed
	// again.
	_didRestoreScroll = NO;
	[super viewDidUnload];
}

// The transcript itself is the conversation and cannot be dropped, but
// everything measured from it can be worked out again.
- (void)didReceiveMemoryWarning {
	[_bodyHeights removeAllObjects];
	[super didReceiveMemoryWarning];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// Which conversation to come back into. Written here rather than on the
	// way out because the way out is also how a killed process leaves, and it
	// never gets there. The scratch conversation has nothing to come back
	// to: the list cleared the key, and it stays cleared.
	if (_project != nil) {
		[[NSUserDefaults standardUserDefaults] setObject:[_project uuid]
			forKey:ABLDefaultsOpenProjectKey];
		[[NSUserDefaults standardUserDefaults] synchronize];
	}
	[self forgetDetailPage];
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
	[center addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
	// Resigning active covers backgrounding and the call/lock interruptions
	// that precede being killed, and both constants predate iOS 4 — which
	// UIApplicationDidEnterBackgroundNotification does not.
	[center addObserver:self selector:@selector(persistOpenRound) name:UIApplicationWillResignActiveNotification object:nil];
	[center addObserver:self selector:@selector(persistOpenRound) name:UIApplicationWillTerminateNotification object:nil];
	// The welcome row says whether a key has been entered yet, and Settings is
	// where it gets entered — so redraw it on the way back in.
	[self refreshWelcomeRow];
	if (_loading) {
		[self startTranscriptRefresh];
	}
	// A reopened project starts at the end of its transcript. Only the first
	// appearance: coming back from a pushed page must not throw away where the
	// reader had scrolled to.
	if (!_didRestoreScroll) {
		_didRestoreScroll = YES;
		[self scrollToBottomAnimated:NO];
	}
}

// Only the opening word from the app is ever replaced: a transcript that has
// been spoken into starts with the user's row, not this one.
- (void)refreshWelcomeRow {
	if ([_messages count] == 0) {
		return;
	}
	NSDictionary *first = [_messages objectAtIndex:0];
	if (![[first objectForKey:@"role"] isEqualToString:@"system"] || [first objectForKey:@"boundary"] != nil) {
		return;
	}
	NSString *welcome = ABLWelcomeMessage(_project);
	if ([welcome isEqualToString:[first objectForKey:@"content"]]) {
		return;
	}
	[_messages replaceObjectAtIndex:0 withObject:[NSDictionary dictionaryWithObjectsAndKeys:
		@"system", @"role", welcome, @"content", nil]];
	[self reloadTranscript];
}

// The timer retains this controller, so leaving it running past the screen
// would make -dealloc unreachable in exactly the case that matters: popped
// mid-reply. The reply keeps streaming into the transcript either way; only
// the redraw of an off-screen table stops.
- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self stopTranscriptRefresh];
	[self persistOpenRound];
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)notification {
	NSDictionary *info = [notification userInfo];
	CGRect keyboardFrame = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
	keyboardFrame = [[self view] convertRect:keyboardFrame fromView:nil];
	CGRect bounds = [[self view] bounds];
	CGFloat overlap = MAX(0.0f, CGRectGetMaxY(bounds) - keyboardFrame.origin.y);
	if ([[notification name] isEqualToString:UIKeyboardWillHideNotification]) {
		overlap = 0.0f;
	}
	NSTimeInterval duration = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
	[UIView beginAnimations:@"keyboard" context:NULL];
	[UIView setAnimationDuration:duration];
	[UIView setAnimationCurve:(UIViewAnimationCurve)[[info objectForKey:UIKeyboardAnimationCurveUserInfoKey] intValue]];
	[_inputBar setFrame:CGRectMake(0.0f, bounds.size.height - overlap - ABLInputBarHeight, bounds.size.width, ABLInputBarHeight)];
	[_tableView setFrame:CGRectMake(0.0f, 0.0f, bounds.size.width, bounds.size.height - overlap - ABLInputBarHeight)];
	[UIView commitAnimations];
	[self scrollToBottomAnimated:YES];
}

#pragma mark - Actions

- (void)dismissKeyboard {
	[_inputField resignFirstResponder];
}

// The transcript only needs a heartbeat while a reply is streaming into it,
// so the timer lives exactly as long as the loading state does.
- (void)startTranscriptRefresh {
	if (_transcriptTimer != nil) {
		return;
	}
	_transcriptTimer = [[NSTimer timerWithTimeInterval:ABLTranscriptRefreshInterval
		target:self selector:@selector(refreshTranscriptIfNeeded) userInfo:nil repeats:YES] retain];
	// Common modes, so the reply keeps appearing while the transcript is scrolled.
	[[NSRunLoop mainRunLoop] addTimer:_transcriptTimer forMode:NSRunLoopCommonModes];
}

- (void)stopTranscriptRefresh {
	[_transcriptTimer invalidate];
	[_transcriptTimer release];
	_transcriptTimer = nil;
	[self refreshTranscriptIfNeeded]; // whatever arrived since the last tick
}

- (void)refreshTranscriptIfNeeded {
	if (!_transcriptNeedsRefresh) {
		return;
	}
	_transcriptNeedsRefresh = NO;
	[self refreshStreamingRow];
	if (_detailPage != nil && _detailRow == [_messages lastObject]) {
		[_detailPage updateText:[_detailRow objectForKey:@"content"]];
	}
}

- (void)setLoading:(BOOL)loading {
	_loading = loading;
	if (loading) {
		[self startTranscriptRefresh];
	} else {
		[self stopTranscriptRefresh];
	}
	[[self navigationItem] setRightBarButtonItem:(loading ? _loadingItem : _cleanupItem)];
	[_sendButton setTitle:(loading ? @"Stop" : @"Send") forState:UIControlStateNormal];
}

// Every row holds a mutable content string, so a streamed reply grows in place
// instead of rebuilding the row for each token.
- (NSMutableDictionary *)rowWithRole:(NSString *)role content:(NSString *)content {
	NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObjectsAndKeys:
		role, @"role", [NSMutableString stringWithString:content], @"content", nil];
	if ([self isTerminalRole:role]) {
		// Counted once, here: a command's output is appended whole and never
		// streamed into, and it is the one thing measured by its line count.
		// Whether it failed is settled here too — it decides the row's colour,
		// and asking the string again on every pass means scanning 64 KB of
		// output each time the row is drawn.
		[row setObject:[NSNumber numberWithInteger:ABLLineCount(content)] forKey:@"line_count"];
		[row setObject:[NSNumber numberWithBool:ABLOutputFailed(content)] forKey:@"failed"];
	}
	return row;
}

// A row the transcript carries for the request and has nothing to draw for:
// the assistant turn that produced only a tool call. Its calls are what the
// next request needs and its content is empty, so the row would be a titled
// blank above the result it asked for.
- (BOOL)isHiddenAtIndex:(NSUInteger)index {
	NSDictionary *message = [_messages objectAtIndex:index];
	return [[message objectForKey:@"role"] isEqualToString:@"assistant"]
		&& [[message objectForKey:@"content"] length] == 0
		&& [[message objectForKey:@"tool_calls"] count] > 0;
}

// The one place the table's rows and _messages are lined up. Called from
// -reloadTranscript, so a row can be appended or filled in without announcing
// itself here.
- (void)rebuildVisibleRows {
	[_visibleRows removeAllObjects];
	for (NSUInteger i = 0; i < [_messages count]; i++) {
		if (![self isHiddenAtIndex:i]) {
			[_visibleRows addObject:[NSNumber numberWithUnsignedInteger:i]];
		}
	}
}

- (NSUInteger)messageIndexForRow:(NSInteger)row {
	return [[_visibleRows objectAtIndex:(NSUInteger)row] unsignedIntegerValue];
}

// Redrawing everything satisfies whatever the growing row was still owed, so
// this is the one place the pending-refresh flag is cleared.
- (void)reloadTranscript {
	_transcriptNeedsRefresh = NO;
	[self invalidateLastBodyHeight];
	[self rebuildVisibleRows];
	[_tableView reloadData];
}

// Only the newest row is ever written to in place, so it is the only cached
// height that can go stale. The array is squared up against _messages on
// every read, which is what keeps an appended row from needing to announce
// itself here.
- (void)invalidateLastBodyHeight {
	if ([_bodyHeights count] > 0) {
		[_bodyHeights replaceObjectAtIndex:[_bodyHeights count] - 1 withObject:[NSNull null]];
	}
}

// The wrapped height of a row's body text, measured once. Terminal rows are
// not measured at all: their height is a line count times a line height.
- (CGFloat)bodyTextHeightAtIndex:(NSUInteger)index {
	NSUInteger count = [_messages count];
	while ([_bodyHeights count] > count) {
		[_bodyHeights removeLastObject];
	}
	while ([_bodyHeights count] < count) {
		[_bodyHeights addObject:[NSNull null]];
	}
	if (index >= count) {
		return 0.0f;
	}
	id cached = [_bodyHeights objectAtIndex:index];
	if (cached != [NSNull null]) {
		return (CGFloat)[cached doubleValue];
	}
	NSDictionary *message = [_messages objectAtIndex:index];
	NSString *content = [message objectForKey:@"content"];
	NSString *role = [message objectForKey:@"role"];
	CGFloat height = [content length] > 0
		? [self wrappedHeightForContent:content font:[self fontForRole:role]
			width:[self bodyWidthForRole:role]]
		: 0.0f;
	[_bodyHeights replaceObjectAtIndex:index withObject:[NSNumber numberWithDouble:(double)height]];
	return height;
}

- (void)appendMessageWithRole:(NSString *)role content:(NSString *)content {
	[_messages addObject:[self rowWithRole:role content:content]];
	[self reloadTranscript];
	[self scrollToBottomAnimated:YES];
}

// The row that is growing is redrawn in place. Reloading it instead would
// rebuild the cell while the table is already applying its new height, which
// is what leaves a row the right size showing the previous text.
// Whether the reader is still at the tail of the transcript. Asked before the
// growing row changes height, so it only has to absorb rounding — and answered
// NO while a drag is in progress, because the client delivers in common modes
// specifically so the reply keeps arriving while the transcript is scrolled.
- (BOOL)isFollowingTail {
	if ([_tableView isDragging] || [_tableView isDecelerating]) {
		return NO;
	}
	CGFloat bottom = [_tableView contentSize].height - [_tableView bounds].size.height;
	return [_tableView contentOffset].y >= bottom - ABLTailSlack;
}

- (void)refreshStreamingRow {
	NSUInteger count = [_visibleRows count];
	if (count == 0) {
		return;
	}
	BOOL following = [self isFollowingTail];
	NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)count - 1 inSection:0];
	UITableViewCell *cell = [_tableView cellForRowAtIndexPath:path];
	if (cell != nil) {
		[self configureCell:cell forRowAtIndex:[self messageIndexForRow:(NSInteger)count - 1]];
	}
	// An empty update block is how the table is told to ask for heights again
	// without rebuilding any cell. Unanimated: this is a redraw, not a change
	// the reader should see animate.
	[UIView setAnimationsEnabled:NO];
	[_tableView beginUpdates];
	[_tableView endUpdates];
	[UIView setAnimationsEnabled:YES];
	if (following) {
		[self scrollToBottomAnimated:NO];
	}
}

- (void)appendToken:(NSString *)token role:(NSString *)role {
	NSMutableDictionary *last = [_messages lastObject];
	// A row that has already made its tool calls is finished, whatever comes
	// next belongs to the turn after it — and growing into it would also make
	// a hidden row visible without the table being told.
	if (![[last objectForKey:@"role"] isEqualToString:role]
			|| [[last objectForKey:@"tool_calls"] count] > 0) {
		[self appendMessageWithRole:role content:token];
		return;
	}
	[[last objectForKey:@"content"] appendString:token];
	[self invalidateLastBodyHeight];
	_transcriptNeedsRefresh = YES;
}

- (void)scrollToBottomAnimated:(BOOL)animated {
	NSUInteger count = [_visibleRows count];
	if (count == 0) {
		return;
	}
	[_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)count - 1 inSection:0]
		atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (NSArray *)messagesForRequest {
	NSMutableArray *history = [NSMutableArray array];
	NSUInteger start = [self conversationStart];
	NSString *summary = nil;
	if (start > 0) {
		NSDictionary *boundary = [_messages objectAtIndex:start - 1];
		if ([[boundary objectForKey:@"summary"] boolValue]) {
			summary = [boundary objectForKey:@"content"];
		}
	}
	for (NSUInteger i = start; i < [_messages count]; i++) {
		NSDictionary *message = [_messages objectAtIndex:i];
		NSString *role = [message objectForKey:@"role"];
		if ([role isEqualToString:@"thinking"] || [role isEqualToString:@"system"]) {
			continue;
		}
		[history addObject:message];
	}
	// Only the newest photos are re-uploaded on each turn — a 3G cannot afford
	// twenty of them per request. Older ones keep their text and a note that
	// a photo was there, so "the pic above" still means something. The file
	// on disk outlives the upload: the path is how the model gets at the
	// bytes, pixels or not.
	NSUInteger photosKept = 0;
	for (NSUInteger i = [history count]; i > 0; i--) {
		NSDictionary *message = [history objectAtIndex:i - 1];
		BOOL hasImage = [[message objectForKey:@"image"] isKindOfClass:[NSData class]];
		NSString *path = [message objectForKey:@"photo_path"];
		// A photo whose bytes were released when the project was reopened is
		// still a photo that was there, and still earns the note below.
		if (!hasImage && path == nil && ![[message objectForKey:@"image_dropped"] boolValue]) {
			continue;
		}
		BOOL keep = hasImage && photosKept < ABLPhotosResent;
		if (keep) {
			photosKept++;
			if (path == nil) {
				continue;
			}
		}
		NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithDictionary:message];
		[copy removeObjectForKey:@"image_dropped"];
		[copy removeObjectForKey:@"thumbnails"];
		[copy removeObjectForKey:@"photo_path"];
		if (!keep) {
			[copy removeObjectForKey:@"image"];
		}
		NSString *note = path != nil
			? [NSString stringWithFormat:@"(Photo %@: saved as ../%@, relative to the project directory.)",
				keep ? @"attached" : @"was attached here", path]
			: @"(a photo was attached here)";
		NSString *text = [copy objectForKey:@"content"];
		[copy setObject:[text length] > 0 ? [text stringByAppendingFormat:@"\n%@", note] : note forKey:@"content"];
		[history replaceObjectAtIndex:i - 1 withObject:copy];
	}
	NSUInteger count = [history count];
	NSUInteger window = count > ABLHistoryLimit ? count - ABLHistoryLimit : 0;
	while (window > 0 && window < count && [[[history objectAtIndex:window] objectForKey:@"role"] isEqualToString:@"tool"]) {
		window--;
	}

	NSString *systemPrompt = _systemPrompt;
	if ([summary length] > 0) {
		systemPrompt = [NSString stringWithFormat:@"%@\n\nSummary of the conversation before this point (it was compacted):\n%@", _systemPrompt, summary];
	}
	NSMutableArray *payload = [NSMutableArray arrayWithCapacity:(count - window) + 1];
	[payload addObject:[NSDictionary dictionaryWithObjectsAndKeys:
		@"system", @"role", systemPrompt, @"content", nil]];
	[payload addObjectsFromArray:[history subarrayWithRange:NSMakeRange(window, count - window)]];
	return payload;
}

#pragma mark - Photos

// The button reads "+" until a photo is waiting, then "1" — the field's
// placeholder says what that means.
- (void)updatePhotoButton {
	BOOL pending = _pendingImage != nil;
	[_photoButton setTitle:pending ? @"1" : @"+" forState:UIControlStateNormal];
	[_inputField setPlaceholder:pending ? @"Add a message (photo attached)" : @"Message"];
}

// Redrawn into a bitmap of at most `edge` pixels on the long side. Drawing
// applies the camera's orientation flag, so the model sees the photo the way
// the screen does.
static UIImage *ABLScaledImage(UIImage *image, CGFloat edge) {
	CGSize size = [image size];
	CGFloat longest = size.width > size.height ? size.width : size.height;
	if (longest <= edge) {
		return image;   // already small enough; a redraw would only cost a bitmap
	}
	CGFloat scale = edge / longest;
	CGSize target = CGSizeMake(floorf(size.width * scale), floorf(size.height * scale));
	if (target.width < 1.0f || target.height < 1.0f) {
		return nil;
	}
	UIGraphicsBeginImageContext(target);
	[image drawInRect:CGRectMake(0.0f, 0.0f, target.width, target.height)];
	UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return scaled;
}

// The photo as JPEG within ABLPhotoSendBytes: quality steps down first, then
// the edge, each try re-encoding the already-scaled image rather than the
// camera frame. The smallest attempt is returned if none fits.
static NSData *ABLPhotoJPEG(UIImage *scaled) {
	const CGFloat qualities[] = { 0.7f, 0.5f, 0.35f };
	const CGFloat edges[] = { ABLPhotoSendEdge, 480.0f, 400.0f, 320.0f };
	NSData *best = nil;
	for (NSUInteger e = 0; e < sizeof(edges) / sizeof(edges[0]); e++) {
		UIImage *image = ABLScaledImage(scaled, edges[e]);
		if (image == nil) {
			break;
		}
		for (NSUInteger q = 0; q < sizeof(qualities) / sizeof(qualities[0]); q++) {
			NSData *jpeg = UIImageJPEGRepresentation(image, qualities[q]);
			if (jpeg == nil) {
				continue;
			}
			if ([jpeg length] <= ABLPhotoSendBytes) {
				return jpeg;
			}
			if (best == nil || [jpeg length] < [best length]) {
				best = jpeg;
			}
		}
	}
	return best;
}

// Saved beside the working tree, not in it — photos/ is the model's to read
// and copy from, not part of what it builds — under a name that counts up, so
// "photo-3.jpg" in a transcript still names the same file a week later.
// Returns the path relative to the project directory, or nil.
- (NSString *)savePhoto:(NSData *)jpeg {
	if (_project == nil) {
		return nil;
	}
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *directory = [[_project directory] stringByAppendingPathComponent:@"photos"];
	[files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
	NSUInteger index = 1;
	NSString *name, *path;
	do {
		name = [NSString stringWithFormat:@"photo-%lu.jpg", (unsigned long)index++];
		path = [directory stringByAppendingPathComponent:name];
	} while ([files fileExistsAtPath:path]);
	if (![jpeg writeToFile:path atomically:YES]) {
		return nil;
	}
	return [@"photos" stringByAppendingPathComponent:name];
}

- (void)choosePhoto {
	if (_loading) {
		return;
	}
	[_inputField resignFirstResponder];
	BOOL camera = [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self
		cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
	if (camera) {
		[sheet addButtonWithTitle:@"Take Photo"];
	}
	[sheet addButtonWithTitle:@"Choose Photo"];
	if (_pendingImage != nil) {
		[sheet setDestructiveButtonIndex:[sheet addButtonWithTitle:@"Remove Photo"]];
	}
	[sheet setCancelButtonIndex:[sheet addButtonWithTitle:@"Cancel"]];
	[sheet setTag:ABLPhotoSheetTag];
	[sheet showInView:[self view]];
	[sheet release];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
	if (index == [sheet cancelButtonIndex]) {
		return;
	}
	NSString *title = [sheet buttonTitleAtIndex:index];
	if ([sheet tag] == ABLCleanupSheetTag) {
		if ([title isEqualToString:@"Compact"]) {
			[self compactConversation];
		} else {
			[self startNewConversation];
		}
		return;
	}
	if ([title isEqualToString:@"Remove Photo"]) {
		if (_pendingPhotoPath != nil) {
			[[NSFileManager defaultManager] removeItemAtPath:
				[[_project directory] stringByAppendingPathComponent:_pendingPhotoPath] error:NULL];
		}
		[self setPendingImage:nil thumbnail:nil path:nil];
		return;
	}
	UIImagePickerController *picker = [[UIImagePickerController alloc] init];
	[picker setSourceType:[title isEqualToString:@"Take Photo"]
		? UIImagePickerControllerSourceTypeCamera : UIImagePickerControllerSourceTypePhotoLibrary];
	[picker setDelegate:self];
	[self presentModalViewController:picker animated:YES];
	[picker release];
}

- (void)setPendingImage:(NSData *)image thumbnail:(NSData *)thumbnail path:(NSString *)path {
	[image retain];
	[_pendingImage release];
	_pendingImage = image;
	[thumbnail retain];
	[_pendingThumbnail release];
	_pendingThumbnail = thumbnail;
	[path retain];
	[_pendingPhotoPath release];
	_pendingPhotoPath = path;
	[self updatePhotoButton];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
	UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
	[self dismissModalViewControllerAnimated:YES];
	if (image == nil) {
		return;
	}
	// The original is a camera frame: 2048x1536 on a 3GS, six megabytes once
	// UIKit has decoded it. It is scaled once, and the thumbnail comes from
	// the already-scaled copy rather than from the original — drawing the
	// original twice meant a second full-size decode and a second context
	// alive beside the first, which is the largest thing this app ever asks
	// of a 128 MB phone. The pool bounds how long the intermediates live.
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	UIImage *scaled = ABLScaledImage(image, ABLPhotoSendEdge);
	NSData *jpeg = scaled != nil ? [ABLPhotoJPEG(scaled) retain] : nil;
	UIImage *small = scaled != nil ? ABLScaledImage(scaled, ABLPhotoThumbnailEdge) : nil;
	NSData *thumbnail = small != nil ? [UIImageJPEGRepresentation(small, 0.8f) retain] : nil;
	[pool release];
	[jpeg autorelease];
	[thumbnail autorelease];
	if (jpeg == nil || thumbnail == nil) {
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Photo" message:@"That image could not be read."
			delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[alert show];
		[alert release];
		return;
	}
	[self setPendingImage:jpeg thumbnail:thumbnail path:[self savePhoto:jpeg]];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[self dismissModalViewControllerAnimated:YES];
}

#pragma mark - Compact / start over

// iOS 4 has no menu control; a bar button that needs a choice shows an action
// sheet, the way Mail's reply button does.
- (void)cleanupConversation {
	if (_loading) {
		return;
	}
	[_inputField resignFirstResponder];
	UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Compact this conversation or start a new one?"
		delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
	[sheet addButtonWithTitle:@"Compact"];
	[sheet addButtonWithTitle:@"Start New Conversation"];
	[sheet setCancelButtonIndex:[sheet addButtonWithTitle:@"Cancel"]];
	[sheet setTag:ABLCleanupSheetTag];
	[sheet showInView:[self view]];
	[sheet release];
}

// Index of the row after the last boundary — where the conversation the model
// sees begins.
- (NSUInteger)conversationStart {
	for (NSUInteger i = [_messages count]; i > 0; i--) {
		if ([[[_messages objectAtIndex:i - 1] objectForKey:@"boundary"] boolValue]) {
			return i;
		}
	}
	return 0;
}

// A boundary is a round of its own, so it is on disk like any turn.
- (NSMutableDictionary *)appendBoundaryWithContent:(NSString *)content summary:(BOOL)summary {
	_roundStart = [_messages count];
	_roundOpen = YES;
	NSMutableDictionary *row = [self rowWithRole:@"system" content:content];
	[row setObject:[NSNumber numberWithBool:YES] forKey:@"boundary"];
	if (summary) {
		[row setObject:[NSNumber numberWithBool:YES] forKey:@"summary"];
	}
	[_messages addObject:row];
	[self reloadTranscript];
	[self scrollToBottomAnimated:YES];
	return row;
}

- (void)startNewConversation {
	[self appendBoundaryWithContent:@"New conversation starts here." summary:NO];
	[self closeRoundWithEndReason:ABLRoundEndReasonComplete];
}

- (void)compactConversation {
	if ([self conversationStart] >= [_messages count]) {
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Nothing to Compact"
			message:@"There is no conversation since the last boundary." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[alert show];
		[alert release];
		return;
	}
	// The request is built before the boundary row exists, so the summary
	// request sees the conversation it is summarizing.
	NSMutableArray *request = [NSMutableArray arrayWithArray:[self messagesForRequest]];
	[request addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", ABLCompactPrompt, @"content", nil]];
	[self appendBoundaryWithContent:@"" summary:YES];
	_compacting = YES;
	_turn++;
	_loopCount = 0;
	[self setLoading:YES];
	[self persistOpenRound];
	[_client sendMessages:request];
}

- (void)finishCompactingWithError:(NSString *)error {
	NSMutableDictionary *row = [_messages lastObject];
	NSMutableString *content = [row objectForKey:@"content"];
	if (error != nil) {
		// Not a summary any more: the conversation before it stays in play.
		[row removeObjectForKey:@"summary"];
		[row removeObjectForKey:@"boundary"];
		[content setString:[NSString stringWithFormat:@"Unable to compact the conversation: %@", error]];
	} else if ([content length] == 0) {
		[content setString:@"No summary was produced."];
	}
	_compacting = NO;
	[self reloadTranscript];
	[self setLoading:NO];
	[self closeRoundWithEndReason:error != nil ? ABLRoundEndReasonError : ABLRoundEndReasonComplete];
}

#pragma mark - Rounds

// A round is one user message plus everything the assistant produced until it
// stopped: thinking, the reply, and every exec result along the way. It is
// written to its own file so a long transcript is never rewritten to record
// one more token, and rewritten in place at each boundary so closing it twice
// — or recovering it after a kill — costs nothing.
// Returns NO when the round could not be written — the model runs as root with
// the project directory as its working directory, so it can delete its own
// conversation/ folder, and losing a turn silently is worse than saying so.
- (BOOL)writeRoundWithEndReason:(NSString *)reason {
	NSUInteger count = [_messages count];
	if (_project == nil || !_roundOpen || _roundStart >= count) {
		return YES;   // nothing to write is not a failure
	}
	return [_project writeRoundAtIndex:_roundIndex
		messages:[_messages subarrayWithRange:NSMakeRange(_roundStart, count - _roundStart)]
		endReason:reason];
}

// The round on disk stays marked interrupted until something closes it, which
// is exactly what a round the app was killed during should say.
- (void)persistOpenRound {
	[self writeRoundWithEndReason:ABLRoundEndReasonInterrupted];
}

- (void)closeRoundWithEndReason:(NSString *)reason {
	if (!_roundOpen) {
		return;
	}
	BOOL wrote = [self writeRoundWithEndReason:reason];
	_roundOpen = NO;
	_roundStart = [_messages count];
	if (!wrote) {
		// The index deliberately does not advance: the next round reuses it
		// rather than leaving a hole, and the user is told the turn is not on
		// disk instead of finding out when they reopen the project.
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Unable to Save"
			message:@"This turn could not be written to the project. Check that the "
				@"project folder still exists and that there is free space."
			delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[alert show];
		[alert release];
		return;
	}
	_roundIndex++;
}

#pragma mark - Actions

- (void)sendOrStop {
	if (_loading) {
		[self stop];
	} else {
		[self send];
	}
}

- (void)send {
	NSString *text = [[_inputField text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (_loading || ([text length] == 0 && _pendingImage == nil)) {
		return;
	}
	[_inputField setText:nil];
	[_inputField resignFirstResponder];
	_roundStart = [_messages count];
	_roundOpen = YES;
	NSMutableDictionary *row = [self rowWithRole:@"user" content:text];
	if (_pendingImage != nil) {
		[row setObject:_pendingImage forKey:@"image"];
		[row setObject:[NSArray arrayWithObject:_pendingThumbnail] forKey:@"thumbnails"];
		if (_pendingPhotoPath != nil) {
			[row setObject:_pendingPhotoPath forKey:@"photo_path"];
		}
		[self setPendingImage:nil thumbnail:nil path:nil];
	}
	[_messages addObject:row];
	[self reloadTranscript];
	[self scrollToBottomAnimated:YES];
	_turn++;
	_loopCount = 0;
	[self setLoading:YES];
	// Written before the request goes out, so the question survives even if
	// the answer never arrives.
	[self persistOpenRound];
	[_client sendMessages:[self messagesForRequest]];
}

// Bumping the turn abandons work already in flight: the connection is
// cancelled outright, and a shell command that cannot be cancelled is left to
// finish into a turn nobody is listening to any more.
- (void)stop {
	if (_compacting) {
		_turn++;
		[_client cancel];
		[self finishCompactingWithError:@"stopped"];
		return;
	}
	_turn++;
	[_client cancel];
	[self setLoading:NO];
	[self closeRoundWithEndReason:ABLRoundEndReasonStopped];
}

// The calls hang off the assistant row that made them, and nothing describes
// them there: what ran is the result row's own title, and a call written into
// the assistant's content would also be echoed back to the model next to the
// structured call it already sent. A turn that went straight to a tool has an
// assistant row with nothing in it — carried for the request, hidden from the
// transcript by -isHiddenAtIndex:.
- (void)continueWithToolCalls:(NSArray *)toolCalls {
	NSMutableDictionary *last = [_messages lastObject];
	if ([[last objectForKey:@"role"] isEqualToString:@"assistant"]) {
		[last setObject:toolCalls forKey:@"tool_calls"];
		[self reloadTranscript];
	} else {
		NSMutableDictionary *row = [self rowWithRole:@"assistant" content:@""];
		[row setObject:toolCalls forKey:@"tool_calls"];
		[_messages addObject:row];
		[self reloadTranscript];
		[self scrollToBottomAnimated:YES];
	}
	if (_loopCount >= ABLToolLoopLimit) {
		[self setLoading:NO];
		[self closeRoundWithEndReason:ABLRoundEndReasonRoundLimit];
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Stopped"
			message:@"The assistant ran as many steps as it can in one turn. Send a message to continue." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[alert show];
		[alert release];
		return;
	}
	_loopCount++;
	NSString *workingDirectory = _project != nil ? [_project workingDirectory] : [ABLProjectStore scratchDirectory];
	[self performSelectorInBackground:@selector(executeToolCallsInBackground:)
		withObject:[NSDictionary dictionaryWithObjectsAndKeys:
			toolCalls, @"calls", [NSNumber numberWithUnsignedInteger:_turn], @"turn",
			workingDirectory != nil ? workingDirectory : @"", @"cwd", nil]];
}

- (void)executeToolCallsInBackground:(NSDictionary *)job {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSMutableArray *results = [NSMutableArray array];
	NSString *workingDirectory = [job objectForKey:@"cwd"];
	for (NSDictionary *call in [job objectForKey:@"calls"]) {
		NSString *name = [call objectForKey:@"name"];
		NSString *output = ABLRunToolCall(call, workingDirectory);
		[results addObject:[NSDictionary dictionaryWithObjectsAndKeys:
			[call objectForKey:@"id"], @"id", name, @"name", output, @"content", nil]];
	}
	[self performSelectorOnMainThread:@selector(didFinishExecutingTools:)
		withObject:[NSDictionary dictionaryWithObjectsAndKeys:
			[[results copy] autorelease], @"results", [job objectForKey:@"turn"], @"turn", nil]
		waitUntilDone:NO];
	[pool release];
}

- (void)didFinishExecutingTools:(NSDictionary *)job {
	if ([[job objectForKey:@"turn"] unsignedIntegerValue] != _turn) {
		return; // the user stopped or replaced the turn these results belong to
	}
	for (NSDictionary *result in [job objectForKey:@"results"]) {
		NSMutableDictionary *row = [self rowWithRole:@"tool" content:[result objectForKey:@"content"]];
		[row setObject:[result objectForKey:@"id"] forKey:@"tool_call_id"];
		[row setObject:[result objectForKey:@"name"] forKey:@"name"];
		[_messages addObject:row];
	}
	[self reloadTranscript];
	[self scrollToBottomAnimated:YES];
	[self persistOpenRound];
	[_client sendMessages:[self messagesForRequest]];
}

#pragma mark - ABLChatClientDelegate

- (void)chatClient:(ABLChatClient *)client didReceiveThinking:(NSString *)token {
	if (_compacting) {
		return; // the summary row is the only thing a compaction shows
	}
	[self appendToken:token role:@"thinking"];
}

- (void)chatClient:(ABLChatClient *)client didReceiveToken:(NSString *)token {
	if (_compacting) {
		[[[_messages lastObject] objectForKey:@"content"] appendString:token];
		[self invalidateLastBodyHeight];
		_transcriptNeedsRefresh = YES;
		return;
	}
	[self appendToken:token role:@"assistant"];
}

- (void)chatClient:(ABLChatClient *)client didFinishWithToolCalls:(NSArray *)toolCalls {
	if (!_loading) {
		return;
	}
	if (_compacting) {
		[self finishCompactingWithError:nil];
		return;
	}
	if ([toolCalls count] > 0) {
		[self continueWithToolCalls:toolCalls];
		return;
	}
	NSDictionary *last = [_messages lastObject];
	NSString *role = [last objectForKey:@"role"];
	if (![role isEqualToString:@"assistant"] && ![role isEqualToString:@"thinking"]) {
		[self appendMessageWithRole:@"assistant" content:@"No reply was received."];
	}
	[self setLoading:NO];
	[self closeRoundWithEndReason:ABLRoundEndReasonComplete];
}

- (void)chatClient:(ABLChatClient *)client didFailWithMessage:(NSString *)message {
	if (!_loading) {
		return;
	}
	if (_compacting) {
		[self finishCompactingWithError:message];
		return;
	}
	[self setLoading:NO];
	[self closeRoundWithEndReason:ABLRoundEndReasonError];
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Cannot Send"
		message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
	[alert show];
	[alert release];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[self send];
	return NO;
}

#pragma mark - Table

// Command output is the one row that is not prose: it keeps the columns the
// command printed, in a monospaced face where one is available, and its lines
// are clipped rather than wrapped.
- (BOOL)isTerminalRole:(NSString *)role {
	return [role isEqualToString:@"tool"];
}

- (UIFont *)fontForRole:(NSString *)role {
	if ([self isTerminalRole:role]) {
		UIFont *monospaced = [UIFont fontWithName:@"Courier" size:ABLTerminalFontSize];
		if (monospaced != nil) {
			return monospaced;
		}
	}
	if ([role isEqualToString:@"thinking"]) {
		return [UIFont italicSystemFontOfSize:ABLBodyFontSize];
	}
	return [UIFont systemFontOfSize:ABLBodyFontSize];
}

// The one place a row's body is measured, so the height the table reserves and
// the frame the label gets can never disagree.
// Lines of command output the row shows: what the command printed, up to the
// abridged cap.
- (NSInteger)visibleLineCountForMessage:(NSDictionary *)message {
	NSInteger lines = [[message objectForKey:@"line_count"] integerValue];
	return lines < ABLAbridgedLines ? lines : ABLAbridgedLines;
}

- (BOOL)isThinkingRole:(NSString *)role {
	return [role isEqualToString:@"thinking"];
}

// A role that can be abridged always leaves room for the disclosure, so a row
// does not reflow when its content grows past the cap mid stream.
- (CGFloat)bodyWidthForRole:(NSString *)role {
	CGFloat width = [_tableView bounds].size.width - 2.0f * ABLCellPadding;
	BOOL abridgeable = [self isThinkingRole:role] || [self isTerminalRole:role];
	return abridgeable ? width - ABLDisclosureWidth : width;
}

- (CGFloat)wrappedHeightForContent:(NSString *)content font:(UIFont *)font width:(CGFloat)width {
	return [content sizeWithFont:font constrainedToSize:CGSizeMake(width, ABLMaximumBodyHeight)
		lineBreakMode:UILineBreakModeWordWrap].height;
}

// Whether a thinking row holds more than the lines it shows — decided from the
// same measurement as the row height, so the indicator and the ellipsis agree.
// The longest prefix (or suffix) of `text` that fits on one line of `width`.
// Measured by wrapped height, so a word too long for the line counts as
// needing a second one; binary search keeps it to a handful of measurements
// per refresh, which a 3G can afford at the transcript's refresh rate.
static NSString *ABLOneLine(NSString *text, UIFont *font, CGFloat width, BOOL fromEnd) {
	CGFloat lineHeight = [@"Mg" sizeWithFont:font].height;
	NSUInteger length = [text length];
	NSUInteger low = 0, high = length;
	while (low < high) {
		NSUInteger mid = (low + high + 1) / 2;
		NSString *candidate = fromEnd ? [text substringFromIndex:length - mid] : [text substringToIndex:mid];
		CGFloat height = [candidate sizeWithFont:font constrainedToSize:CGSizeMake(width, lineHeight * 3.0f)
			lineBreakMode:UILineBreakModeWordWrap].height;
		if (height <= lineHeight + 0.5f) {
			low = mid;
		} else {
			high = mid - 1;
		}
	}
	return fromEnd ? [text substringFromIndex:length - low] : [text substringToIndex:low];
}

// The last `count` lines of `content`. What a command printed that matters is
// almost always at the end, and the "(exit N)" suffix ABLRunCommand appends is
// the last line of all — so an abridged exec row is a tail, not a head.
static NSString *ABLLastLines(NSString *content, NSInteger count) {
	NSArray *lines = [content componentsSeparatedByString:@"\n"];
	NSUInteger total = [lines count];
	if (total <= (NSUInteger)count) {
		return content;
	}
	return [[lines subarrayWithRange:NSMakeRange(total - (NSUInteger)count, (NSUInteger)count)]
		componentsJoinedByString:@"\n"];
}

// What a truncated thinking row shows: its first line, an ellipsis, and its
// last line — which, while the reply streams, is whatever just arrived.
- (NSString *)abridgedThinking:(NSString *)content font:(UIFont *)font width:(CGFloat)width {
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	// Only the two ends are ever shown, so only the two ends are looked at.
	// Trimming the whole block copied it, and the newline searches walked it;
	// worse, a block with no newline in it handed all of itself to ABLOneLine,
	// whose binary search then measured a substring of it sixteen times over.
	// Everything below is bounded by ABLThinkingWindow.
	NSUInteger length = [content length];
	NSUInteger window = length < ABLThinkingWindow ? length : ABLThinkingWindow;
	NSString *front = [content substringToIndex:window];
	NSString *back = [content substringFromIndex:length - window];

	NSString *trimmedFront = [front stringByTrimmingCharactersInSet:whitespace];
	NSRange firstBreak = [trimmedFront rangeOfString:@"\n"];
	NSString *head = firstBreak.location == NSNotFound
		? trimmedFront : [trimmedFront substringToIndex:firstBreak.location];

	NSString *trimmedBack = [back stringByTrimmingCharactersInSet:whitespace];
	NSRange lastBreak = [trimmedBack rangeOfString:@"\n" options:NSBackwardsSearch];
	NSString *tail = lastBreak.location == NSNotFound
		? trimmedBack : [trimmedBack substringFromIndex:lastBreak.location + 1];

	head = ABLOneLine([head stringByTrimmingCharactersInSet:whitespace], font, width, NO);
	tail = ABLOneLine([tail stringByTrimmingCharactersInSet:whitespace], font, width, YES);
	return [NSString stringWithFormat:@"%@\n\u2026\n%@", head, tail];
}

// The height a thinking row's body gets, and whether it is showing less than
// it holds. Answered together, from one measurement, so the indicator and the
// ellipsis can never disagree — and answered without any measurement at all
// once the block is longer than three lines could possibly hold, which while
// a reply streams is almost immediately.
- (CGFloat)thinkingBodyHeightAtIndex:(NSUInteger)index abridged:(BOOL *)abridged {
	NSDictionary *message = [_messages objectAtIndex:index];
	CGFloat cap = [@"Mg" sizeWithFont:[self fontForRole:[message objectForKey:@"role"]]].height
		* (CGFloat)ABLAbridgedLines;
	if ([[message objectForKey:@"content"] length] > ABLThinkingWindow) {
		if (abridged != NULL) {
			*abridged = YES;
		}
		return cap;
	}
	CGFloat height = [self bodyTextHeightAtIndex:index];
	if (abridged != NULL) {
		*abridged = height > cap + 0.5f;
	}
	return height < cap ? height : cap;
}

// Whether the row is showing less than it holds — which is also what decides
// the disclosure indicator and whether the row answers a tap.
- (BOOL)isAbridgedAtIndex:(NSUInteger)index {
	NSDictionary *message = [_messages objectAtIndex:index];
	NSString *role = [message objectForKey:@"role"];
	if ([self isTerminalRole:role]) {
		return [[message objectForKey:@"line_count"] integerValue] > ABLAbridgedLines;
	}
	if (![self isThinkingRole:role]) {
		return NO;
	}
	BOOL abridged = NO;
	[self thinkingBodyHeightAtIndex:index abridged:&abridged];
	return abridged;
}

- (CGFloat)bodyHeightAtIndex:(NSUInteger)index {
	NSDictionary *message = [_messages objectAtIndex:index];
	NSString *role = [message objectForKey:@"role"];
	NSString *content = [message objectForKey:@"content"];
	UIFont *font = [self fontForRole:role];
	if ([self isTerminalRole:role]) {
		// Unwrapped: exactly one line per line the row shows.
		return [@"Mg" sizeWithFont:font].height * (CGFloat)[self visibleLineCountForMessage:message];
	}
	// Thinking is capped at ABLAbridgedLines and never carries a photo, so it
	// is answered before anything is measured.
	if ([self isThinkingRole:role]) {
		return [self thinkingBodyHeightAtIndex:index abridged:NULL];
	}
	CGFloat height = [self bodyTextHeightAtIndex:index];
	if ([[message objectForKey:@"thumbnails"] count] > 0) {
		height += ABLPhotoSquare + ([content length] > 0 ? ABLPhotoGap : 0.0f);
	}
	return height;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return (NSInteger)[_visibleRows count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return ABLCellPadding + ABLRoleLabelHeight + 2.0f
		+ [self bodyHeightAtIndex:[self messageIndexForRow:[indexPath row]]] + ABLCellPadding;
}

// A row that is showing less than it holds answers a tap by pushing the whole
// text as a page, the way a step's log does.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSUInteger index = [self messageIndexForRow:[indexPath row]];
	NSDictionary *message = [_messages objectAtIndex:index];
	if (![self isAbridgedAtIndex:index]) {
		return;
	}
	NSString *role = [message objectForKey:@"role"];
	ABLLogViewController *page = [[ABLLogViewController alloc]
		initWithTitle:[self isTerminalRole:role] ? @"Output" : @"Thinking"
		text:[message objectForKey:@"content"] font:[self fontForRole:role]];
	[_detailPage release];
	_detailPage = page;
	[_detailRow release];
	_detailRow = [(NSMutableDictionary *)message retain];
	[[self navigationController] pushViewController:page animated:YES];
}

- (void)forgetDetailPage {
	[_detailPage release];
	_detailPage = nil;
	[_detailRow release];
	_detailRow = nil;
}

- (void)configureCell:(UITableViewCell *)cell forRowAtIndex:(NSUInteger)index {
	NSDictionary *message = [_messages objectAtIndex:index];
	NSString *role = [message objectForKey:@"role"];
	NSString *content = [message objectForKey:@"content"];
	CGFloat width = [self bodyWidthForRole:role];
	UIFont *font = [self fontForRole:role];
	BOOL terminal = [self isTerminalRole:role];
	BOOL abridged = [self isAbridgedAtIndex:index];

	NSString *label = @"Assistant";
	UIColor *roleColor = [UIColor colorWithRed:0.22f green:0.33f blue:0.53f alpha:1.0f];
	UIColor *background = [UIColor colorWithRed:0.93f green:0.95f blue:0.98f alpha:1.0f];
	if ([role isEqualToString:@"user"]) {
		label = @"You";
		roleColor = [UIColor colorWithRed:0.20f green:0.50f blue:0.20f alpha:1.0f];
		background = [UIColor whiteColor];
	} else if ([role isEqualToString:@"thinking"]) {
		label = @"Thinking";
		roleColor = [UIColor grayColor];
		background = [UIColor colorWithWhite:0.96f alpha:1.0f];
	} else if ([role isEqualToString:@"system"]) {
		label = [[message objectForKey:@"summary"] boolValue] ? @"Summary" : @"System";
		roleColor = [UIColor colorWithRed:0.55f green:0.35f blue:0.10f alpha:1.0f];
		background = [UIColor colorWithRed:0.99f green:0.96f blue:0.86f alpha:1.0f];
	} else if (terminal) {
		// Whether the command worked is the first thing anyone wants from this
		// row, so it is the row's colour rather than something to read for.
		// Kept pale: the body is monospaced text and has to stay legible.
		BOOL failed = [[message objectForKey:@"failed"] boolValue];
		// The tool that produced it, canonicalised: rows written before there
		// was more than one carry "exec", and a reopened transcript full of
		// them should still read as the tool it is.
		label = [NSString stringWithFormat:@"Tool %@",
			ABLCanonicalToolName([message objectForKey:@"name"])];
		roleColor = failed
			? [UIColor colorWithRed:0.60f green:0.15f blue:0.12f alpha:1.0f]
			: [UIColor colorWithRed:0.13f green:0.42f blue:0.16f alpha:1.0f];
		background = failed
			? [UIColor colorWithRed:0.99f green:0.92f blue:0.91f alpha:1.0f]
			: [UIColor colorWithRed:0.91f green:0.96f blue:0.91f alpha:1.0f];
	}

	UILabel *roleLabel = (UILabel *)[[cell contentView] viewWithTag:ABLRoleLabelTag];
	[roleLabel setText:label];
	[roleLabel setTextColor:roleColor];
	[roleLabel setFrame:CGRectMake(ABLCellPadding, ABLCellPadding, width, ABLRoleLabelHeight)];

	UILabel *body = (UILabel *)[[cell contentView] viewWithTag:ABLBodyLabelTag];
	[body setFont:font];
	NSInteger lines = 0;
	UILineBreakMode breakMode = UILineBreakModeWordWrap;
	NSString *bodyText = content;
	if (terminal) {
		lines = [self visibleLineCountForMessage:message];
		breakMode = UILineBreakModeClip;
		bodyText = ABLLastLines(content, ABLAbridgedLines);
	} else if ([self isThinkingRole:role]) {
		lines = ABLAbridgedLines;
		breakMode = UILineBreakModeTailTruncation;
		if (abridged) {
			bodyText = [self abridgedThinking:content font:font width:width];
		}
	}
	[body setLineBreakMode:breakMode];
	[body setNumberOfLines:lines];
	[body setText:bodyText];
	CGFloat bodyTop = ABLCellPadding + ABLRoleLabelHeight + 2.0f;
	CGFloat textHeight = [self bodyHeightAtIndex:index];
	// Photos are a strip of fixed squares under the text, at most
	// ABLPhotosPerRow of them; the height never depends on what they show.
	NSArray *thumbnails = [message objectForKey:@"thumbnails"];
	NSUInteger shown = [thumbnails count] < (NSUInteger)ABLPhotosPerRow ? [thumbnails count] : (NSUInteger)ABLPhotosPerRow;
	if (shown > 0) {
		textHeight -= ABLPhotoSquare + ([content length] > 0 ? ABLPhotoGap : 0.0f);
	}
	CGFloat stripTop = bodyTop + textHeight + ([content length] > 0 && shown > 0 ? ABLPhotoGap : 0.0f);
	for (NSInteger slot = 0; slot < ABLPhotosPerRow; slot++) {
		UIImageView *photo = (UIImageView *)[[cell contentView] viewWithTag:ABLPhotoViewTag + slot];
		if ((NSUInteger)slot < shown) {
			[photo setImage:[UIImage imageWithData:[thumbnails objectAtIndex:(NSUInteger)slot]]];
			[photo setFrame:CGRectMake(ABLCellPadding + (CGFloat)slot * (ABLPhotoSquare + ABLPhotoGap), stripTop, ABLPhotoSquare, ABLPhotoSquare)];
			[photo setHidden:NO];
		} else {
			[photo setImage:nil];
			[photo setHidden:YES];
		}
	}
	[body setFrame:CGRectMake(ABLCellPadding, bodyTop, width, textHeight)];
	[[cell contentView] setBackgroundColor:background];
	// The accessory sits outside the content view. The table repaints a
	// cell's backgroundColor with its own when the row comes on screen, so the
	// strip under the disclosure is coloured by a background view instead.
	[[cell backgroundView] setBackgroundColor:background];
	[cell setAccessoryType:abridged ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone];
	[cell setSelectionStyle:abridged ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *reuseIdentifier = @"MessageCell";
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
	if (cell == nil) {
		cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier] autorelease];
		[cell setSelectionStyle:UITableViewCellSelectionStyleNone];
		UIView *backdrop = [[UIView alloc] initWithFrame:CGRectZero];
		[cell setBackgroundView:backdrop];
		[backdrop release];
		UILabel *roleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		[roleLabel setTag:ABLRoleLabelTag];
		[roleLabel setFont:[UIFont boldSystemFontOfSize:13.0f]];
		[roleLabel setBackgroundColor:[UIColor clearColor]];
		[[cell contentView] addSubview:roleLabel];
		[roleLabel release];
		UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
		[body setTag:ABLBodyLabelTag];
		[body setBackgroundColor:[UIColor clearColor]];
		[[cell contentView] addSubview:body];
		[body release];
		for (NSInteger slot = 0; slot < ABLPhotosPerRow; slot++) {
			UIImageView *photo = [[UIImageView alloc] initWithFrame:CGRectZero];
			[photo setTag:ABLPhotoViewTag + slot];
			[photo setContentMode:UIViewContentModeScaleAspectFill];
			[photo setClipsToBounds:YES];
			[photo setHidden:YES];
			[[cell contentView] addSubview:photo];
			[photo release];
		}
	}
	[self configureCell:cell forRowAtIndex:[self messageIndexForRow:[indexPath row]]];
	return cell;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
	return orientation == UIInterfaceOrientationPortrait;
}

// Every ivar is nil'd, not just released, and that is not tidiness. [super
// dealloc] tears the view down, and UIViewController answers by calling
// -viewDidUnload on a controller that is already half gone: it stops the
// refresh timer, releases the view-owned objects again and touches
// _bodyHeights — all of which this method had just released. That double
// release is the crash the phone left in /var/logs/CrashReporter after a push
// and a pop, symbolicating to -[ABLChatViewController dealloc] calling into
// UIKit calling -[ABLChatViewController viewDidUnload].
- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_transcriptTimer invalidate];
	[_transcriptTimer release];
	_transcriptTimer = nil;
	[_client setDelegate:nil];
	[self forgetDetailPage];
	[self releaseViewOwnedObjects];
	[_pendingImage release];
	_pendingImage = nil;
	[_pendingThumbnail release];
	_pendingThumbnail = nil;
	[_pendingPhotoPath release];
	_pendingPhotoPath = nil;
	[_client cancel];
	[_client release];
	_client = nil;
	[_systemPrompt release];
	_systemPrompt = nil;
	[_bodyHeights release];
	_bodyHeights = nil;
	[_visibleRows release];
	_visibleRows = nil;
	[_messages release];
	_messages = nil;
	[_project release];
	_project = nil;
	[super dealloc];
}

@end
