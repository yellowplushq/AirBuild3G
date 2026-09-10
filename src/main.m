#import <UIKit/UIKit.h>

// There used to be four lines of setup here, and all four were consequences of
// one decision: the app binary was installed setuid root, so main() raised its
// uid before UIKit started and then had to put the home directory back where
// the phone actually keeps things, because root's is /var/root and neither the
// photo library nor the preferences live there.
//
// AirBuild runs as mobile now, like any other app. Root is reached one command
// at a time through `airbuildhelper` (see ABLPrivileged.h), the home directory
// is already the right one, and there is nothing left to do before
// UIApplicationMain.
int main(int argc, char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	int status = UIApplicationMain(argc, argv, nil, @"HelloAppDelegate");
	[pool release];
	return status;
}
