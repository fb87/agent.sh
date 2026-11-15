<!-- Find the cause of a bug or failing command and fix it -->
Fix this problem: {{args}}

If nothing is described above, run the project's tests or build, and fix what
fails.

1. Reproduce it first: run the command that shows the problem and read the
   whole error. If you cannot reproduce it, say so and stop.
2. Find the cause, not just the place where it shows. Read the code involved
   and check your explanation against it before changing anything.
3. Make the smallest change that removes the cause. Do not tidy up unrelated
   code on the way.
4. Run the reproducing command again to show the problem is gone, then the
   tests, to show nothing else broke.

Finish with the cause in one or two sentences, what you changed, and what you
ran to check it.
