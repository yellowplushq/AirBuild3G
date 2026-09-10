#import "ABLLogViewController.h"

@implementation ABLLogViewController

- (id)initWithTitle:(NSString *)title text:(NSString *)text {
	return [self initWithTitle:title text:text font:nil];
}

- (id)initWithTitle:(NSString *)title text:(NSString *)text font:(UIFont *)font {
	self = [super initWithNibName:nil bundle:nil];
	if (self != nil) {
		_font = [font retain];
		// Copied rather than held: the runner keeps appending to the step's log
		// on its own thread, and this page is a snapshot of it.
		_text = [text copy];
		[self setTitle:title];
	}
	return self;
}

- (void)loadView {
	// Released first: a memory warning unloads the view of an off-screen
	// controller and -loadView runs again. This page holds up to 64 KB of
	// command output, so leaking the text view leaks the text with it.
	[_textView release];
	_textView = [[UITextView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
	[_textView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[_textView setEditable:NO];
	// Command output keeps the columns the command printed, so a monospaced
	// face where there is one — the same choice the transcript makes.
	UIFont *font = _font;
	if (font == nil) {
		font = [UIFont fontWithName:@"Courier" size:12.0f];
	}
	[_textView setFont:font != nil ? font : [UIFont systemFontOfSize:13.0f]];
	[_textView setText:[_text length] > 0 ? _text : @"This step produced no output."];
	[self setView:_textView];
}

static const NSTimeInterval ABLLogRefreshInterval = 1.0;

- (void)updateText:(NSString *)text {
	NSString *copy = [text copy];
	[_text release];
	_text = copy;
	if (_textView == nil) {
		return;
	}
	// A reader at the tail stays at the tail; anyone else keeps their place.
	CGPoint offset = [_textView contentOffset];
	CGFloat oldBottom = [_textView contentSize].height - [_textView bounds].size.height;
	BOOL atTail = offset.y >= oldBottom - 4.0f;
	[_textView setText:_text];
	CGFloat bottom = [_textView contentSize].height - [_textView bounds].size.height;
	if (bottom < 0.0f) {
		bottom = 0.0f;
	}
	if (atTail || offset.y > bottom) {
		offset.y = bottom;
	}
	[_textView setContentOffset:offset animated:NO];
}

- (void)viewDidUnload {
	[_textView release];
	_textView = nil;
	[super viewDidUnload];
}

- (void)followSource:(id)source selector:(SEL)selector {
	[source retain];
	[_liveSource release];
	_liveSource = source;
	_liveSelector = selector;
}

- (void)pollSource {
	if (_liveSource == nil) {
		return;
	}
	NSString *text = [_liveSource performSelector:_liveSelector];
	if ([text isKindOfClass:[NSString class]] && ![text isEqualToString:_text]) {
		[self updateText:text];
	}
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	if (_liveSource != nil && _liveTimer == nil) {
		[self pollSource];
		_liveTimer = [[NSTimer scheduledTimerWithTimeInterval:ABLLogRefreshInterval target:self
			selector:@selector(pollSource) userInfo:nil repeats:YES] retain];
		[[NSRunLoop currentRunLoop] addTimer:_liveTimer forMode:NSRunLoopCommonModes];
	}
}

- (void)viewWillDisappear:(BOOL)animated {
	[_liveTimer invalidate];
	[_liveTimer release];
	_liveTimer = nil;
	[super viewWillDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
	return orientation == UIInterfaceOrientationPortrait;
}

// _textView is nil'd because [super dealloc] unloads the view, and
// UIViewController answers that with -viewDidUnload, which releases it again.
- (void)dealloc {
	[_liveTimer invalidate];
	[_liveTimer release];
	_liveTimer = nil;
	[_liveSource release];
	_liveSource = nil;
	[_textView release];
	_textView = nil;
	[_text release];
	_text = nil;
	[_font release];
	_font = nil;
	[super dealloc];
}

@end
