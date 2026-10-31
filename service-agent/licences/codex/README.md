# Codex's licence and NOTICE

The Codex npm tarball carries neither file, so the image copies them from the
release whose version `service-agent/versions.env` pins:

- `LICENSE`: https://raw.githubusercontent.com/openai/codex/rust-v0.165.0/LICENSE
- `NOTICE`: https://raw.githubusercontent.com/openai/codex/rust-v0.165.0/NOTICE

Both are Apache-2.0, unmodified. Their SHA256s are in `versions.env`
(`CODEX_LICENSE_SHA256`, `CODEX_NOTICE_SHA256`), and `build.sh` checks them
before the build. A new Codex pin moves the tag in these URLs, both files and
both hashes together.
