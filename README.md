# Call of Duty Black Ops Cold War - keyboard fix

Adresses [Bug 59540](https://bugs.winehq.org/show_bug.cgi?id=59540), the content was created by the reporter, daniel, I only improved on the codebase (notably the C code).

tl;dr there are missing function calls from Wine, notably NotifyIME and ImeSetActiveContext. Cold War uses those to track whether or not you're in a textbox. This tool will send those events automatically every 2s by default. In theory, this should also work for other games that suffer from the same issue (simply chaning the APPID should do it).

## How to run it
Install mingw64-gcc and its headers:
```bash
sudo pacman mingw-w64-gcc mingw-w64-headers
```

Clone the repo. Then, in the folder run:
```bash
make
```

Once built you have a few options, you can run it standalone or via steam launch option.

### Steam Launch options
In your launch parameters for Cold War:
```bash
/path/to/ime-fixer.sh --endcomp %command%
```

### Standalone
```bash
./ime-fixer.sh --run-helper           # one-shot
# or
./ime-fixer.sh --run-helper --hotkey  # F12 to send
# or
./ime-fixer.sh --run-helper --periodic # auto every 2s
```

## Troubleshooting
If it doesn't run, check your Steam library location and add it to the FALLBACK_LIBRARIES.

## Known issues
- The game stays running on Steam, due to script not exitting gracefully, requiring you to forcefully stop it via Steam.
- Not an issue per se but... The delay between the event dispatches is 2 seconds by default, which COULD lead to a situation where you're standing in place, waiting for program to free you.
