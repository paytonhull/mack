# Contributing

Thanks for helping! M.A.C.K. is a small, friendly project and all kinds of contributions are welcome: bug reports, ideas, new screens, fixes, docs.

## Report a bug or suggest something

Open an issue on GitHub. For a bug, please include:

- your macOS version and whether it is Apple Silicon or Intel
- what you did, what you expected and what happened
- anything shown in `/tmp/macmon-debug.log` (it holds no personal data)

## Run it while you work on it

You don't need to rebuild the app to try changes. Run the server straight from the folder and open it in a browser:

```bash
./run.sh          # http://localhost:8765/war
```

Edit `war.html` (the 3D war room), refresh the page, and see the change. The whole app is plain HTML/JavaScript, Python (standard library only) and one Swift file, so there is no package manager and nothing to install.

Developer helpers:

- `http://localhost:8765/war?show=20` jumps into the war show 20 seconds in.
- `open MacMon.app --args --war` opens the war-room window at launch.

## Pull requests

1. Fork the repo and make your change on a branch.
2. Keep it small and focused. Match the style of the code around it.
3. Check that `./build.sh` still succeeds and that the war room loads without errors (the page shows errors in a red box at the top left).
4. Describe what you changed and why in the pull request.

## Ideas that would be great

- Intel Mac and older macOS testing and fixes
- More screens (battery, temperatures, Wi-Fi, per-process drill-down)
- A settings screen (port, hostname, default sound state)
- More games for the games menu

## Licensing of contributions

By submitting a contribution you agree it is licensed under the project's MIT license. Don't add anything you don't have the right to share (music, images, code with an incompatible licence).
