<!-- Investigate a problem and report its cause without changing code -->
Investigate this problem and report the cause. Do not fix it: {{args}}

Work like this:
1. Reproduce the problem and write down exactly what happens against what
   should happen.
2. Form a guess about the cause, then run the command or read the code that
   would prove it wrong. Keep going until one explanation survives.
3. Narrow it down: the smallest input that triggers it, the line where things
   first go wrong, and, when the history helps, the commit that brought it in
   (`git log -S`, `git blame`).

You may add temporary output to see what is going on, but remove it again and
leave the tree as you found it (`git status` should show no change of yours).

Report the cause with the evidence for it (file, line, the output that shows
it), how sure you are, and the fix you would make.
