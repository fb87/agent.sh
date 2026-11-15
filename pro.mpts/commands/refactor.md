<!-- Make code simpler to read without changing what it does -->
Refactor: {{args}}

If nothing is named above, refactor the code touched by the uncommitted
changes.

The behaviour must stay exactly the same; only the shape of the code changes.

1. Read the code and its callers. Run the tests first, so that you know they
   pass before you start; if there are none for this code, say so, and be more
   careful.
2. Say in a few lines what you will change and why it is better: a
   duplication removed, a long function split, a name that says what it means,
   dead code deleted.
3. Change one thing at a time and run the tests after each step.
4. Keep public names, signatures, output and error messages as they are,
   unless the user asked for them to change.

Do not fix bugs on the way: report the ones you see. Finish with what changed
and the test result.
