## Description
<!--
Provide a clear overview of what this PR does and why.
See .omni-dev/pr-guidelines.md for detailed guidance.
-->

## Type of Change
<!-- Mark ALL relevant options with an "x" -->
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] CI/CD changes

## Related Issue
<!-- Link to issues this PR addresses -->
Fixes #(issue_number)

## Changes Made
<!-- List specific changes organized by category -->

**Action Definition:**
-
-

**Documentation:**
-
-

## Testing
<!-- Describe testing performed -->

**Manual Testing:**
- [ ] Verified the coverage PR comment posts
- [ ] Verified baseline download + worktree fallback
- [ ] Verified the line / patch gates
- [ ] Verified thin mode with a supplied lcov

**Example Test Workflow:**
```yaml
- uses: action-works/omni-dev-coverage-check@this-branch
  with:
    worktree-system-deps: libasound2-dev
```

## Checklist
<!-- Mark completed items with an "x" -->
- [ ] My changes follow the project's commit guidelines
- [ ] I have updated the README if inputs/outputs changed
- [ ] I have tested the action in a real workflow
- [ ] I have read the [PR Guidelines](../.omni-dev/pr-guidelines.md)

## Breaking Changes
<!-- Only for breaking changes - provide migration instructions -->

**Migration Required:**
1.

**Backward Compatibility:**
-
