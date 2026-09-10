#import "ABLOnboardingViewController.h"
#import "ABLDetailCell.h"
#import "ABLLogViewController.h"
#import "ABLStash.h"

// A spinner is 20pt square; the mark matches it so the column does not move
// when a row stops running.
static const CGFloat ABLStatusMarkWidth = 20.0f;

// The mark at the right of a row. Text rather than an image: this is one
// column of a plain grouped table, and iOS 4 has no symbol font to draw from.
static NSString *ABLStatusMark(ABLStepState state) {
	switch (state) {
		case ABLStepDone: return @"✓";
		case ABLStepFailed: return @"✗";
		case ABLStepSkipped: return @"—";
		case ABLStepManual: return @"!";
		default: return @"";
	}
}

// Phase identifiers are what the plan and the runner speak; the headers say
// what each one does for the person waiting on it.
static NSString *ABLPhaseDisplayName(NSString *phase) {
	if ([phase isEqualToString:@"stash"]) {
		return @"Make Room";
	}
	if ([phase isEqualToString:@"install"]) {
		return @"Install";
	}
	if ([phase isEqualToString:@"ready"]) {
		return @"Check";
	}
	return phase;
}

static UIColor *ABLStatusColor(ABLStepState state) {
	switch (state) {
		case ABLStepDone: return [UIColor colorWithRed:0.20f green:0.50f blue:0.20f alpha:1.0f];
		case ABLStepFailed: return [UIColor colorWithRed:0.65f green:0.15f blue:0.15f alpha:1.0f];
		case ABLStepManual: return [UIColor colorWithRed:0.65f green:0.45f blue:0.10f alpha:1.0f];
		default: return [UIColor grayColor];
	}
}

@implementation ABLOnboardingViewController

- (id)initWithNibName:(NSString *)nibName bundle:(NSBundle *)bundle {
	self = [super initWithNibName:nibName bundle:bundle];
	if (self != nil) {
		// Shared, and retained here only so -dealloc stays symmetrical. The
		// plan is loaded once; a second visit to this page must attach to the
		// run that is already going, not start a rival one.
		_bootstrap = [[ABLBootstrap shared] retain];
		_headerMarks = [[NSMutableDictionary alloc] init];
		[_bootstrap setDelegate:self];
		NSString *error = nil;
		if ([[_bootstrap phases] count] == 0 && ![_bootstrap loadWithError:&error]) {
			_loadError = [error copy];
		}
	}
	return self;
}

- (void)loadView {
	// Released first: -loadView runs again after a memory warning unloads the
	// view of an off-screen controller, and this page spends its time with a
	// log page pushed on top of it.
	[_tableView release];
	[_installItem release];
	[_runningItem release];
	_tableView = [[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]
		style:UITableViewStyleGrouped];
	[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[_tableView setDataSource:self];
	[_tableView setDelegate:self];
	[self setView:_tableView];
	[self setTitle:@"Environment"];

	// The back slot is ours, so leaving before the environment is installed
	// can be questioned first — the navigation bar's own back button cannot be
	// intercepted in 4.0.
	UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"AirBuild"
		style:UIBarButtonItemStyleBordered target:self action:@selector(leave)];
	[[self navigationItem] setLeftBarButtonItem:back];
	[back release];

	_installItem = [[UIBarButtonItem alloc] initWithTitle:@"Install"
		style:UIBarButtonItemStyleDone target:self action:@selector(install)];
	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
		initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	[spinner startAnimating];
	_runningItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
	[spinner release];
	[self updateInstallButton];
}

- (void)updateInstallButton {
	if ([_bootstrap running]) {
		[[self navigationItem] setRightBarButtonItem:_runningItem];
		return;
	}
	if (_loadError != nil) {
		[[self navigationItem] setRightBarButtonItem:nil];
		return;
	}
	[_installItem setTitle:[_bootstrap isFinished] ? @"Reinstall" : @"Install"];
	[[self navigationItem] setRightBarButtonItem:_installItem];
}

// Two alerts share this controller as their delegate and want opposite things
// from a tap, so they are told apart by tag rather than by button index.
enum {
	ABLLeaveAlertTag = 1,
	ABLWelcomeAlertTag = 2
};

- (void)leave {
	if (_loadError == nil && ![_bootstrap isFinished]) {
		NSString *message = [_bootstrap running]
			? @"The install keeps running in the background, but AirBuild cannot build apps until it finishes. Leave now?"
			: @"The build environment is not installed. AirBuild cannot build apps without it. Leave anyway?";
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Environment Not Ready" message:message
			delegate:self cancelButtonTitle:@"Stay" otherButtonTitles:@"Leave", nil];
		[alert setTag:ABLLeaveAlertTag];
		[alert show];
		[alert release];
		return;
	}
	[[self navigationController] popViewControllerAnimated:YES];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
	if ([alertView tag] == ABLWelcomeAlertTag) {
		// Straight to the project list, not back one page: Environment may
		// have been pushed on top of Settings on first launch.
		[[self navigationController] popToRootViewControllerAnimated:YES];
		return;
	}
	if (buttonIndex != [alertView cancelButtonIndex]) {
		[[self navigationController] popViewControllerAnimated:YES];
	}
}

- (void)install {
	if (_loadError != nil || [_bootstrap running]) {
		return;
	}
	[_bootstrap start];
	[self showRun];
}

- (void)reinstall {
	if (_loadError != nil || [_bootstrap running]) {
		return;
	}
	[_bootstrap reinstall];
	[self showRun];
}

- (void)showRun {
	[self updateInstallButton];
	[_tableView reloadData];
}

#pragma mark - ABLBootstrapDelegate

- (void)bootstrap:(ABLBootstrap *)bootstrap didUpdateStep:(ABLBootstrapStep *)step {
	NSArray *phases = [bootstrap phases];
	NSUInteger section = [phases indexOfObject:[step phase]];
	if (section == NSNotFound) {
		return;
	}
	NSUInteger row = [[bootstrap stepsInPhase:[step phase]] indexOfObject:step];
	if (row == NSNotFound) {
		return;
	}
	// The row is always reconfigured in place. On iOS 4, reloadSections: with
	// UITableViewRowAnimationNone leaves the cells already on screen as they
	// were — a finished step kept its spinner until it scrolled out and back —
	// and rebuilding the section for a spinner costs a visible flicker on a 3G.
	NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)row inSection:(NSInteger)section];
	ABLDetailCell *cell = (ABLDetailCell *)[_tableView cellForRowAtIndexPath:path];
	if (cell != nil) {
		[self configureCell:cell forStep:step];
	}
	// The phase's header carries a mark too, and asking the table for a header
	// view is iOS 6, so when that mark changes the section is redrawn — with a
	// fade, which is the reload iOS 4 actually performs.
	NSString *phase = [step phase];
	NSString *mark = ABLStatusMark([bootstrap stateOfPhase:phase]);
	if (![mark isEqualToString:[_headerMarks objectForKey:phase]]) {
		[_headerMarks setObject:mark forKey:phase];
		[_tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
			withRowAnimation:UITableViewRowAnimationFade];
	}
}

- (void)bootstrap:(ABLBootstrap *)bootstrap didFinishWithFailure:(ABLBootstrapStep *)failedStep {
	[self updateInstallButton];
	[_tableView reloadData];
	if (failedStep == nil) {
		UIAlertView *done = [[UIAlertView alloc] initWithTitle:@"Welcome to AirBuild"
			message:@"The build environment is ready. Start a project and the model can write, compile and install apps on this phone."
			delegate:self cancelButtonTitle:@"Go Home" otherButtonTitles:nil];
		[done setTag:ABLWelcomeAlertTag];
		[done show];
		[done release];
		return;
	}
	[_installItem setTitle:@"Retry"];
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[failedStep title]
		message:[NSString stringWithFormat:@"%@\n\nTap the row to read the whole log. Retry picks up from here.",
			[failedStep status]]
		delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
	[alert show];
	[alert release];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return _loadError != nil ? 1 : (NSInteger)[[_bootstrap phases] count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (_loadError != nil) {
		return 0;
	}
	NSString *phase = [[_bootstrap phases] objectAtIndex:(NSUInteger)section];
	return (NSInteger)[[_bootstrap stepsInPhase:phase] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (_loadError != nil) {
		return nil;
	}
	NSString *phase = [[_bootstrap phases] objectAtIndex:(NSUInteger)section];
	NSString *name = [ABLPhaseDisplayName(phase) uppercaseString];
	NSString *mark = ABLStatusMark([_bootstrap stateOfPhase:phase]);
	return [NSString stringWithFormat:@"%ld · %@ %@", (long)section + 1, name, mark];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (_loadError != nil) {
		return _loadError;
	}
	if (section != (NSInteger)[[_bootstrap phases] count] - 1) {
		return nil;
	}
	// One sentence. What the stash does to the system partition and how to
	// undo it is in AGENTS.md and the log, not on a page a person reads once.
	return @"Installs the compiler and the SDK on this iPhone. This takes several minutes.";
}

- (void)configureCell:(ABLDetailCell *)cell forStep:(ABLBootstrapStep *)step {
	[[cell titleLabel] setText:[step title]];
	// The subtitle is the step's progress and nothing else: the manifest's
	// description of each step is for the log, not for a page a person
	// glances at while it runs.
	[[cell detailLabel] setText:[step status]];

	// Mark and spinner both go in the accessory slot so they land on the same
	// baseline and the same right edge. Positioning the mark by hand inside
	// contentView instead put it in a different coordinate space from the
	// spinner — and contentView narrows when an accessory appears, so the
	// column visibly shifted between a settled row and a running one.
	if ([step state] == ABLStepRunning) {
		UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
			initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
		[spinner startAnimating];
		[cell setAccessoryView:spinner];
		[spinner release];
	} else {
		UILabel *mark = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, 0.0f, ABLStatusMarkWidth, ABLStatusMarkWidth)];
		[mark setBackgroundColor:[UIColor clearColor]];
		[mark setFont:[UIFont boldSystemFontOfSize:16.0f]];
		[mark setTextAlignment:UITextAlignmentCenter];
		[mark setText:ABLStatusMark([step state])];
		[mark setTextColor:ABLStatusColor([step state])];
		[cell setAccessoryView:mark];
		[mark release];
	}
	// Only a step that has actually printed something has a log to open.
	// -hasLog rather than a length check on the string itself: the runner is
	// appending to that log on its own thread while this runs for every row on
	// every scroll.
	[cell setSelectionStyle:[step hasLog]
		? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *reuseIdentifier = @"StepCell";
	ABLDetailCell *cell = (ABLDetailCell *)[tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
	if (cell == nil) {
		cell = [[[ABLDetailCell alloc] initWithReuseIdentifier:reuseIdentifier layout:ABLDetailCellSubtitle] autorelease];
	}

	NSString *phase = [[_bootstrap phases] objectAtIndex:(NSUInteger)[indexPath section]];
	[self configureCell:cell forStep:[[_bootstrap stepsInPhase:phase] objectAtIndex:(NSUInteger)[indexPath row]]];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSString *phase = [[_bootstrap phases] objectAtIndex:(NSUInteger)[indexPath section]];
	ABLBootstrapStep *step = [[_bootstrap stepsInPhase:phase] objectAtIndex:(NSUInteger)[indexPath row]];
	if (![step hasLog]) {
		return;
	}
	ABLLogViewController *log = [[ABLLogViewController alloc] initWithTitle:[step title]
		text:[step logSnapshot]];
	[log followSource:step selector:@selector(logSnapshot)];
	[[self navigationController] pushViewController:log animated:YES];
	[log release];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
	return orientation == UIInterfaceOrientationPortrait;
}

- (void)dealloc {
	// The runner is shared and outlives this page, and a later page may
	// already have made itself the delegate. Only clear it if it is still us.
	if ([_bootstrap delegate] == self) {
		[_bootstrap setDelegate:nil];
	}
	[_bootstrap release];
	_bootstrap = nil;
	// Nil'd like everywhere else here: [super dealloc] unloads the view and
	// UIViewController calls -viewDidUnload on the way. This page has none
	// today, and the rule is what keeps that from mattering if it grows one.
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[_installItem release];
	_installItem = nil;
	[_runningItem release];
	_runningItem = nil;
	[_headerMarks release];
	_headerMarks = nil;
	[_loadError release];
	_loadError = nil;
	[super dealloc];
}

@end
