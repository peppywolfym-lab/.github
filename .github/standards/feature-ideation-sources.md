# Feature Ideation — Reputable Source List

> **Purpose:** A starter list of reputable web pages, RSS feeds, podcasts,
> and YouTube channels that the BMAD Analyst (Mary) consults during
> **Phase 2: Market Research** of the
> [Feature Ideation workflow](../.github/workflows/feature-ideation-reusable.yml).
>
> **How it is used:** This file is a **template**. Each adopting repo copies
> it to `.github/feature-ideation-sources.md` (or the path configured via
> the `sources_file` workflow input) and customises it for their project.
> The reusable workflow reads the repo-local copy — it does **not** read
> this file directly. Mary treats the local list as her starting set for
> web research, supplementing it with targeted searches as needed.
>
> **Curation rules:**
>
> - Only sources with a track record of accurate, technically-grounded
>   content. No SEO farms, no anonymous aggregators with no editorial
>   standards.
> - Prefer **primary sources** (vendor changelogs, research labs, official
>   blogs) over secondary commentary.
> - RSS / Atom feed URLs are listed where available — they let Mary fetch
>   structured "what is new since last scan" data instead of scraping HTML.
> - YouTube and podcast feeds are included because release announcements,
>   conference talks, and engineering deep-dives often appear there before
>   (or instead of) blog posts.
> - Every entry has a one-line note explaining **why it is on this list** —
>   if you cannot justify it in one line, it should not be here.
>
> **Maintenance:** Each repo owns its own copy — add or remove entries via
> PR in that repo. To update the shared starter template, open a PR here;
> existing repos with their own copy will not be affected automatically.

---

## 1. AI / ML — Vendor & Lab Primary Sources

Release notes, model launches, capability changes. These are usually the
**first** place a new feature surfaces, weeks before commentary catches up.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| Anthropic News | <https://www.anthropic.com/news> | <https://www.anthropic.com/rss.xml> | Model releases, safety research, API changes |
| OpenAI Blog | <https://openai.com/blog> | <https://openai.com/blog/rss.xml> | Model releases, API updates, research |
| Google DeepMind Blog | <https://deepmind.google/discover/blog/> | — | Research breakthroughs, Gemini updates |
| Google AI Blog | <https://ai.googleblog.com/> | <https://ai.googleblog.com/feeds/posts/default> | Applied AI research and product updates |
| Meta AI Blog | <https://ai.meta.com/blog/> | — | LLaMA releases, research |
| Mistral Blog | <https://mistral.ai/news/> | — | Open-weight model releases |
| HuggingFace Blog | <https://huggingface.co/blog> | <https://huggingface.co/blog/feed.xml> | Model releases, dataset news, community trends |
| Cohere Blog | <https://cohere.com/blog> | — | Enterprise LLM API updates |
| xAI Blog | <https://x.ai/blog> | — | Grok model updates |

## 2. AI / ML — Research & Trends

Pre-prints, paper trackers, and analyst commentary. Useful for spotting
emerging capabilities **before** they hit vendor APIs.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| arXiv cs.AI | <https://arxiv.org/list/cs.AI/recent> | <https://export.arxiv.org/rss/cs.AI> | Daily AI pre-prints |
| arXiv cs.CL | <https://arxiv.org/list/cs.CL/recent> | <https://export.arxiv.org/rss/cs.CL> | NLP / language model pre-prints |
| arXiv cs.LG | <https://arxiv.org/list/cs.LG/recent> | <https://export.arxiv.org/rss/cs.LG> | Machine learning pre-prints |
| Papers with Code — Trending | <https://paperswithcode.com/> | — | Papers ranked by community attention with reference implementations |
| Import AI (Jack Clark) | <https://importai.substack.com/> | <https://importai.substack.com/feed> | Weekly research roundup with policy + capability framing |
| The Gradient | <https://thegradient.pub/> | <https://thegradient.pub/rss/> | Long-form ML research essays |

## 3. Developer Tooling, DevEx & Platform Changelogs

Platform features that unlock new product capabilities. GitHub's changelog
in particular is the **single most important feed** for any project hosted
on GitHub.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| GitHub Changelog | <https://github.blog/changelog/> | <https://github.blog/changelog/feed/> | GitHub product feature releases |
| GitHub Engineering | <https://github.blog/engineering/> | <https://github.blog/engineering/feed/> | Deep-dives on GitHub's own engineering decisions |
| GitLab Blog | <https://about.gitlab.com/blog/> | <https://about.gitlab.com/atom.xml> | DevOps platform changes |
| Vercel Blog | <https://vercel.com/blog> | — | Frontend/edge platform updates |
| Cloudflare Blog | <https://blog.cloudflare.com/> | <https://blog.cloudflare.com/rss/> | Edge, Workers, security product updates |
| AWS What's New | <https://aws.amazon.com/new/> | <https://aws.amazon.com/about-aws/whats-new/recent/feed/> | AWS service launches and updates |
| GCP Blog | <https://cloud.google.com/blog/> | <https://cloud.google.com/feeds/gcp-release-notes.xml> | GCP release notes |
| Stack Overflow Blog | <https://stackoverflow.blog/> | <https://stackoverflow.blog/feed/> | Developer survey data, industry trends |
| The Pragmatic Engineer | <https://newsletter.pragmaticengineer.com/> | — | Engineering leadership and tooling trends |

## 4. Security & Compliance

Vulnerabilities, supply chain threats, and compliance changes that may
surface as feature requirements.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| GitHub Security Blog | <https://github.blog/security/> | <https://github.blog/security/feed/> | GitHub's own security advisories and features |
| GitHub Advisory Database | <https://github.com/advisories> | — | Known vulnerabilities in open-source packages |
| CISA Known Exploited Vulnerabilities | <https://www.cisa.gov/known-exploited-vulnerabilities-catalog> | <https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json> | US government KEV feed |
| OpenSSF Blog | <https://openssf.org/blog/> | <https://openssf.org/blog/feed/> | Supply chain security standards |
| Snyk Blog | <https://snyk.io/blog/> | <https://snyk.io/blog/feed/> | Vulnerability research and DevSecOps trends |
| Krebs on Security | <https://krebsonsecurity.com/> | <https://krebsonsecurity.com/feed/> | Investigative security journalism |

## 5. Software Engineering Practice & Industry Analysis

Long-form analysis of engineering decisions, industry shifts, and
developer trends.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| Hacker News — Top | <https://news.ycombinator.com/> | <https://hnrss.org/frontpage> | Community signal on what engineers care about |
| Lobsters | <https://lobste.rs/> | <https://lobste.rs/rss> | Curated engineering discussion |
| Martin Fowler | <https://martinfowler.com/> | <https://martinfowler.com/feed.atom> | Software design patterns and architecture |
| Latent Space (substack) | <https://www.latent.space/> | <https://www.latent.space/feed> | AI engineering deep-dives |
| Simon Willison's Weblog | <https://simonwillison.net/> | <https://simonwillison.net/atom/entries/> | Practical LLM applications and web tech |
| Stratechery | <https://stratechery.com/> | — | Tech strategy and business model analysis |
| Increment | <https://increment.com/> | <https://increment.com/feed.xml> | Long-form engineering practice essays |

## 6. Newsletters

Curated weekly signal with low noise. Prefer fetching the RSS feed if
listed over the web version.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| TLDR | <https://tldr.tech/> | <https://tldr.tech/rss/tech> | High-signal daily tech summary |
| Ben's Bites | <https://bensbites.beehiiv.com/> | <https://bensbites.beehiiv.com/feed> | Daily AI product and research digest |
| The Rundown AI | <https://www.therundown.ai/> | — | AI tools and model updates for practitioners |
| Bytes (JS) | <https://bytes.dev/> | — | JavaScript/TypeScript ecosystem news |
| Python Weekly | <https://www.pythonweekly.com/> | — | Python ecosystem packages and tutorials |
| DevOps Weekly | <https://www.devopsweekly.com/> | — | DevOps tooling and practices |

## 7. Podcasts

Engineering and product insights that often precede written coverage.
Subscribe to the RSS feed and look for recent episode titles/descriptions.

| Source | URL | Feed | Why it's here |
|--------|-----|------|---------------|
| Latent Space Podcast | <https://www.latent.space/podcast> | <https://www.latent.space/feed> | AI engineering interviews with practitioners |
| The Changelog | <https://changelog.com/podcast> | <https://changelog.com/podcast/feed> | Open-source and developer tooling |
| Practical AI | <https://changelog.com/practicalai> | <https://changelog.com/practicalai/feed> | Applied ML and AI products |
| a16z Podcast | <https://a16z.com/podcasts/> | <https://a16z.com/feed/podcast/> | Tech and startup strategy |
| The Cognitive Revolution | <https://www.cognitiverevolution.ai/> | — | AI capability and safety interviews |
| Lex Fridman Podcast | <https://lexfridman.com/podcast/> | <https://lexfridman.com/feed/podcast/> | Long-form researcher/founder interviews |
| Software Engineering Daily | <https://softwareengineeringdaily.com/> | <https://softwareengineeringdaily.com/feed/podcast/> | Engineering deep-dives |

## 8. YouTube Channels

Conference talks and product launches often land on YouTube before
blog posts. Fetch the channel's RSS feed to see recent video titles.

| Source | Channel URL | RSS Feed | Why it's here |
|--------|-------------|----------|---------------|
| Fireship | <https://www.youtube.com/@Fireship> | <https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA> | Quick-hit tech trends and new tool releases |
| ThePrimeagen | <https://www.youtube.com/@ThePrimeagen> | <https://www.youtube.com/feeds/videos.xml?channel_id=UC8ENHE5xdFSwx71WHd9LCvg> | Developer tooling opinions and Rust/Go/TS trends |
| Two Minute Papers | <https://www.youtube.com/@TwoMinutePapers> | <https://www.youtube.com/feeds/videos.xml?channel_id=UCbfYPyITQ-7l4upoX8nvctg> | Accessible ML research summaries |
| Yannic Kilcher | <https://www.youtube.com/@YannicKilcher> | <https://www.youtube.com/feeds/videos.xml?channel_id=UCZHmQk67mSJgfCCTn7xBfew> | Deep ML paper walkthroughs |
| AI Explained | <https://www.youtube.com/@aiexplained-official> | <https://www.youtube.com/feeds/videos.xml?channel_id=UCNJ1Ymd5yFuUPtn21xtRbbw> | LLM capability updates |
| Matthew Berman | <https://www.youtube.com/@matthew_berman> | <https://www.youtube.com/feeds/videos.xml?channel_id=UCnUYZLuoy1rq1aVMwx4aTzw> | AI tool demos and model comparisons |
| GitHub on YouTube | <https://www.youtube.com/@GitHub> | <https://www.youtube.com/feeds/videos.xml?channel_id=UC7c3Kb6jYCRj4JOHHZTxKsQ> | GitHub product demos and Universe talks |
| AWS Events | <https://www.youtube.com/@AWSEventsChannel> | <https://www.youtube.com/feeds/videos.xml?channel_id=UCdoadna9HFHDqnC9lBaxd3w> | re:Invent, re:Inforce session recordings |

## 9. Conferences

Major annual events where product announcements and research previews
cluster. Monitor the conference site and YouTube channel in the weeks
before and after each event.

| Conference | Typical date | URL | Why it's here |
|------------|-------------|-----|---------------|
| GitHub Universe | Oct | <https://githubuniverse.com/> | GitHub roadmap and ecosystem announcements |
| KubeCon / CloudNativeCon | Mar + Nov | <https://events.linuxfoundation.org/kubecon-cloudnativecon-north-america/> | Cloud-native platform shifts |
| AWS re:Invent | Nov–Dec | <https://reinvent.awsevents.com/> | AWS service launches |
| Google Cloud Next | Apr | <https://cloud.withgoogle.com/next> | GCP and Workspace announcements |
| NeurIPS | Dec | <https://neurips.cc/> | Top-tier ML research |
| ICML | Jul | <https://icml.cc/> | Machine learning research trends |
| ICLR | May | <https://iclr.cc/> | Deep learning and representation learning |
| Strange Loop (archive) | — | <https://www.thestrangeloop.com/> | Engineering practice talks (archived; still valuable) |
