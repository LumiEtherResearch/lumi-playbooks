---
name: regression-testing
description: Validate engineering changes using existing local tests and deterministic checks.
user-invocable: true
---

# Regression Testing

1. Identify changed files and behavior.
2. Identify affected modules and interfaces.
3. Locate existing relevant tests.
4. Execute authorized unit tests.
5. Execute applicable integration tests.
6. Execute existing build and static checks where relevant.
7. Inspect failures and isolate relevant evidence.
8. Inspect the final Git diff.
9. Identify unintended modifications.
10. Report passed, failed and unexecuted checks.

Use only existing project validation capabilities.

Do not add a new testing framework.

Do not claim tests passed unless they executed successfully.
