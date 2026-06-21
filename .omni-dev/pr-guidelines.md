# Pull Request Guidelines

This document provides guidelines for writing effective pull request descriptions for the omni-dev-coverage-check GitHub Action.

## Overview

A well-written pull request serves multiple purposes:

- **Documentation**: Explains what changed and why
- **Review Aid**: Helps reviewers understand context and focus areas
- **Project History**: Creates searchable record for future reference
- **Quality Assurance**: Ensures all necessary steps are completed

### Key Principles

1. **Clarity**: Write for reviewers who may not have context
2. **Completeness**: Include all necessary information for review
3. **Conciseness**: Be thorough but avoid unnecessary verbosity
4. **Actionability**: Provide clear testing and validation steps

## AI-Generated PR Descriptions

**CRITICAL FOR AI ASSISTANTS**: When generating PR descriptions, you MUST:

1. **ALWAYS REPLACE PLACEHOLDERS**: Never leave placeholder text like "TODO", "FIXME", or generic instructions
2. **FILL IN ACTUAL CONTENT**: Every section must contain specific information based on actual code changes
3. **BE SPECIFIC ABOUT CHANGES**: List exact files, inputs, and features modified
4. **NO GENERIC TEXT**: Avoid generic statements like "various improvements"
5. **REMOVE TEMPLATE COMMENTS**: Delete all HTML comments and instructional text
6. **ANALYZE THE DIFFS**: Read through all commit diffs to understand what changed
7. **PROVIDE REAL EXAMPLES**: If the template asks for test workflows, provide actual YAML
8. **COMPLETE ALL CHECKLISTS**: Mark items as checked `[x]` only if actually completed

### What NOT to Do

**NEVER do this:**
```markdown
## Description
<!-- Provide a clear overview of changes -->
Add description here.

## Changes Made
**Action Definition:**
-
-
```

**ALWAYS do this instead:**
```markdown
## Description
This PR adds a `fail-under-patch` input that gates the build on patch coverage. The gate runs after the sticky PR comment is posted, so the comment still appears when the gate fails.

## Changes Made
**Action Definition:**
- Added `fail-under-patch` input with no default (gate disabled unless set)
- Added an "Enforce patch-coverage gate" step that runs `omni-dev coverage diff --fail-under-patch` after the comment step
- Documented the new input and gate ordering in README
```

### AI Generation Checklist

Before returning a PR description, verify:
- [ ] All HTML comments and instructional text removed
- [ ] All placeholder bullet points replaced with actual content
- [ ] Specific file names and inputs mentioned where relevant
- [ ] Test workflow examples are actual YAML, not placeholders
- [ ] Checklist items accurately reflect what was done
- [ ] No sections left empty (either fill them or remove them)
- [ ] Description explains WHAT changed and WHY based on actual commits

## PR Title Guidelines

### Format
Use conventional commit format:
```
<type>(<scope>): <description>
```

### Types
- `feat`: New features or enhancements (new inputs, outputs, behavior)
- `fix`: Bug fixes
- `docs`: Documentation changes (README, examples)
- `refactor`: Code restructuring without functional changes
- `chore`: Maintenance tasks, dependency updates
- `ci`: CI/CD pipeline changes

### Scope Examples
- `action`: Changes to action.yml
- `docs`: Documentation updates
- `ci`: Workflow changes

### Title Best Practices

**Good Examples:**
- `feat(action): add thin mode via run-coverage input`
- `fix(action): rewrite worktree lcov paths for renamed report`
- `docs(docs): add baseline-publish-on-main example`

**Avoid:**
- `Update action` (too vague)
- `Fix bug` (no context)
- `Add new feature` (too verbose)

## Template Section Guidelines

### Description Section
- Start with one-sentence summary
- Explain the problem being solved
- Describe the solution approach
- Mention user-facing impact

### Type of Change Section
- Select all applicable types
- Use "Breaking change" sparingly and document migration
- Choose "Bug fix" only for actual defects

### Changes Made Section
- Be specific about what was changed
- Group related changes (Action Definition, Documentation, CI)
- Focus on significant changes

**Example:**
```markdown
## Changes Made

**Action Definition:**
- Added `worktree-system-deps` input for the merge-base fallback build
- Installs the listed apt packages only on the worktree recompute path
- Updated the baseline-fallback step to honor the new input

**Documentation:**
- Added a "Baseline mechanism" section to README
- Documented `worktree-system-deps` in the inputs table
```

### Testing Section
- Include both automated testing (if applicable) and manual testing
- Provide specific workflow examples users can copy
- Note edge cases tested

**Example:**
```markdown
## Testing

**Manual Testing:**
- [x] Verified the PR comment posts on a pull request
- [x] Verified baseline download + worktree fallback on a cold start
- [x] Verified the line gate fails the build below the threshold
- [x] Verified thin mode (run-coverage: false) with a supplied lcov

**Example Test Workflow:**
```yaml
- uses: action-works/omni-dev-coverage-check@this-branch
  with:
    worktree-system-deps: libasound2-dev
```
```

### Breaking Changes Section
Only use for actual breaking changes:
- Provide clear migration instructions
- Include before/after examples
- Explain backward compatibility status

## Common Patterns

### Adding a New Input
```markdown
## Description
Adds `comment-header` input to control the sticky PR comment key, letting repos run multiple coverage comments without collisions.

## Changes Made
**Action Definition:**
- Added `comment-header` input with default value `coverage`
- Passed it to marocchino/sticky-pull-request-comment as `header`

**Documentation:**
- Added comment-header to the inputs table in README
```

### Bug Fix
```markdown
## Description
Fixes an issue where the worktree baseline fallback wrote to the wrong path when the `report` input was renamed, leaving the diff without a baseline.

## Root Cause
The fallback hard-coded `coverage-head.lcov` instead of deriving the basename from the `report` input.

## Solution
Compute `REPORT_BASENAME` from `report` and use it consistently across download, fallback, and diff steps.
```

### Documentation Update
```markdown
## Description
Adds comprehensive examples for fat and thin modes, plus a CircleCI counterpart note.

## Changes Made
**Documentation:**
- Added fat-mode quick-start example
- Added thin-mode example with a caller-supplied lcov
- Documented outputs and the gate ordering
```
