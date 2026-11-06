#!/bin/bash
# Run M.A.C.K. in your web browser, no build step needed.
# Usage: ./run.sh            (opens the 3D war room)
#        PORT=9000 ./run.sh  (use another port)
cd "$(dirname "$0")"
PORT="${PORT:-8765}"
export PORT
echo "M.A.C.K. running at http://localhost:$PORT/war   (Ctrl-C to stop)"
( sleep 1.5; open "http://localhost:$PORT/war" ) &
exec python3 server.py
