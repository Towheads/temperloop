---
description: Initialize a new CLAUDE.md file with codebase documentation, then create a project context placeholder in the Obsidian vault at ~/dev/mind.
---

Please analyze this codebase and create a CLAUDE.md file, which will be given to future instances of Claude Code to operate in this repository.

What to add:
1. Commands that will be commonly used, such as how to build, lint, and run tests. Include the necessary commands to develop in this codebase, such as how to run a single test.
2. High-level code architecture and structure so that future instances can be productive more quickly. Focus on the "big picture" architecture that requires reading multiple files to understand.

Usage notes:
- If there's already a CLAUDE.md, suggest improvements to it.
- When you make the initial CLAUDE.md, do not repeat yourself and do not include obvious instructions like "Provide helpful error messages to users", "Write unit tests for all new utilities", "Never include sensitive information (API keys, tokens) in code or commits".
- Avoid listing every component or file structure that can be easily discovered.
- Don't include generic development practices.
- If there are Cursor rules (in .cursor/rules/ or .cursorrules) or Copilot rules (in .github/copilot-instructions.md), make sure to include the important parts.
- If there is a README.md, make sure to include the important parts.
- Do not make up information such as "Common Development Tasks", "Tips for Development", "Support and Documentation" unless this is expressly included in other files that you read.
- Be sure to prefix the file with the following text:
```
# CLAUDE.md
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
```

## After creating CLAUDE.md: Create Obsidian project placeholder

Once CLAUDE.md has been written, create a project context placeholder in the Obsidian vault at `~/dev/mind`.

Steps:
1. Derive the project name from the current working directory name (e.g. `/Users/alice/dev/BusinessSearch` → `BusinessSearch`). Convert hyphenated/underscored names to title case (e.g. `my-app` → `My App`).
2. Build a kebab-case tag slug from the project name (e.g. `My App` → `my-app`).
3. Check whether `Context/<ProjectName>/index.md` already exists in the vault using `mcp__obsidian__get_vault_file`. If it does, skip creation.
4. If it doesn't exist, use `mcp__obsidian__create_vault_file` to create `Context/<ProjectName>/index.md` with this content (substituting the actual values):

```markdown
---
tags:
  - project/<tag-slug>
created: <YYYY-MM-DD>
---

# <ProjectName>

Project context for this codebase.

## Overview

_Add overview here._

## Key Links

- Codebase: `<absolute path to cwd>`
```

5. Let the user know the vault note was created (or already existed).
