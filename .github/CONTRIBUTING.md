# How to Contribute

**Note**: contributing implies licensing those contributions under the terms of
[COPYING](../COPYING).

## Opening issues

* Make sure you have a [GitHub account](https://github.com/signup/free)
* [Submit an issue](https://github.com/thoughtpolice/eris/issues) - assuming one does not already exist.
  * Clearly describe the issue including steps to reproduce when it is a bug.
  * Include the git repository information, any changes, Nix version, etc.

## Submitting changes

* Always run tests. This can be done using the `check` target.
* Keep changes logically separated: one-commit-per-problem.
* Try to keep the code style the same where-ever you're writing patches; some
  things may differ. If some code is inconsistent, feel free to clean it up
  (in a separate commit first, then make your actual change).
* Try not to add lots of "superfluous commits" for typos, trivial compile
  errors, etc.
* The repository **MUST BUILD** with every single commit you author, and the
  tests **MUST PASS**, even if something you're implementing or changing is
  incomplete. This allows very useful tools like `git bisect` to work over time.

Regarding point #4 (and #5): for multi-commit requests, your code may get
squashed into the smallest possible logical changes and commiting with author
attribution in some cases.  In general, try to keep the history clean of things
like "fix typo" and "obvious build break fix", and this won't normally be
necessary.  Patches with these kinds of changes in the same series will
generally be rejected, but ask if you're unsure.

### Writing good commit messages

In addition to writing properly formatted commit messages, it's important to
include relevant information so other developers can later understand *why* a
change was made. While this information usually can be found by digging code,
mailing list/Discourse archives, pull request discussions or upstream changes,
it may require a lot of work.

* The first line of a commit message **SHOULD BE** 73 columns max.
* Always reference the issue you're working on in the bug tracker in your
  commit message, and if it fixes the issue, close it using the relevant
  syntax.
* Try to describe the relevant change in the following way:

  ```
  (component): (20,000 foot overview)

  (Motivation, reason for change)
  ```

  For consistency, there **SHOULD NOT** be a period at the end of the commit
  message's summary line (the first line of the commit message).

### Notes on sign-offs and attributions, etc.

When you commit, **please use -s to add a Signed-off-by line**. `Signed-off-by`
is interpreted as a very weak statement of ownership, much like Git itself: by
adding it, you make clear that the contributed code abides by the project
license, and you are rightfully contributing it yourself or on behalf of
someone. You should always do this.

This means that if the patch you submit was authored by someone else -- perhaps
a coworker for example that you submit it from or you revive a patch that
someone forgot about a long time ago and resubmit it -- you should also include
their name in the details if possible.
