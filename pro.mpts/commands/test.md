<!-- Write tests for the code you name, or for the uncommitted changes -->
Write tests.

What to test: {{args}}
If nothing is named above, test the code touched by the uncommitted changes.

1. Find how this project tests: the framework, where test files live, how
   they are named and how they are run. Follow those conventions; do not add
   a new framework or dependency without asking.
2. Read the code under test and list its behaviours: the normal case, the
   edges (empty, missing, boundary values, bad input) and the error paths.
3. Write a test for each behaviour. A test checks what the code promises, not
   how it is written, and its name says what it checks.
4. Run the tests and show the result. If a test fails because the code is
   wrong, do not bend the test to pass: report the bug and leave the fix to
   the user.

Finish with what is covered and what is not.
