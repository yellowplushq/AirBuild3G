#import "ABLSettingsViewController.h"
#import "ABLBootstrap.h"
#import "ABLConfig.h"
#import "ABLOnboardingViewController.h"

// Three sections, and they have nothing to do with each other: where requests
// go, what is accepted on the way there, and what is installed on the phone.
enum {
	ABLEndpointSection = 0,
	ABLSecuritySection,
	ABLEnvironmentSection,
	ABLSectionCount
};

enum {
	ABLBaseRow = 0,
	ABLKeyRow,
	ABLModelRow,
	ABLEndpointRowCount
};

// Both rows push the same page. The second one starts a run that ignores what
// dpkg already reports as installed, which is the only way to repair a
// toolchain from the UI: an ordinary run is idempotent and would do nothing.
enum {
	ABLEnvironmentRow = 0,
	ABLReinstallRow = 1,
	ABLEnvironmentRowCount
};

// Grouped-table geometry, fixed because this app is portrait only.
static const CGFloat ABLFieldLabelWidth = 92.0f;
static const CGFloat ABLFieldInset = 10.0f;

@implementation ABLSettingsViewController

// Built here, not in -loadView: -loadView runs again after a memory warning
// unloads the view of a controller that is not on screen, and rebuilding the
// fields there would throw away what was half-typed into them.
- (id)init {
	self = [super initWithNibName:nil bundle:nil];
	if (self != nil) {
		_baseField = [self newFieldWithKey:ABLDefaultsAPIBaseKey placeholder:ABLDefaultAPIBase];
		[_baseField setKeyboardType:UIKeyboardTypeURL];
		_keyField = [self newFieldWithKey:ABLDefaultsAPIKeyKey placeholder:@"sk-…"];
		[_keyField setSecureTextEntry:YES];
		_modelField = [self newFieldWithKey:ABLDefaultsModelKey placeholder:ABLDefaultModel];
	}
	return self;
}

// Retained by the caller; the placeholder is the value that will be used if
// the field is left empty, so an untouched page still says what will happen.
- (UITextField *)newFieldWithKey:(NSString *)key placeholder:(NSString *)placeholder {
	UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
	[field setText:[[NSUserDefaults standardUserDefaults] stringForKey:key]];
	[field setPlaceholder:placeholder];
	[field setFont:[UIFont systemFontOfSize:15.0f]];
	[field setTextColor:[UIColor colorWithRed:0.22f green:0.33f blue:0.53f alpha:1.0f]];
	[field setAutocapitalizationType:UITextAutocapitalizationTypeNone];
	[field setAutocorrectionType:UITextAutocorrectionTypeNo];
	[field setClearButtonMode:UITextFieldViewModeWhileEditing];
	[field setReturnKeyType:UIReturnKeyDone];
	[field setDelegate:self];
	return field;
}

- (void)loadView {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = [[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame] style:UITableViewStyleGrouped];
	[_tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[_tableView setDataSource:self];
	[_tableView setDelegate:self];
	[self setView:_tableView];
	[self setTitle:@"Settings"];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[_tableView reloadData];
}

// Leaving the page is a save. Typing a key and pressing Back is what a person
// does, and losing it there would be indistinguishable from the key not
// working.
- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self save];
}

- (void)viewDidUnload {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[super viewDidUnload];
}

#pragma mark - Saving

- (void)saveField:(UITextField *)field toKey:(NSString *)key {
	NSString *value = [[field text] stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([value length] > 0) {
		[defaults setObject:value forKey:key];
	} else {
		// Removed rather than stored empty, so the compiled-in default is what
		// a cleared field falls back to.
		[defaults removeObjectForKey:key];
	}
}

- (void)save {
	[self saveField:_baseField toKey:ABLDefaultsAPIBaseKey];
	[self saveField:_keyField toKey:ABLDefaultsAPIKeyKey];
	[self saveField:_modelField toKey:ABLDefaultsModelKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
	[field resignFirstResponder];
	return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)field {
	[self save];
}

- (void)trustSwitchChanged:(UISwitch *)sender {
	[[NSUserDefaults standardUserDefaults] setBool:[sender isOn] forKey:ABLDefaultsTrustAnyCertificateKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Environment

- (void)openEnvironmentReinstalling:(BOOL)reinstalling {
	ABLOnboardingViewController *environment = [[ABLOnboardingViewController alloc] init];
	[[self navigationController] pushViewController:environment animated:YES];
	if (reinstalling) {
		[environment reinstall];
	}
	[environment release];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
	if (buttonIndex != [alertView cancelButtonIndex]) {
		[self openEnvironmentReinstalling:YES];
	}
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return ABLSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
		case ABLEndpointSection: return ABLEndpointRowCount;
		case ABLSecuritySection: return 1;
		default: return ABLEnvironmentRowCount;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch (section) {
		case ABLEndpointSection: return @"Endpoint";
		case ABLSecuritySection: return @"Security";
		default: return @"Build Environment";
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == ABLEndpointSection) {
		return @"Requests go straight from this iPhone to that address, with this key as the "
			@"bearer token. Both are kept in this app's preferences and are sent nowhere else. "
			@"Any endpoint that speaks the OpenAI chat completions format works.";
	}
	if (section == ABLSecuritySection) {
		return @"Off, the certificate is checked the usual way. On, any certificate is accepted "
			@"— which means anyone able to answer for that address can read your API key. "
			@"Only turn it on for an endpoint on your own network.";
	}
	return [ABLBootstrap isReady]
		? @"The compiler and the SDK are installed. Reinstall Everything installs them again if the toolchain is damaged."
		: @"The compiler and the SDK are not installed yet. Open Environment to install them.";
}

- (UITableViewCell *)fieldCellWithTitle:(NSString *)title field:(UITextField *)field {
	UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];
	[cell setSelectionStyle:UITableViewCellSelectionStyleNone];
	[[cell textLabel] setText:title];
	[[cell textLabel] setFont:[UIFont boldSystemFontOfSize:15.0f]];
	// Laid out here rather than in a cell subclass: the geometry is two
	// constants and the page is portrait only.
	CGRect content = [[cell contentView] bounds];
	CGFloat x = ABLFieldInset + ABLFieldLabelWidth;
	[field setFrame:CGRectMake(x, 0.0f, content.size.width - x - ABLFieldInset, content.size.height)];
	[field setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[[cell contentView] addSubview:field];
	return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if ([indexPath section] == ABLEndpointSection) {
		switch ([indexPath row]) {
			case ABLBaseRow: return [self fieldCellWithTitle:@"Base URL" field:_baseField];
			case ABLKeyRow: return [self fieldCellWithTitle:@"API Key" field:_keyField];
			default: return [self fieldCellWithTitle:@"Model" field:_modelField];
		}
	}

	UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];
	[[cell textLabel] setFont:[UIFont boldSystemFontOfSize:17.0f]];

	if ([indexPath section] == ABLSecuritySection) {
		[[cell textLabel] setText:@"Trust Any Certificate"];
		[[cell textLabel] setFont:[UIFont boldSystemFontOfSize:15.0f]];
		[cell setSelectionStyle:UITableViewCellSelectionStyleNone];
		UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
		[toggle setOn:[[NSUserDefaults standardUserDefaults] boolForKey:ABLDefaultsTrustAnyCertificateKey]];
		[toggle addTarget:self action:@selector(trustSwitchChanged:) forControlEvents:UIControlEventValueChanged];
		[cell setAccessoryView:toggle];
		[toggle release];
		return cell;
	}

	[cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
	[[cell textLabel] setText:[indexPath row] == ABLReinstallRow ? @"Reinstall Everything" : @"Environment"];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:NO];
	if ([indexPath section] != ABLEnvironmentSection) {
		return;
	}
	if ([indexPath row] == ABLReinstallRow) {
		// It reinstalls the whole toolchain over a working one and takes
		// several minutes on a 3G, so it is asked about first.
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Reinstall Everything"
			message:@"Installs every package and the SDK again, whatever is already on this iPhone. This takes several minutes."
			delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Reinstall", nil];
		[alert show];
		[alert release];
		return;
	}
	[self openEnvironmentReinstalling:NO];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
	return orientation == UIInterfaceOrientationPortrait;
}

// Nil'd, not merely released: [super dealloc] unloads the view and
// UIViewController calls -viewDidUnload on the way, which releases it a
// second time. That is the crash this page left behind every time it was
// pushed and popped.
- (void)dealloc {
	[_tableView setDataSource:nil];
	[_tableView setDelegate:nil];
	[_tableView release];
	_tableView = nil;
	[_baseField setDelegate:nil];
	[_baseField release];
	_baseField = nil;
	[_keyField setDelegate:nil];
	[_keyField release];
	_keyField = nil;
	[_modelField setDelegate:nil];
	[_modelField release];
	_modelField = nil;
	[super dealloc];
}

@end
