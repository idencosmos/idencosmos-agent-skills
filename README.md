# idencosmos-agent-skills

Public agent skills maintained by `idencosmos`.

## Install

```bash
npx skills add idencosmos/idencosmos-agent-skills --list
npx skills add idencosmos/idencosmos-agent-skills --skill <skill-name> -y
```

## Repository Layout

- `skills/<skill-name>/SKILL.md`: Each published skill.
- `.github/workflows/`: CI checks for skill docs and structure.

## Development

```bash
# list all skills available from this repo
npx skills add . --list

# test install one local skill
npx skills add . --skill <skill-name> -y
```
