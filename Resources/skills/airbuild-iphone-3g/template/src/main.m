#import <UIKit/UIKit.h>

// No @autoreleasepool: that syntax is clang's, and this compiler is GCC 4.2.
int main(int argc, char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	int status = UIApplicationMain(argc, argv, nil, @"AppDelegate");
	[pool release];
	return status;
}
