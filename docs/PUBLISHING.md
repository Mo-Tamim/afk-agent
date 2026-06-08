# Publishing to skills.sh

`afk-agent` is structured to be discoverable by [skills.sh](https://www.skills.sh/)
as a multi-skill bundle.

## How skills.sh discovers skills

```mermaid
flowchart LR
  Repo[GitHub repo:<br/>&lt;handle&gt;/afk-agent] --> Crawl[skills.sh crawler]
  Crawl -->|reads| Pkg[package.json<br/>"skills.directory": "skills"]
  Crawl -->|enumerates| Dir[skills/*/SKILL.md]
  Dir -->|extracts frontmatter| Index[(skills.sh index)]
  Index --> CLI[npx skills add &lt;repo&gt;]
  CLI --> User[User's agent runtime]
```

The conventions this repo follows:

1. A `package.json` at the root with `"skills": { "directory":
   "skills" }`. The crawler reads this to know where to look.
2. Each skill lives at `skills/<skill-name>/SKILL.md` (one directory
   per skill).
3. Each `SKILL.md` starts with YAML frontmatter:

   ```yaml
   ---
   name: <skill-name>
   description: One-sentence trigger. Use when the user says "X" or "Y".
   ---
   ```

   The `description` is what shows up in skills.sh search and what
   most agents use to decide whether to load the skill.

4. The skill name in frontmatter **matches** the directory name.

## Pre-publish checklist

- [ ] `package.json` has a non-default `name`, `description`,
      `repository.url`, and `license`.
- [ ] Every `skills/*/SKILL.md` has frontmatter with `name` and
      `description`.
- [ ] Every skill's `name` in frontmatter == its directory name.
- [ ] No skill description starts with "This skill …" — start with
      the action ("Stress-test …", "Convert …", "Scaffold …").
- [ ] `README.md` has a one-paragraph "what's in the box" + the
      `npx skills add` command.
- [ ] `LICENSE` exists.
- [ ] No secrets, no `.env` files, no internal paths in any file.
- [ ] `install.sh` is executable (`chmod +x`).
- [ ] Bash scripts under `template/scripts/` are executable.
- [ ] `template/dashboard/server.py` is present (stdlib-only;
      no `requirements.txt` needed). Document the Python 3.8+
      requirement in your README.
- [ ] Replace every `Mo-Tamim` placeholder with your actual
      GitHub handle.

## Publish

```bash
# 1. Tag the version
git tag v0.1.0
git push --tags

# 2. Push to your public GitHub repo
git remote add origin git@github.com:Mo-Tamim/afk-agent.git
git push -u origin main

# 3. Submit to skills.sh
#    Either: open https://www.skills.sh/, sign in, and submit
#            the repo URL via the UI.
#    Or:     wait for the next crawl pass — skills.sh picks up
#            new public repos that match the convention.

# 4. Verify
npx skills search afk-agent
# Should list afk-grill, afk-prd, afk-setup, ... and "Installs" count.
```

## Version & changelog discipline

skills.sh shows `First seen` and an installs counter, not a version
column — but agents can pin to a `--ref <tag>` when calling
`npx skills add`. Keep semver-style tags so users can pin against
breaking changes.

```
v0.1.0  — initial public release
v0.2.0  — added GitLab tracker support
v0.3.0  — added /afk-grill skill
v1.0.0  — stable API: phases, sentinels, tracker verbs frozen
```

A `CHANGELOG.md` at the repo root summarising each tag's deltas helps
the bots and humans both.

## Naming etiquette

- **Prefix every skill** with `afk-` so they cluster in agent
  autocomplete and don't clash with the `mattpocock/skills` originals.
- **Lowercase, kebab-case** for skill names. No `AFK_Grill`,
  `afk.grill`, `AfkGrill`.
- **Don't reuse names** that already exist on skills.sh with a
  different meaning. Search before publishing.

## Marketing copy (optional but worth it)

skills.sh shows the `description` from the SKILL.md frontmatter
verbatim. Make it scannable:

- Bad: *"This skill is used to interview the user about a design plan
  and challenge it against existing project documentation."*
- Good: *"Stress-test a design idea against the existing domain
  model, sharpen vocabulary, and capture decisions as ADRs and
  CONTEXT.md entries inline. Use when the user wants to 'grill' a
  plan or design a new feature."*

Lead with the verb. End with "Use when the user …" so agents have
clear trigger phrases.
