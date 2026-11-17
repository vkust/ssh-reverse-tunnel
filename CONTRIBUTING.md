# Contributing

1. `python3 -m unittest discover -s tests -v` must pass.
2. `shellcheck -s sh install.sh srt` must be clean (POSIX sh only; no bashisms).
3. CI runs an install → add → remove → uninstall cycle on a throwaway HOME. Keep it passing.
4. Do not commit real hosts, IPs, passwords or keys. Use example addresses (192.0.2.0/24).
