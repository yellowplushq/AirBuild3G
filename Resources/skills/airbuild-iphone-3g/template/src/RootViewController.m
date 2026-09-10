#import "RootViewController.h"

static const CGFloat ABMargin = 20.0f;
static const CGFloat ABButtonHeight = 44.0f;

@implementation RootViewController

- (id)init {
	self = [super initWithNibName:nil bundle:nil];
	if (self != nil) {
		[self setTitle:@"__NAME__"];
	}
	return self;
}

// Frame-based, laid out here and kept correct by autoresizing masks.
// -viewDidLayoutSubviews is iOS 5 and does not exist on this phone.
- (void)loadView {
	CGRect bounds = [[UIScreen mainScreen] applicationFrame];
	bounds.origin = CGPointZero;

	UIView *view = [[UIView alloc] initWithFrame:bounds];
	[view setBackgroundColor:[UIColor colorWithRed:0.93f green:0.94f blue:0.96f alpha:1.0f]];
	[view setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];

	_label = [[UILabel alloc] initWithFrame:CGRectMake(ABMargin, ABMargin,
		bounds.size.width - 2.0f * ABMargin, 60.0f)];
	[_label setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
	[_label setBackgroundColor:[UIColor clearColor]];
	[_label setNumberOfLines:0];
	[_label setTextAlignment:UITextAlignmentCenter];
	[_label setFont:[UIFont systemFontOfSize:17.0f]];
	[_label setText:@"Built on an iPhone 3G."];
	[view addSubview:_label];

	UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
	[button setFrame:CGRectMake(ABMargin, ABMargin + 60.0f + ABMargin,
		bounds.size.width - 2.0f * ABMargin, ABButtonHeight)];
	[button setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
	[button setTitle:@"Tap me" forState:UIControlStateNormal];
	[button addTarget:self action:@selector(tapped)
		forControlEvents:UIControlEventTouchUpInside];
	[view addSubview:button];

	[self setView:view];
	[view release];
}

- (void)tapped {
	_taps++;
	[_label setText:[NSString stringWithFormat:@"Tapped %ld time%@.",
		(long)_taps, _taps == 1 ? @"" : @"s"]];
}

- (void)dealloc {
	[_label release];
	[super dealloc];
}

@end
