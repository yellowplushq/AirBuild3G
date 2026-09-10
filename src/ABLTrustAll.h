#import <Foundation/Foundation.h>

// Loads TLSFix into this process if it is installed and not yet loaded.
// Idempotent. Called at launch and again before every request, so an install
// made from the Environment page takes effect without relaunching the app.
void ABLLoadTLSFix(void);

// Whether the owner has turned Trust Any Certificate on in Settings. Off
// unless they did. Read on every trust decision rather than cached, so the
// switch takes effect on the next request instead of the next launch.
BOOL ABLTrustAnyCertificate(void);
