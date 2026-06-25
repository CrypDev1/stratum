# Claude Design Prompt — Stratum Protocol website

> Paste everything below the line into Claude Design.

---

Design and build the marketing website for **Stratum** — the on-chain operating system for tokenized equities. This is a serious DeFi infrastructure protocol on BNB Chain, in the same tier as Pendle, Morpho, Hyperliquid, and Ethena. The site must look like it was built by an A+ in-house brand and product design team — the kind of site where a visitor's first reaction is *"holy shit, this is a real, well-funded business with world-class designers."* No generic templates, no AI-generated look, no stock-photo energy.

## Absolute requirements
- **No AI watermarks, no "made with AI" badges, no placeholder lorem ipsum, no default framework chrome.** Every pixel intentional.
- **Single, cohesive, distinctive visual identity** — not a Bootstrap/Tailwind-default look. Commit hard to one strong art direction (see below).
- Production-quality, responsive (flawless on mobile, tablet, desktop, ultrawide), accessible (WCAG AA contrast, keyboard nav, reduced-motion support), and fast.
- Real, specific copy (provided below) — never placeholder.

## What Stratum is (so the copy is accurate)
Stratum turns tokenized stocks (Binance **bStocks** — BEP-20 tokens 1:1-backed by real US shares like NVIDIA, Tesla, Micron, trading 24/7) into composable DeFi assets. A permissionless stack:
- **Indexes & Vaults** — one-click thematic ETFs ("AI Index", "Memory Supercycle") and manager-run / AI-agent-run strategies.
- **Fair-value oracle** — prices tokenized stocks 24/7, even when the US market is closed (the technical moat).
- **Leverage, yield, and structured products** — leverage your basket, earn yield on idle shares, split into principal/yield or senior/junior tranches.
- **24/7 derivatives** — perps on stock indexes that never sleep.
- **ve-tokenomics flywheel** — fees from every layer flow to STRAT lockers who direct incentives.
One line: *"Any tokenized stock, made composable: index it, leverage it, tranche it, trade it — 24/7, on-chain."*

## Art direction (pick this and commit)
**"Institutional futurism."** The feeling of a Bloomberg terminal reimagined by a luxury fintech — precise, data-dense, expensive, and quietly futuristic. Specifics:
- **Palette:** deep near-black base (not pure #000 — a rich charcoal/ink, e.g. #0A0B0D) with a single confident accent. Suggest a luminous "Stratum green" gradient (electric green → teal, nodding to BNB without copying its yellow) used sparingly for emphasis and data highlights. One accent, used with discipline. Generous use of subtle layered surfaces and hairline borders (1px, low-opacity) to create a sense of stratified depth — lean into the "layers" theme of the name.
- **Typography:** a distinctive, characterful display face for headlines (a tight, modern grotesk or a refined serif for contrast — not Inter-default) paired with a clean monospace for numbers, tickers, and data (numbers everywhere should be tabular/mono — this is a finance product). Big, confident type scale. Real typographic hierarchy.
- **Motion:** restrained, premium micro-interactions — numbers that count up on scroll, subtle parallax on layered cards, a live-feeling "ticker" of bStock prices, hover states with intention. Smooth, never gratuitous. Honor `prefers-reduced-motion`.
- **Background/texture:** a subtle, custom hero treatment that reinforces "layers/strata" — e.g. an animated topographic/contour mesh, a faint grid that reacts to the cursor, or stacked translucent planes with depth. Custom SVG/canvas, not a stock gradient blob. Avoid the overused "purple glow orb" web3 cliché.
- **Iconography & charts:** crisp custom line icons; real-looking data viz (sparklines, an index NAV chart, a tranche waterfall diagram, a layer-stack diagram of the protocol). Make the data feel alive and credible.

## Page structure (single landing page, long-scroll)
1. **Sticky nav** — wordmark + links (Protocol, Indexes, Docs, Governance) + a primary "Launch App" button. Thin, glassy, refined.
2. **Hero** — bold headline (e.g. *"Tokenized stocks, finally composable."*), one-sentence subhead, two CTAs ("Launch App" / "Read the docs"), and a live-feeling visual: a layered protocol-stack graphic or an animated index card showing a basket of bStocks with a live NAV sparkline. Include a discreet "Built on BNB Chain" mark.
3. **Trust bar** — animated metrics row: TVL, total portfolios created, 24/7 uptime, assets supported. Numbers count up on scroll, mono font.
4. **The problem / insight** — short, sharp: tokenized stocks exist but sit idle; the US market sleeps, DeFi doesn't. Stratum makes them productive 24/7.
5. **The stack** — the signature section: an interactive vertical diagram of the layers (Oracle → Portfolios → Leverage/Yield → Structured Products → Derivatives → AI Agents → Token), each expandable with a one-liner. This is the "wow" moment — make it feel like inspecting a real piece of engineering.
6. **Indexes/Vaults showcase** — a grid of beautiful product cards (AI Index, Semis, Mag7, an AI-agent vault) each with a mini NAV chart, weighting donut, and APY/leverage badges. Make them look like real, tradeable products.
7. **For builders** — composability / "money legos" section with a clean code snippet and interface highlights.
8. **Tokenomics / flywheel** — an elegant circular flywheel diagram showing fees → veSTRAT → gauges → incentives → growth.
9. **Security & backing** — Proof-of-Collateral, audits (placeholder badges clearly marked), self-custody. Build trust.
10. **CTA band** — strong closing call to action.
11. **Footer** — full nav, socials (X, Discord, GitHub, Docs, Mirror), legal/disclaimer line, newsletter input. Rich and polished, not an afterthought.

## Copy voice
Confident, precise, technical-but-clear. Short declarative sentences. No hype-words like "revolutionary" or "unleash." Sound like Stripe or Linear writing for a sophisticated DeFi audience. Lead with substance and numbers.

## Tech
Build it as a single, self-contained, production-grade responsive site (React + Tailwind or clean HTML/CSS/JS — your call, but the result must not look like default Tailwind). Custom CSS for the distinctive bits. Smooth scroll, intersection-observer animations, and a live-updating mock price ticker (use realistic mock data for NVDAB, TSLAB, MUB, etc.). Optimize for Lighthouse 95+. Include favicon + OG meta. Dark mode is the default and primary aesthetic.

Deliver something that could be the actual homepage of a top-10 DeFi protocol on launch day.
