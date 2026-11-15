<!-- Review the uncommitted changes, or the commit, branch or path you name -->
Review code, and change nothing.

What to review: {{args}}
If nothing is named above, review the uncommitted changes (`git diff HEAD`,
plus untracked files from `git status --short`). If there are none, review the
last commit.

Read the surrounding code as well as the diff: most real problems are in how a
change meets the code around it. Look for, in this order:
1. bugs: wrong logic, unhandled errors, edge cases (empty, missing, very
   large, concurrent), broken callers;
2. security problems: unchecked input, injection, leaked secrets, unsafe file
   or shell handling;
3. missing or wrong tests and documentation for what changed;
4. needless complexity and code that duplicates something already there.

Report the findings most serious first. For each one give the file and line,
what goes wrong and when, and the fix you suggest. Leave out matters of taste
and anything you are not sure is a problem; if you had to guess how something
is used, say so. If you find nothing, say that and say what you checked.
