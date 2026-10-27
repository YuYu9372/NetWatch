NetWatch 2.0.0
==============
Native macOS menu bar app (C++ / Objective-C++) that alerts you, with a sound
and a notification, when your internet connection drops and when it returns,
and shows what your Wi-Fi is doing. See README.md for full details.

Layout
- src/NetWatch.mm       Objective-C++ source (main app, ~1080 lines)
- assets/ping.mp3       Alert sound
- packaging/Info.plist  App bundle metadata
- Makefile              Build rules
- build/NetWatch.app    Build output (generated)
- .backup/cpp-1.2.0     Snapshot of the earlier C++ version 1.2.0
- .backup/python-1.1.4  Snapshot of the original Python version 1.1.4
- C++/                  Empty folder
- LICENSE, README.md, .gitignore
- .git                  Git repo with a branch per version (1.0.0 ... 2.0.0, main)

Build / run
- make        build build/NetWatch.app
- make run    build and launch
- make clean  delete build/
Requires Xcode command line tools.
