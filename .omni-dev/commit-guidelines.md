# omni-dev-coverage-check Commit Guidelines

This project follows conventional commit format with specific requirements.

## Severity Levels

| Severity | Sections                                                               |
|----------|------------------------------------------------------------------------|
| error    | Commit Format, Types, Scopes, Subject Line, Accuracy, Breaking Changes |
| warning  | Body Guidelines, Scope Specificity                                     |
| info     | Subject Line Style                                                     |

## Commit Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

Multiple scopes can be specified using comma separation:

```
<type>(<scope1>,<scope2>): <description>
```

## Scope Specificity

The type and scope may be the same (e.g., `ci(ci)`, `docs(docs)`) when the change category matches the area of code modified. However, prefer a more specific scope when possible (e.g., `ci(action)` over `ci(ci)` if the CI change is in the action definition).

## Types

Required. Must be one of:

| Type       | Use for                                               |
|------------|-------------------------------------------------------|
| `feat`     | New features or enhancements to existing features     |
| `fix`      | Bug fixes                                             |
| `docs`     | Documentation changes only                            |
| `refactor` | Code refactoring without behavior changes             |
| `chore`    | Maintenance tasks, dependency updates, config changes |
| `test`     | Test additions or modifications                       |
| `ci`       | CI/CD pipeline changes                                |

### Type Precedence

When a commit includes multiple types of changes, use the type that reflects the **primary functional change**:

- If adding a new feature AND updating docs to describe it → use `feat`
- If fixing a bug AND updating docs about it → use `fix`
- If ONLY updating documentation with no functional changes → use `docs`

The type should reflect what the code does, not what files were touched. Documentation updates that accompany functional changes are expected and don't change the commit type.

## Scopes

Required. Use scopes defined in `.omni-dev/scopes.yaml`:

- `action` - GitHub Action definition and composite steps (`action.yml`)
- `docs` - Documentation (README, examples, guidelines)
- `ci` - GitHub workflows and automation (`.github/workflows/`)

### Multiple Scopes

When a commit modifies files in multiple scope areas, **all relevant scopes must be listed**:

- Modifying `action.yml` AND `README.md` → use `feat(action,docs): ...`
- Modifying `action.yml` AND `.github/workflows/` → use `feat(action,ci): ...`
- Modifying only `action.yml` → use `feat(action): ...`

This is required even when documentation updates are incidental to the primary change. The scopes should reflect all areas of code that were modified.

## Subject Line

- Keep under 72 characters total
- Use imperative mood: "add feature" not "added feature" or "adds feature"
- Be specific: avoid vague terms like "update", "fix stuff", "changes"

## Subject Line Style

- Use lowercase for the description
- No period at the end

## Accuracy

The commit message must accurately reflect the actual code changes:

- **Type must match changes**: Don't use `feat` for a bug fix, or `fix` for new functionality
- **Scope must match files**: The scope should reflect which area of code was modified
- **Description must be truthful**: Don't claim changes that weren't made
- **Mention significant changes**: If you add new inputs, outputs, or change behavior, mention it

## Body Guidelines

For significant changes (new inputs/outputs or behavior changes), include a body:

- Explain what was changed and why
- Describe the approach taken
- Note any breaking changes or migration requirements
- Use bullet points for multiple related changes
- Reference issues in footer: `Closes #123` or `Fixes #456`

## Breaking Changes

For breaking changes:
- Add `!` after type/scope: `feat(action)!: change default fail-under-lines`
- Include `BREAKING CHANGE:` footer with migration instructions

## Examples

### Simple change
```
fix(action): handle missing baseline artifact gracefully
```

### Feature with body (single scope)
```
feat(action): add fail-under-patch input for patch-coverage gating

Adds a fail-under-patch input that maps to
`omni-dev coverage diff --fail-under-patch`. The gate is enforced after
the PR comment is posted so the comment still appears when it fails.

Closes #5
```

### Feature with documentation (multiple scopes)
```
feat(action,docs): add thin mode via run-coverage and report inputs

Adds a run-coverage toggle that lets callers supply their own lcov via
the report input, skipping the built-in cargo-llvm-cov pipeline.

Changes:
- Add run-coverage and report inputs to action.yml
- Gate the cargo-llvm-cov steps on run-coverage
- Document fat vs thin mode in README
```

### Documentation update
```
docs(docs): add CircleCI counterpart note
```

### Multiple scopes
```
feat(action,ci): add release workflow and version output
```

### Breaking change
```
feat(action)!: rename report input to head-report

BREAKING CHANGE: The `report` input is now `head-report`. Update
workflows that set `report:` to use `head-report:` instead.
```
