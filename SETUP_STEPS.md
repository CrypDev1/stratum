# Stratum — from this folder to a building repo

## 1. Create the GitHub repo + push (one block)

From inside this `stratum/` folder on your machine:

```bash
# requires the GitHub CLI (https://cli.github.com) — run `gh auth login` once if needed
cd stratum
git init -q
git add -A
git commit -m "chore: scaffold Stratum Foundry repo + build prompt"
gh repo create stratum --private --source=. --remote=origin --push
```

That creates the repo under your account and pushes everything. Swap `--private` for `--public` if you want it open from day one.

> No GitHub CLI? Create an empty repo at github.com/new (don't add a README), then:
> ```bash
> git remote add origin https://github.com/<you>/stratum.git
> git branch -M main && git push -u origin main
> ```

## 2. Open Codespaces + launch Claude Code

1. On the repo page → green **Code** button → **Codespaces** tab → **Create codespace on main**.
2. In the Codespace terminal, install Foundry + Claude Code:
   ```bash
   curl -L https://foundry.paradigm.xyz | bash && foundryup
   forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
   npm install -g @anthropic-ai/claude-code   # then run: claude
   ```
3. Start Claude Code (`claude`) and send it this single prompt:

   > **Read BUILD_PROMPT.md and implement the protocol exactly as specified, layer by layer, with full test coverage. Begin with L0 (oracle), build it, run `forge build` and `forge test` until green, commit, then continue to L1 and onward. Maintain PROGRESS.md as you go.**

That's it — it will build the whole stack autonomously, layer by layer.

## 3. Website

Open Claude Design and paste the full contents of `WEBSITE_PROMPT.md`.

---

### Files in this bundle
- `BUILD_PROMPT.md` — the autonomous build spec for Claude Code (all layers L0–★).
- `WEBSITE_PROMPT.md` — the design brief for Claude Design.
- `README.md` — public-facing project overview + architecture table.
- `foundry.toml`, `remappings.txt`, `.env.example`, `.gitignore`, `LICENSE` — repo config.
- `src/…` skeleton + `PROGRESS.md` — where Claude Code fills in contracts.
