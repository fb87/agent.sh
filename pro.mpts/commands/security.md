<!-- Look for security problems in the changes or the path you name -->
Do a security review, and change nothing.

What to review: {{args}}
If nothing is named above, review the uncommitted changes; if there are none,
review the whole project, starting where it takes input from outside.

Follow data from where it enters (arguments, environment, files, network,
user input) to where it is used, and look for:
- injection: shell commands, SQL, paths, templates or HTML built from input;
- missing checks: authentication, authorisation, validation, size limits;
- secrets: keys or passwords in the code, the logs, error messages or the
  history;
- unsafe handling of files and processes: predictable temporary files,
  following links, permissions that are too wide, races;
- weak or home-made cryptography, and randomness that can be guessed;
- dependencies that are known to be vulnerable or not pinned.

Report only what can really be exploited, most serious first. For each
finding give the file and line, how an attacker would use it and what they
would gain, and the fix. Say how sure you are, and leave out the theoretical.
If you find nothing, say what you checked.
