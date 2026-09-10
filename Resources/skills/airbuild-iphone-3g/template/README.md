# Single-view app template

Four files and a Makefile. It builds, signs, packages and installs on the
phone with `make install`, and it is meant to be edited rather than read.

```
src/main.m                 NSAutoreleasePool + UIApplicationMain
src/AppDelegate.{h,m}      window, navigation controller
src/RootViewController.{h,m}   the screen — start here
Info.plist                 bundle id, URL scheme, MinimumOSVersion 4.0
Makefile                   all / package / install / run / clean
```

```sh
make install    # compile, sign, package, dpkg -i, uicache
make run        # uiopen <scheme>://
```

The rules this code already follows, because breaking them fails at runtime
rather than at compile time:

- manual `retain`/`release`; there is no ARC on this compiler
- no blocks, no `@autoreleasepool`, no `@[]`/`@{}`/`@42`
- iOS 4.0 API only, and 4.0-only selectors probed with `respondsToSelector:`
- frame-based layout with autoresizing masks; `-viewDidLayoutSubviews` is
  iOS 5 and is never called here
