#import "ABLProjectListViewController.h"
#import "ABLChatViewController.h"
#import "ABLConfig.h"
#import "ABLDetailCell.h"
#import "ABLProject.h"
#import "ABLProjectStore.h"
#import "ABLSettingsViewController.h"
#import "ABLTemplate.h"

static const CGFloat ABLNameFieldInset = 14.0f;

#pragma mark - New Project

// A grouped page with one text-field row, the way iOS 4 asked for a single
// value. A UIAlertView with a text field would be the modern shape, and its
// style is iOS 5 only — this is both older and closer to the house idiom.
@interface ABLNewProjectViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate> {
	UITableView *_tableView;
	UITextField *_nameField;
	ABLProjectListViewController *_owner; // not retained; it owns the stack
}
- (id)initWithOwner:(ABLProjectListViewController *)owner;
@end

@implementation ABLNewProjectViewController

- (id)initWithOwner:(ABLProjectListViewController *)owner {
	self = [super initWithNibName:nil bundle:nil];
	if (self != nil) {
		_owner = owner;
	}
	return self;
}

- (void)loadView {
	// Released first: -loadView runs again after a memory warning unloads the
	// view of a controller that is not on screen.
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = [[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]
		style:UITableViewStyleGrouped];
	[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[_tableView setDataSource:self];
	[_tableView setDelegate:self];
	[self setView:_tableView];
	[self setTitle:@"New Project"];

	UIBarButtonItem *create = [[UIBarButtonItem alloc] initWithTitle:@"Create"
		style:UIBarButtonItemStyleDone target:self action:@selector(create)];
	[[self navigationItem] setRightBarButtonItem:create];
	[create release];
}

- (void)viewDidUnload {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[_nameField setDelegate:nil];
	[_nameField release];
	_nameField = nil;
	[super viewDidUnload];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[_nameField becomeFirstResponder];
}

- (void)create {
	NSString *name = [[_nameField text] stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([name length] == 0) {
		[_nameField becomeFirstResponder];
		return;
	}
	[_nameField resignFirstResponder];
	// Popping first means the transcript the owner pushes lands on the list,
	// not on top of this page.
	[[self navigationController] popViewControllerAnimated:NO];
	[_owner createProjectNamed:name];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *reuseIdentifier = @"NameCell";
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
	if (cell == nil) {
		// UITableView empties its reuse pool on a memory warning, so this runs
		// again on the next reload. Assigning straight over the ivar leaked
		// the old field and threw away the name the user had already typed.
		[_nameField release];
		cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier] autorelease];
		[cell setSelectionStyle:UITableViewCellSelectionStyleNone];
		CGFloat width = [tableView bounds].size.width - 2.0f * ABLNameFieldInset - 20.0f;
		_nameField = [[UITextField alloc] initWithFrame:CGRectMake(ABLNameFieldInset, 11.0f, width, 24.0f)];
		[_nameField setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
		[_nameField setFont:[UIFont systemFontOfSize:17.0f]];
		[_nameField setPlaceholder:@"Project Name"];
		[_nameField setReturnKeyType:UIReturnKeyDone];
		[_nameField setAutocorrectionType:UITextAutocorrectionTypeNo];
		[_nameField setAutocapitalizationType:UITextAutocapitalizationTypeWords];
		[_nameField setClearButtonMode:UITextFieldViewModeWhileEditing];
		[_nameField setDelegate:self];
		[[cell contentView] addSubview:_nameField];
	}
	return cell;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[self create];
	return NO;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
	return orientation == UIInterfaceOrientationPortrait;
}

// Nil'd, not merely released: [super dealloc] unloads the view, and
// UIViewController calls -viewDidUnload on the way out, which releases the
// same two objects again.
- (void)dealloc {
	[_nameField setDelegate:nil];
	[_nameField release];
	_nameField = nil;
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[super dealloc];
}

@end

#pragma mark - Project List

@implementation ABLProjectListViewController

- (void)loadView {
	// Released first: -loadView runs again after a memory warning unloads the
	// view of a controller that is not on screen, and this one spends its life
	// underneath a transcript.
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = [[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]
		style:UITableViewStyleGrouped];
	[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[_tableView setDataSource:self];
	[_tableView setDelegate:self];
	[self setView:_tableView];
	[self setTitle:@"AirBuild"];

	// Two buttons in one slot — iOS 4 gives a navigation item exactly one
	// right item, and a bar-style momentary segmented control is how the
	// system apps put two there. Chat first, then +.
	[_actionsItem release];
	UISegmentedControl *actions = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:
		[UIImage imageNamed:@"BarChat.png"], [UIImage imageNamed:@"BarPlus.png"], nil]];
	[actions setSegmentedControlStyle:UISegmentedControlStyleBar];
	[actions setMomentary:YES];
	[actions setFrame:CGRectMake(0.0f, 0.0f, 84.0f, 30.0f)];
	[actions addTarget:self action:@selector(actionChosen:) forControlEvents:UIControlEventValueChanged];
	_actionsItem = [[UIBarButtonItem alloc] initWithCustomView:actions];
	[actions release];
	[_creatingItem release];
	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
		initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	[spinner startAnimating];
	_creatingItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
	[spinner release];
	// -loadView runs again after a memory warning, and a project may well be
	// being made while it does.
	[[self navigationItem] setRightBarButtonItem:(_creating ? _creatingItem : _actionsItem)];

	UIBarButtonItem *settings = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"BarGear.png"]
		style:UIBarButtonItemStyleBordered target:self action:@selector(openSettings)];
	[[self navigationItem] setLeftBarButtonItem:settings];
	[settings release];
}

// The list is rebuilt from disk on the way back in, so the loaded projects are
// not worth keeping across an unload.
- (void)viewDidUnload {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[_projects release];
	_projects = nil;
	[_actionsItem release];
	_actionsItem = nil;
	[_creatingItem release];
	_creatingItem = nil;
	[super viewDidUnload];
}

// The subtitle and the ordering both change whenever a transcript grows, so
// the list is rebuilt from disk every time it comes back on screen.
- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// Back at the list means nothing is open, so the next launch starts here
	// too. The transcript writes the key again as soon as one is opened.
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:ABLDefaultsOpenProjectKey];
	[self reloadProjects];
}

- (void)reloadProjects {
	NSArray *projects = [[ABLProjectStore projects] retain];
	[_projects release];
	_projects = projects;
	[_tableView reloadData];
}

#pragma mark - Actions

- (void)newProject {
	if (_creating) {
		return;
	}
	ABLNewProjectViewController *page = [[ABLNewProjectViewController alloc] initWithOwner:self];
	[[self navigationController] pushViewController:page animated:YES];
	[page release];
}

- (void)actionChosen:(UISegmentedControl *)actions {
	if ([actions selectedSegmentIndex] == 0) {
		[self openScratchChat];
	} else {
		[self newProject];
	}
}

- (void)openSettings {
	ABLSettingsViewController *settings = [[ABLSettingsViewController alloc] init];
	[[self navigationController] pushViewController:settings animated:YES];
	[settings release];
}

// The same controller every time, so the conversation is still there on the
// way back in; it lives exactly as long as this process does.
- (void)openScratchChat {
	if (_scratchChat == nil) {
		_scratchChat = [[ABLChatViewController alloc] initWithProject:nil];
	}
	[[self navigationController] pushViewController:_scratchChat animated:YES];
}

- (void)openProject:(ABLProject *)project {
	ABLChatViewController *chat = [[ABLChatViewController alloc] initWithProject:project];
	[[self navigationController] pushViewController:chat animated:YES];
	[chat release];
}

- (void)setCreating:(BOOL)creating {
	_creating = creating;
	[[self navigationItem] setRightBarButtonItem:(creating ? _creatingItem : _actionsItem)];
}

// Off the main thread, because making a project copies the app template in and
// resolves its placeholders file by file, and the list is already back on
// screen with nothing to say for itself while that happens. The + in the
// top-right slot is a spinner until it comes back.
- (void)createProjectNamed:(NSString *)name {
	if (_creating) {
		return;
	}
	[self setCreating:YES];
	[self performSelectorInBackground:@selector(createProjectInBackground:) withObject:name];
}

- (void)createProjectInBackground:(NSString *)name {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSMutableDictionary *outcome = [NSMutableDictionary dictionary];
	ABLProject *project = [ABLProjectStore createProjectNamed:name];
	if (project == nil) {
		[outcome setObject:@"The project folder could not be created. Check that there "
			@"is free space on this iPhone." forKey:@"error"];
	} else {
		[outcome setObject:project forKey:@"project"];
		NSString *seedError = nil;
		if (ABLSeedProjectTemplate([project workingDirectory], name, &seedError) == nil
				&& seedError != nil) {
			// Not fatal. An empty project is still a project and the model can
			// write one from nothing; it is worth saying so, because not having
			// to is the whole point of the template.
			[outcome setObject:seedError forKey:@"warning"];
		}
	}
	[self performSelectorOnMainThread:@selector(didCreateProject:) withObject:outcome
		waitUntilDone:NO];
	[pool release];
}

- (void)didCreateProject:(NSDictionary *)outcome {
	[self setCreating:NO];
	NSString *failure = [outcome objectForKey:@"error"];
	if (failure != nil) {
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Unable to Create Project"
			message:failure delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[alert show];
		[alert release];
		return;
	}
	[self reloadProjects];
	[self openProject:[outcome objectForKey:@"project"]];
	NSString *warning = [outcome objectForKey:@"warning"];
	if (warning != nil) {
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"No Template"
			message:[warning stringByAppendingString:@" The project was made anyway; the "
				@"model will have to write its Makefile itself."]
			delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[alert show];
		[alert release];
	}
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return (NSInteger)[_projects count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return [_projects count] > 0 ? @"Projects" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	return [_projects count] == 0 ? @"Tap + to start a project." : @"Swipe a project to delete it.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *reuseIdentifier = @"ProjectCell";
	ABLDetailCell *cell = (ABLDetailCell *)[tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
	if (cell == nil) {
		cell = [[[ABLDetailCell alloc] initWithReuseIdentifier:reuseIdentifier layout:ABLDetailCellSubtitle] autorelease];
		[cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
	}
	ABLProject *project = [_projects objectAtIndex:(NSUInteger)[indexPath row]];
	[[cell titleLabel] setText:[project name]];
	NSString *subtitle = [project lastMessage];
	[[cell detailLabel] setText:[subtitle length] > 0 ? subtitle : @"No messages yet"];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[self openProject:[_projects objectAtIndex:(NSUInteger)[indexPath row]]];
}

// Deleting a project deletes source code, so it asks first.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
		forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (style != UITableViewCellEditingStyleDelete) {
		return;
	}
	_pendingDeletionRow = (NSUInteger)[indexPath row];
	ABLProject *project = [_projects objectAtIndex:_pendingDeletionRow];
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Delete Project"
		message:[NSString stringWithFormat:@"“%@” and everything in it, including its source, will be removed.", [project name]]
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Delete", nil];
	[alert show];
	[alert release];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)index {
	if (index == [alertView cancelButtonIndex] || _pendingDeletionRow >= [_projects count]) {
		[_tableView setEditing:NO animated:YES];
		return;
	}
	[ABLProjectStore deleteProject:[_projects objectAtIndex:_pendingDeletionRow]];
	[self reloadProjects];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
	return orientation == UIInterfaceOrientationPortrait;
}

// Same reason as everywhere else here: -viewDidUnload runs from inside
// [super dealloc] and releases both of these a second time.
- (void)dealloc {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[_projects release];
	_projects = nil;
	[_actionsItem release];
	_actionsItem = nil;
	[_creatingItem release];
	_creatingItem = nil;
	[_scratchChat release];
	_scratchChat = nil;
	[super dealloc];
}

@end
