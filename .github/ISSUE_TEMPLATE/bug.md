---
name: Bug report
about: Report a bug that exists with Eris
labels: 'A-bug'

---

## Issue description

Describe the bug as clearly as possible.

### Steps to reproduce

Provide steps to reproduce the behavior, including configuration of the server
and how to trigger the behavior.

## Technical details

Please run:

```bash
printf ' - eris revision: ' && echo $(git rev-parse HEAD) && nix run nixpkgs.nix-info -c nix-info -m
```

from the root of the project directory, and paste the results here.
