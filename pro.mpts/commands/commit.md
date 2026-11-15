<!-- Commit the current changes with a message that fits the repository -->
Commit the current changes.

1. Run `git status --short` and `git diff HEAD` to see what changed, and
   `git log --oneline -10` to see how this repository writes its messages.
2. If the changes are several unrelated things, make one commit for each.
   Stage files by name; do not add files that look like secrets, build output
   or editor leftovers, and say which ones you left out.
3. Write the message in the repository's style: a subject line of at most 72
   characters that says what the commit does, then, when the reason is not
   obvious from the diff, a blank line and a short body that gives it.
4. Commit with `git commit -m` (never the editor) and show the result with
   `git log --oneline -3`.

Do not push, amend or rewrite existing commits. If there is nothing to commit,
say so.

{{args}}
