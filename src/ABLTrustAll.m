#import "ABLTrustAll.h"
#import "ABLConfig.h"
#import <Security/SecTrust.h>

#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

BOOL ABLTrustAnyCertificate(void) {
	return [[NSUserDefaults standardUserDefaults] boolForKey:ABLDefaultsTrustAnyCertificateKey];
}

// TLSFix (MobileSubstrate, CFNetwork) speaks TLS 1.2 for us, then evaluates
// the chain with SecTrustEvaluate before NSURLConnection's server-trust
// challenge runs. iOS 4.2.1 has no BreakOnServerAuth, so that evaluation is
// what actually decides the handshake — and a 2010 trust store cannot always
// build a path a 2026 server expects it to.
//
// Overriding that decision is a real hole and it is off by default: this hook
// passes the original result through untouched unless the owner has turned
// Trust Any Certificate on. Checked per call, not at install time, so the
// switch does not need a relaunch — and so a phone that had it on for a local
// endpoint is back to real validation the moment it is turned off.
static OSStatus (*ABLOriginalSecTrustEvaluate)(SecTrustRef trust, SecTrustResultType *result);

static OSStatus ABLSecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
	// No trampoline means there is no evaluation to report, so fail closed and
	// write the out-param -- returning success without touching it leaves the
	// caller reading an uninitialized SecTrustResultType off its own stack.
	if (ABLOriginalSecTrustEvaluate == NULL) {
		if (result != NULL) {
			*result = kSecTrustResultRecoverableTrustFailure;
		}
		return errSecParam;   // the 4.1 SDK defines only this and errSecSuccess
	}
	OSStatus status = ABLOriginalSecTrustEvaluate(trust, result);
	if (!ABLTrustAnyCertificate()) {
		return status;
	}
	if (result != NULL) {
		*result = kSecTrustResultUnspecified;
	}
	return errSecSuccess;
}

// Without TLSFix, SecureTransport offers TLS 1.0 only and openrouter.ai
// rejects the ClientHello before any trust decision is made.
//
// MobileSubstrate injects it on its own now that the app is an ordinary mobile
// process — it could not while the app was setuid, because dyld strips
// DYLD_INSERT_LIBRARIES from a setuid image, and loading the tweak by hand was
// the only way to have it at all. It is still loaded by hand here, for the one
// case injection cannot cover: a phone that has just installed the tweak from
// the Environment page and has not been relaunched. Its constructor hooks
// SecureTransport and links CydiaSubstrate itself, and dlopen of an
// already-loaded image is a no-op, so calling this before every request costs
// nothing.
typedef void (*ABLHookFunction)(void *symbol, void *replace, void **result);

static ABLHookFunction ABLSubstrateHook(void) {
	void *substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
	if (substrate == NULL) {
		substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
	}
	return substrate != NULL ? (ABLHookFunction)dlsym(substrate, "MSHookFunction") : NULL;
}

// TLSFix bridges CFNetwork's socket into OpenSSL, and its SSLWrite answers
// a write the socket could not take whole with errSSLWouldBlock and
// "nothing processed". SecureTransport never says that: it queues every
// byte it was given and reports all of them processed before it says would
// block, and CFNetwork is written to that contract -- on TLSFix's answer it
// frees the connection at once, tries twice more from scratch, and the
// person sees "An SSL error has occurred". Only a write bigger than the
// socket's free buffer, about 128 KB, ever blocks, so it took a 140 KB
// request -- a photo -- to find it: 130 KB got through on the reference 3GS,
// 140 KB did not, and the same bytes reached the server from a Mac.
//
// TLSFix exports its OpenSSL, so its SSL_write is wrapped from here: a write
// OpenSSL could not finish is retried, with the same arguments as OpenSSL
// requires, until the socket has drained enough to take it. That holds
// CFNetwork's loader thread for the milliseconds the kernel needs, which is
// what a blocking write is. Partial-write mode makes every call return as
// soon as one record is out, so nothing waits longer than one record.
static int (*ABLOriginalSSLWrite)(void *ssl, const void *buffer, int length);
static int (*ABLSSLGetError)(const void *ssl, int result);
static void (*ABLOriginalSSLSetConnectState)(void *ssl);
static long (*ABLSSLCtrl)(void *ssl, int command, long argument, void *pointer);
enum {
	ABLSSLCtrlMode = 33,                    // SSL_CTRL_MODE
	ABLSSLModePartialWrite = 0x1,           // SSL_MODE_ENABLE_PARTIAL_WRITE
	ABLSSLModeMovingBuffer = 0x2,           // SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
	ABLSSLErrorWantWrite = 3,               // SSL_ERROR_WANT_WRITE
};
static const useconds_t ABLSSLWriteRetryInterval = 10 * 1000;   // 10 ms
static const unsigned ABLSSLWriteRetryLimit = 6000;            // a minute

static int ABLSSLWrite(void *ssl, const void *buffer, int length) {
	int result = ABLOriginalSSLWrite(ssl, buffer, length);
	unsigned retries = 0;
	while (result <= 0 && ABLSSLGetError(ssl, result) == ABLSSLErrorWantWrite
			&& retries++ < ABLSSLWriteRetryLimit) {
		usleep(ABLSSLWriteRetryInterval);
		result = ABLOriginalSSLWrite(ssl, buffer, length);
	}
	return result;
}

static void ABLSSLSetConnectState(void *ssl) {
	ABLSSLCtrl(ssl, ABLSSLCtrlMode, ABLSSLModePartialWrite | ABLSSLModeMovingBuffer, NULL);
	ABLOriginalSSLSetConnectState(ssl);
}

// Called from the chat client before every request, from whichever thread the
// turn is on; the hook must be placed exactly once.
static pthread_mutex_t ABLTLSFixLock = PTHREAD_MUTEX_INITIALIZER;

void ABLLoadTLSFix(void) {
	void *tlsfix = dlopen("/Library/MobileSubstrate/DynamicLibraries/tlsfix.dylib", RTLD_NOW);
	if (tlsfix == NULL) {
		return;   // not installed yet; the next request tries again
	}
	pthread_mutex_lock(&ABLTLSFixLock);
	if (ABLOriginalSSLSetConnectState == NULL) {
		ABLHookFunction hook = ABLSubstrateHook();
		void *setConnectState = dlsym(tlsfix, "SSL_set_connect_state");
		void *write = dlsym(tlsfix, "SSL_write");
		ABLSSLCtrl = dlsym(tlsfix, "SSL_ctrl");
		ABLSSLGetError = dlsym(tlsfix, "SSL_get_error");
		if (hook != NULL && setConnectState != NULL && write != NULL
				&& ABLSSLCtrl != NULL && ABLSSLGetError != NULL) {
			hook(write, (void *)ABLSSLWrite, (void **)&ABLOriginalSSLWrite);
			hook(setConnectState, (void *)ABLSSLSetConnectState, (void **)&ABLOriginalSSLSetConnectState);
		}
	}
	pthread_mutex_unlock(&ABLTLSFixLock);
}

__attribute__((constructor))
static void ABLInstallTrustAll(void) {
	ABLLoadTLSFix();
	ABLHookFunction MSHookFunction = ABLSubstrateHook();
	void *evaluate = dlsym(RTLD_DEFAULT, "SecTrustEvaluate");
	if (MSHookFunction == NULL || evaluate == NULL) {
		return;
	}
	MSHookFunction(evaluate, (void *)ABLSecTrustEvaluate, (void **)&ABLOriginalSecTrustEvaluate);
}
