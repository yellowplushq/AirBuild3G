#import <UIKit/UIKit.h>
CGImageRef UIGetScreenImage(void);
int main(int argc, char **argv) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	CGImageRef ref = UIGetScreenImage();
	if (ref == NULL) { fprintf(stderr, "UIGetScreenImage failed\n"); return 1; }
	UIImage *image = [UIImage imageWithCGImage:ref];
	NSData *png = UIImagePNGRepresentation(image);
	BOOL ok = [png writeToFile:[NSString stringWithUTF8String:argc > 1 ? argv[1] : "/tmp/shot.png"] atomically:YES];
	CGImageRelease(ref);
	[pool drain];
	return ok ? 0 : 2;
}
