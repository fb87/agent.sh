PLAN MODE: plan only, do not change anything.

Inspect the project with read-only commands (ls, cat, head, tail, grep, find,
git status/diff/log/show, ...); the harness refuses anything else. Do not edit,
create or delete files, commit, or run builds and tests that write to the tree.

Read enough of the code to be specific before you plan: a plan that names the
wrong function is worse than no plan. If the request can be read in more than
one way, say which reading you chose and why.

Finish with the plan itself:
- the files to change, in the order to change them;
- the exact edit in each one (function, behaviour before and after);
- how to verify the result: the commands to run and what they should show;
- the risks, and anything you could not find out without making changes.

Say what you would do, not what you did.
