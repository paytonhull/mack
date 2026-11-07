#!/usr/bin/env python3
"""Builds the App Store variant of the web files from the shared ones.

The shared war.html (used by the open-source build) keeps its film-inspired wording. For the App Store build we reword
anything that quotes the 1983 film, rename the show, and swap the live-feed presets. Every replacement asserts it matched,
so if war.html changes this script fails loudly instead of silently shipping old text.
Run from anywhere:  python3 appstore/tools/make-store-web.py
"""
import os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.abspath(os.path.join(HERE, "..", "web"))

# (old, new, how many times old must occur)
WAR = [
    # the show's name
    ("GLOBAL THERMONUCLEAR WAR (NICE EDITION)", "GLOBAL MELTDOWN (NICE EDITION)", 1),
    ("<li><b>Global Thermonuclear War:</b>", "<li><b>Global Meltdown:</b>", 1),
    ("'NO. GLOBAL THERMONUCLEAR WAR.'", "'NO. GLOBAL MELTDOWN.'", 1),
    ("ACCESS DENIED. TRY: GLOBAL THERMONUCLEAR WAR", "ACCESS DENIED. TRY: GLOBAL MELTDOWN", 1),
    # quoted lines and the games menu
    ("'WOULDN\\'T YOU PREFER'", "'HOW ABOUT'", 0),   # (handled below, double-quoted in source)
    ("\"WOULDN'T YOU PREFER\"", "'HOW ABOUT'", 1),
    ("'A GOOD GAME OF CHESS?'", "'A QUIET GAME OF CHESS?'", 1),
    ("SHALL WE PLAY A GAME?", "WANT TO PLAY A GAME?", 3),
    ("SHALL WE PLAY AGAIN?", "PLAY AGAIN?", 1),
    ("['A STRANGE GAME.', 'THE ONLY WINNING MOVE IS NOT TO PLAY.']", "['A DRAW.', 'SOME GAMES CANNOT BE WON.']", 1),
    ("'A STRANGE GAME.'", "'A DRAW.'", 1),
    ("'THE ONLY WINNING MOVE'", "'SOME GAMES'", 1),
    ("'IS NOT TO PLAY.'", "'CANNOT BE WON.'", 1),
    ("HOW ABOUT A NICE GAME OF CHESS?", "MAYBE CHESS INSTEAD?", 2),
    ("'GREETINGS PROFESSOR.'", "'GOOD EVENING.'", 1),
    ("Snd.say('Greetings, Professor. Shall we play a game?')", "Snd.say('Good evening. Want to play a game?')", 1),
    ("Snd.say('The only winning move is not to play.')", "Snd.say('Some games cannot be won.')", 1),
    ("PW = 'JOSHUA'", "PW = 'KERNEL'", 1),
    # live-feed presets: drop the commercial news channel, add the Lofi Girl channel (resolved to whatever is live)
    ("[['SYNTHWAVE', '4xDzrJKXOOY'], ['NASA LIVE', 'UCLA_DiR1FfKNvjuUpBHmylQ'], ['SKY NEWS', 'UCoMdktPbSTixAyNGwb-UYkQ']]",
     "[['SYNTHWAVE', '4xDzrJKXOOY'], ['LOFI RADIO', 'UCSJ4gkVC6NrvII8umztf0Ow'], ['NASA LIVE', 'UCLA_DiR1FfKNvjuUpBHmylQ']]", 1),
]
GAMES_OLD = ("const GAMES = ['CHESS', 'CHECKERS', 'POKER', 'FIGHTER COMBAT', 'GUERRILLA ENGAGEMENT', 'DESERT WARFARE', 'AIR-TO-GROUND ACTIONS',\n"
             "  'THEATERWIDE TACTICAL WARFARE', 'THEATERWIDE BIOTOXIC AND CHEMICAL WARFARE', 'GLOBAL THERMONUCLEAR WAR'];")
GAMES_NEW = ("const GAMES = ['CHESS', 'CHECKERS', 'POKER', 'DOGFIGHT ACE', 'TREASURE HUNT', 'DESERT RALLY', 'AIR TRAFFIC CONTROL',\n"
             "  'MOON BASE LOGISTICS', 'BACTERIA BAKE-OFF', 'GLOBAL MELTDOWN'];")

def main():
    s = open(os.path.join(SRC, "war.html"), encoding="utf-8").read()
    assert s.count(GAMES_OLD) == 1, "games list not found"
    s = s.replace(GAMES_OLD, GAMES_NEW)
    for old, new, n in WAR:
        if n == 0: continue
        c = s.count(old)
        assert c == n, f"expected {n} x {old!r}, found {c}"
        s = s.replace(old, new)
    # whatever is left of the show's old name (comments, headers, the caption, the alert reason)
    s = s.replace("GLOBAL THERMONUCLEAR WAR", "GLOBAL MELTDOWN")
    leftover = [w for w in ("THERMONUCLEAR", "PROFESSOR", "WINNING MOVE", "JOSHUA", "FALKEN", "SHALL WE", "STRANGE GAME", "NICE GAME OF CHESS", "WarGames") if w.lower() in s.lower()]
    assert not leftover, f"film wording still present: {leftover}"
    shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT)
    open(os.path.join(OUT, "war.html"), "w", encoding="utf-8").write(s)
    shutil.copy(os.path.join(SRC, "index.html"), os.path.join(OUT, "index.html"))
    print("store web files written to", OUT)

if __name__ == "__main__":
    sys.exit(main())
