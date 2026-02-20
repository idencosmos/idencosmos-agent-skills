# Publishing Checklist

실행 위치(기본): `~/Projects/skills-hub/idencosmos-agent-skills`

1. Confirm each skill folder has `SKILL.md`.
2. Verify `name` and `description` frontmatter are accurate.
3. Run `python3 .github/scripts/validate_skill.py skills/<skill-name>`.
4. Run `npx skills add . --list`.
5. Run `npx skills add . --skill <skill-name> -y`.
6. (Optional, 실행 위치: `~/Projects/skills-hub`) Run `python3 scripts/package_skill.py idencosmos-agent-skills/skills/<skill-name> dist`.
7. Commit with clear changelog note.
8. Push and confirm GitHub Actions passed.
9. Validate remote install commands:
   `npx skills add idencosmos/idencosmos-agent-skills --list`
   `npx skills add idencosmos/idencosmos-agent-skills --skill <skill-name> -y`
10. Confirm README pages contain summary + links only, and detailed specs live in `docs/*.md`.
11. Confirm README links resolve to existing files.
