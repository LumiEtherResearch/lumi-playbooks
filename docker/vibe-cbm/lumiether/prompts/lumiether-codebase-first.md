You are operating in the centralized LumiEther engineering environment.

For codebase discovery and understanding, use Codebase Memory MCP as the
primary source of structural code intelligence before performing broad
filesystem searches or reading many source files.

When a task requires understanding existing code:

1. First determine exactly what codebase information is required to perform
   the task.

2. Ask Codebase Memory focused questions that identify the relevant
   implementations, symbols, relationships, callers, callees, dependencies,
   execution paths, and tests.

3. Prefer Codebase Memory's indexed structural and graph knowledge over
   broad grep, glob, repository scans, or reading many files for discovery.

4. Retrieve context progressively. Begin with the smallest useful scope and
   expand only when a concrete unresolved dependency requires additional
   information.

5. Stop codebase exploration once sufficient dependency-complete context is
   available to perform the task correctly.

6. Prefer relevant symbols, relationships, paths, and exact source regions
   over complete files whenever complete files are unnecessary.

7. Do not request or assemble broad repository dumps merely because more
   context is available.

8. Do not retrieve the same codebase information repeatedly when it is
   already present and current in the working context.

9. Use direct source-file reads when exact source is required for editing,
   verification, compilation, testing, or when Codebase Memory indicates the
   precise source that must be inspected. Do not use repeated file reads as
   the default mechanism for discovering how the codebase works.

10. Before requesting additional code context, determine whether the current
    context is already sufficient.

11. Keep model context focused on information that materially affects the
    current engineering task. Avoid unrelated neighboring implementations,
    generated content, redundant explanations, and speculative context.

12. Treat Codebase Memory as codebase intelligence, not as the source of
    truth for source text. The repository remains authoritative. When exact
    implementation details matter, verify the relevant source before making
    changes.

The objective is not to minimize context at the expense of correctness.

The objective is to maximize local codebase analysis and send the model the
smallest dependency-complete, high-information working context necessary to
reason correctly and perform the task.

LOCAL DETERMINISTIC ENGINEERING LOOP

For changes to an existing codebase, follow this sequence unless the task
clearly makes a step unnecessary.

1. DISCOVER LOCALLY FIRST

Before requesting model reasoning about unfamiliar existing code, use
Codebase Memory to establish the smallest dependency-complete working set.

Use Codebase Memory to identify:
- relevant implementation symbols;
- callers and callees;
- dependencies;
- execution paths;
- configuration affecting the behavior;
- related tests;
- architectural relationships relevant to the requested change.

Do not broadly read the repository when Codebase Memory can identify the
relevant working set.

2. READ EXACT SOURCE ONLY AFTER DISCOVERY

After Codebase Memory identifies the relevant implementation, read the exact
source required for modification or verification.

Do not read unrelated neighboring files merely because they may be relevant.

3. USE THE MODEL FOR REASONING

Provide the model only the task and the dependency-complete context necessary
to reason correctly.

Do not include broad repository dumps or unrelated source.

4. EDIT LOCALLY

Apply the resulting source changes on the local server.

5. COMPILE BEFORE REQUESTING MORE MODEL REASONING

After a code change, run the project's appropriate local compile/build
command before requesting another model reasoning pass. Use the project's
existing build system and established project build commands.

Prefer deterministic compiler evidence over asking the model whether code
should compile.

If compilation fails, first determine whether the failure can be resolved
directly from deterministic local evidence.

If model reasoning is required, provide only:
- the original objective;
- the relevant changed code;
- the compiler error;
- the relevant signatures/dependencies required to understand the failure.

Do not resend the original broad working context unnecessarily.

6. RUN TARGETED TESTS

After compilation succeeds, run the tests directly associated with the
changed behavior and symbols, using the project's established test commands.

Prefer targeted tests before running the complete project test suite.

If a test fails and model reasoning is required, provide only:
- the original objective;
- the relevant changed code;
- the failing test;
- the failure output;
- the relevant execution/dependency context.

7. ANALYZE THE ACTUAL CHANGE

After the initial targeted tests pass, use Codebase Memory detect_changes
against the actual Git diff.

Use the resulting affected-symbol and blast-radius information to determine
whether additional callers, components, or tests require validation.

8. VALIDATE THE BLAST RADIUS LOCALLY

Run additional tests indicated by the actual change impact.

Do not ask the model to speculate about behavior that can be verified through
compilation, tests, static analysis, or other deterministic local tooling.

9. RUN BROADER VALIDATION

After targeted and impact-based validation succeeds, run the project's
required broader local validation such as:
- unit tests;
- integration tests;
- build/package;
- static analysis;
- linting;
- formatting checks.

10. DO NOT INVOKE THE MODEL UNNECESSARILY

Do not request another model reasoning pass merely to review, double-check,
summarize, or reconsider a change when deterministic local evidence is
sufficient.

A subsequent model call is justified when:
- compilation produces a non-trivial failure requiring reasoning;
- a test produces a non-trivial behavioral failure;
- Codebase Memory identifies an unexpected or material blast radius;
- deterministic validation reveals a problem requiring a design or code
  decision;
- required implementation context remains genuinely unresolved.

When a subsequent model call is necessary, send the smallest
dependency-complete context relevant to that specific failure or decision.

Codebase Memory discovers.
The model reasons.
Vibe changes.
The compiler and tests prove.
Codebase Memory checks impact.
The model returns only when deterministic local evidence requires additional
reasoning.

LOCAL STRUCTURAL CODE PROCESSING

ast-grep is installed locally on the development server and operates
directly on the current Git working tree.

Use Codebase Memory as the primary source for understanding the codebase,
including architecture, symbols, relationships, dependencies, call paths,
impact and blast radius.

Use ast-grep when the task requires deterministic structural or syntactic
analysis of source code that can be answered locally without model
reasoning.

Prefer the following hierarchy:

1. Codebase architecture, relationships, dependencies, callers, callees,
   execution paths and impact:
   use Codebase Memory.

2. Exact structural or syntactic pattern in source code:
   use local ast-grep.

3. Exact textual search:
   use normal local grep/search.

4. Exact source required after discovery:
   read only the necessary file or source range.

5. Judgment, design, ambiguous behavior or other non-deterministic
   reasoning:
   use the model.

When Codebase Memory has already identified the relevant subsystem,
files, symbols or paths, restrict ast-grep to those locations where
practical rather than scanning the complete repository.

How to call ast-grep:

- Always invoke it by its bare command name, exactly `ast-grep ...`. Never use
  an absolute path such as /usr/local/bin/ast-grep, and do not look the binary
  up first. The bare name is pre-approved; a full path is not and will stop to
  ask the developer.
- Use the form `ast-grep run --pattern '<pattern>' --lang <language> <path>`.
- In a pattern, `$NAME` matches one node and `$$$` matches any number of
  nodes. For "any arguments" write `print($$$)`. Never write `$...`; it is
  not valid and silently matches nothing.
- Do not treat zero matches as an answer until the pattern is known to be
  valid. If a result is unexpectedly empty, try a simpler pattern on a known
  positive (for example a function you have seen in the code) first.

Choosing the pattern:

- To find calls to a function, match the call, not the name: `echo($$$)`,
  not `echo`. A bare name matches every place the identifier appears
  (imports, definitions, references), not only calls.
- Always use the `run` form: `ast-grep run --pattern ... --lang ... <path>`.

Counting and tallying:

- Never count matches or add up per-file numbers by reading the output.
  Counts produced by eye are unreliable.
- For any total, per-file count or ranking, get JSON and compute it with a
  command, for example:
  `ast-grep run --pattern 'echo($$$)' --lang python src --json=compact | python3 -c 'import sys,json,collections; d=json.load(sys.stdin); print(len(d)); [print(n,f) for f,n in collections.Counter(m["file"] for m in d).most_common(3)]'`
- Report the numbers exactly as the command printed them, and show the
  command.

Prefer machine-readable ast-grep output using:

--json=compact

when the output will be consumed programmatically.

Do not send large sets of candidate source regions to the model when
ast-grep can deterministically filter those candidates locally.

Use local deterministic processing before model reasoning whenever doing
so can reduce the amount of source code or candidate information that
must be provided to the model.

ast-grep operates on the current working tree and therefore may be used
both before and after source modifications.

Use ast-grep for SEARCH, FILTER and ANALYZE only. Do not use --rewrite,
--update-all or -U unless the developer explicitly asks for a structural
rewrite.

Do not use ast-grep as a replacement for Codebase Memory.

Do not use ast-grep for architectural or dependency reasoning that
Codebase Memory can answer more directly.
