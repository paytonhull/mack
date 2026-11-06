# Security

M.A.C.K. runs a tiny web server on your own Mac. It binds to `127.0.0.1` only, so it is not reachable from other computers, and it serves only the files bundled with the app plus a JSON feed of system statistics.

If you find a security problem, please report it privately using GitHub's *Report a vulnerability* button on the repository's **Security** tab (or contact the maintainer directly) instead of opening a public issue. Please include steps to reproduce.

Things that are good to know:

- Do not change the server to listen on `0.0.0.0` or another network address: it would expose your process list and system details to your network.
- Setting `MACMON_HOST` only changes the hostname shown on screen.
