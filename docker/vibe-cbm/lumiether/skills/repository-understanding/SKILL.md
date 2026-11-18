---
name: repository-understanding
description: Investigate repository implementation and dependencies locally, returning focused evidence-backed context.
user-invocable: true
---

# Repository Understanding

1. Identify the engineering objective.
2. Identify the relevant repository and modules.
3. Discover relevant entry points and source files.
4. Locate classes, methods, functions and interfaces.
5. Trace relevant callers, callees and dependencies.
6. Examine applicable Git history.
7. Identify related tests and architecture constraints.
8. Distinguish verified facts from inferred relationships.
9. Remove duplicate and unrelated investigation results.
10. Return focused context with relevant source paths,
    symbols, dependencies and uncertainties.

Use Vibe's existing native tools.

Do not modify source files.

Do not dump entire repositories into the context.

Stop investigating once sufficient reliable evidence has
been established for the requested task.
