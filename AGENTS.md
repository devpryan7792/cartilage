## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- If the `graphify` CLI tool is installed on PATH and `graphify-out/graph.json` exists, use `graphify query "<question>"` for codebase questions. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. If `graphify` is not installed on PATH, use standard repository search tools (`grep_search`, `find_by_name`, `view_file`).
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- If `graphify` is installed on PATH, run `graphify update .` after modifying code to keep the graph current (AST-only, no API cost).
