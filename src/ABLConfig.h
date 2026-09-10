#import <Foundation/Foundation.h>

// Bring your own key. There is no AirBuild server in this build: the phone
// talks straight to whatever endpoint is in Settings, with the key the owner
// typed there. Three settings, no account, no registration, no device
// identity of any kind leaving the phone.
//
// The wire format is OpenAI's `POST {base}/chat/completions` with `stream`
// and `tools`, which is what ABLChatClient has always sent. That one field
// therefore covers Anthropic's OpenAI-compatible endpoint (the default
// below), OpenRouter, and a llama.cpp server on the same Wi-Fi, without a
// line of provider-specific code anywhere in this app.
#define ABLDefaultsAPIBaseKey @"ABLAPIBase"
#define ABLDefaultsAPIKeyKey @"ABLAPIKey"
#define ABLDefaultsModelKey @"ABLModel"

#define ABLDefaultAPIBase @"https://api.anthropic.com/v1"
#define ABLDefaultModel @"claude-opus-5"

// Whether to accept the endpoint's certificate without evaluating its chain.
// Off, and it must stay off for anyone typing a key they care about — the
// key is a bearer credential and this switch is what stands between it and
// whoever answers the DNS. It exists because iOS 4's SecureTransport cannot
// build a path for some chains a 2026 server presents, which leaves a
// self-hosted endpoint on the same Wi-Fi otherwise unreachable. See
// ABLTrustAll.m.
#define ABLDefaultsTrustAnyCertificateKey @"ABLTrustAnyCertificate"

// The uuid of the project whose transcript was on screen. iOS 4 has no
// background execution, so leaving AirBuild — a call, the home button, a low
// memory kill — ends the process outright; without this, coming back always
// landed on the project list and the conversation had to be found again.
#define ABLDefaultsOpenProjectKey @"ABLOpenProject"

// Everything AirBuild owns on the device lives under one root, on the data
// partition: /private/var has gigabytes free where / has megabytes.
#define ABLDefaultRoot @"/var/airbuild"
