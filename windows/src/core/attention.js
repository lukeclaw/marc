/*
 * marc — on-demand attention analysis.
 *
 * Port of Sources/MarcCore/AttentionAnalysis.swift. Chunking, the reviewed
 * profile prototypes, the scoring formula, the category quotas, and the
 * relative (z-score) confidence bands are unchanged. Only the embedding
 * provider differs; see src/core/embedding.js for why.
 *
 * Constraints preserved from ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md:
 *   - runs only when explicitly requested,
 *   - performs no network request,
 *   - never modifies the document,
 *   - every result carries its source block IDs.
 */
(function (root, factory) {
  const api = factory(
    typeof module === "object" && module.exports
      ? require("./embedding.js")
      : root.MarcEmbedding
  );
  if (typeof module === "object" && module.exports) module.exports = api;
  root.MarcAttention = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (Embedding) {
  "use strict";

  const MODEL_IDENTIFIER = Embedding.modelIdentifier;
  const PROFILE_VERSION = "attention-profiles-v1";

  const CATEGORIES = ["urgent", "important", "review"];

  const CATEGORY_LABELS = {
    urgent: "Urgent",
    important: "Important",
    review: "Review"
  };

  const CATEGORY_POLICIES = {
    urgent: { maximumResults: 2 },
    important: { maximumResults: 3 },
    review: { maximumResults: 4 }
  };

  const PROFILES = [
    {
      category: "urgent",
      name: "Blocking failure",
      positive: [
        "A production failure is blocking users and requires immediate intervention.",
        "The work cannot proceed because a critical dependency is unavailable.",
        "An active incident requires rollback or urgent mitigation."
      ],
      negative: [
        "This document describes a historical failure that has already been resolved.",
        "The test intentionally verifies an expected failure condition."
      ],
      signals: ["production is down", "outage", "blocking", "cannot proceed", "rollback", "immediate action"],
      negativeSignals: ["historical", "already resolved", "expected failure", "test intentionally", "hypothetical"]
    },
    {
      category: "urgent",
      name: "Security or destructive risk",
      positive: [
        "There is an immediate security, privacy, data-loss, or destructive-action risk.",
        "Credentials or sensitive information may be exposed and require intervention."
      ],
      negative: [
        "The security section documents normal safeguards with no active issue.",
        "This is a hypothetical risk used only as an example."
      ],
      signals: ["data loss", "security incident", "credential leak", "destructive", "privacy breach"],
      negativeSignals: ["hypothetical", "no active issue", "normal safeguards", "already resolved"]
    },
    {
      category: "important",
      name: "Consequential decision",
      positive: [
        "A consequential architecture, product, or implementation decision is being proposed.",
        "This decision changes scope, behavior, ownership, or a public contract.",
        "The section records an expensive or difficult-to-reverse tradeoff."
      ],
      negative: [
        "This is a minor formatting preference with no behavioral impact.",
        "The section repeats background information without a new decision."
      ],
      signals: ["decision", "recommendation", "breaking change", "scope change", "tradeoff", "irreversible"],
      negativeSignals: ["minor formatting", "no behavioral impact", "background information", "already decided"]
    },
    {
      category: "important",
      name: "Material dependency or risk",
      positive: [
        "A material dependency or risk affects multiple components, teams, or users.",
        "The plan depends on an unresolved external system or approval."
      ],
      negative: [
        "This dependency is already satisfied and requires no attention.",
        "The risk is negligible and documented only for completeness."
      ],
      signals: ["depends on", "dependency", "material risk", "multiple teams", "customer impact"],
      negativeSignals: ["already satisfied", "negligible", "no attention required"]
    },
    {
      category: "review",
      name: "Approval or human judgment needed",
      positive: [
        "A human reviewer must approve, choose, or validate this proposal.",
        "The author explicitly requests review before proceeding.",
        "The correct behavior depends on product or engineering judgment."
      ],
      negative: [
        "The review has already completed and the decision is final.",
        "This section merely describes the normal review process."
      ],
      signals: [
        "approval required",
        "approval is required",
        "requires approval",
        "needs review",
        "please review",
        "human judgment",
        "before proceeding"
      ],
      negativeSignals: ["already approved", "review completed", "decision is final", "normal review process"]
    },
    {
      category: "review",
      name: "Unresolved or unverified",
      positive: [
        "The section contains an unresolved question, contradiction, assumption, or missing validation.",
        "The author is uncertain and requires verification.",
        "Tests or evidence are missing or failed."
      ],
      negative: [
        "All questions are resolved and validation passed.",
        "The assumption has been verified by the cited evidence."
      ],
      signals: ["open question", "unresolved", "uncertain", "assumption", "not verified", "validation failed", "todo"],
      negativeSignals: ["all questions are resolved", "validation passed", "has been verified", "already verified"]
    }
  ];

  // Prototype vectors are pure functions of bundled data, so they are computed
  // once and reused for every run.
  let prototypeCache = null;

  function prototypeVectors() {
    if (prototypeCache !== null) return prototypeCache;
    prototypeCache = PROFILES.map((profile) => ({
      category: profile.category,
      name: profile.name,
      positive: profile.positive.map(Embedding.embed),
      negative: profile.negative.map(Embedding.embed),
      signals: profile.signals,
      negativeSignals: profile.negativeSignals
    }));
    return prototypeCache;
  }

  class AttentionAnalysisError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "AttentionAnalysisError";
      this.code = code;
    }
  }

  const Errors = {
    embeddingUnavailable: () =>
      new AttentionAnalysisError(
        "embeddingUnavailable",
        "The approved local sentence embedding model is unavailable."
      ),
    unsupportedLanguage: (language) =>
      new AttentionAnalysisError(
        "unsupportedLanguage",
        `Attention analysis currently supports English documents. Detected ${language}.`
      ),
    noAnalyzableContent: () =>
      new AttentionAnalysisError(
        "noAnalyzableContent",
        "This document does not contain enough prose to analyze."
      ),
    cancelled: () => new AttentionAnalysisError("cancelled", "Analysis was cancelled.")
  };

  const FNV_OFFSET = 14695981039346656037n;
  const FNV_PRIME = 1099511628211n;
  const UINT64 = (1n << 64n) - 1n;

  function stableIdentifier(source) {
    let hash = FNV_OFFSET;
    const bytes =
      typeof TextEncoder !== "undefined"
        ? new TextEncoder().encode(source)
        : Buffer.from(source, "utf8");
    for (let i = 0; i < bytes.length; i += 1) {
      hash ^= BigInt(bytes[i]);
      hash = (hash * FNV_PRIME) & UINT64;
    }
    return hash.toString(16);
  }

  function documentRevision(parsed) {
    return stableIdentifier(
      parsed.blocks.map((block) => `${block.id}:${block.signature}`).join("\n")
    );
  }

  function analysisText(block) {
    const kind = block.kind;
    switch (kind.type) {
      case "heading":
        return kind.title;
      case "paragraph":
        return kind.text;
      case "list":
        return kind.items
          .map((item) => {
            let marker;
            if (item.marker.type === "bullet") marker = "•";
            else if (item.marker.type === "ordered") marker = `${item.marker.number}.`;
            else marker = item.marker.checked ? "[x]" : "[ ]";
            return `${marker} ${item.text}`;
          })
          .join("\n");
      case "table":
        return [kind.table.headers, ...kind.table.rows]
          .map((row) => row.join(" | "))
          .join("\n");
      case "blockquote":
        return kind.text;
      case "code": {
        const sample = kind.content.slice(0, 600);
        return `Code ${kind.language === null || kind.language === undefined ? "block" : kind.language}:\n${sample}`;
      }
      default:
        return null;
    }
  }

  /** Build source-linked semantic chunks from parsed Markdown. */
  function makeChunks(parsed, fileName) {
    const headingTitles = new Map(parsed.headings.map((heading) => [heading.id, heading.title]));
    const drafts = [];
    const draftIndexes = new Map();

    for (const block of parsed.blocks) {
      const text = analysisText(block);
      if (text === null || text.length === 0) continue;

      let sectionID;
      let breadcrumbIDs;
      if (block.kind.type === "heading") {
        sectionID = block.id;
        breadcrumbIDs = [...block.ancestorHeadingIDs, block.id];
      } else {
        sectionID =
          block.ancestorHeadingIDs.length > 0
            ? block.ancestorHeadingIDs[block.ancestorHeadingIDs.length - 1]
            : "document-introduction";
        breadcrumbIDs = block.ancestorHeadingIDs;
      }
      const breadcrumb = breadcrumbIDs
        .map((id) => headingTitles.get(id))
        .filter((title) => title !== undefined)
        .join(" › ");
      const key = sectionID;

      const index = draftIndexes.get(key);
      if (index !== undefined && drafts[index].sourceText.length + text.length < 3500) {
        drafts[index].blockIDs.push(block.id);
        drafts[index].sourceText += `\n\n${text}`;
      } else {
        const part = drafts.filter((draft) => draft.sectionID === sectionID).length + 1;
        drafts.push({
          id: `${sectionID}-attention-${part}`,
          sectionID,
          blockIDs: [block.id],
          breadcrumb: breadcrumb.length === 0 ? fileName : breadcrumb,
          sourceText: text
        });
        draftIndexes.set(key, drafts.length - 1);
      }
    }

    return drafts.map((draft) => ({
      id: draft.id,
      blockIDs: draft.blockIDs,
      breadcrumb: draft.breadcrumb,
      sourceText: draft.sourceText,
      embeddingText: `Document: ${fileName}\nSection: ${draft.breadcrumb}\nContent:\n${draft.sourceText}`
    }));
  }

  function scoreCandidates(chunk) {
    const lowered = chunk.sourceText.toLowerCase();
    const chunkVector = Embedding.embed(chunk.embeddingText);
    const matches = [];

    for (const profile of prototypeVectors()) {
      const positiveDistance = profile.positive.length === 0
        ? 2
        : Math.min(...profile.positive.map((vector) => Embedding.distance(chunkVector, vector)));
      const negativeDistance = profile.negative.length === 0
        ? 2
        : Math.min(...profile.negative.map((vector) => Embedding.distance(chunkVector, vector)));

      const semanticSimilarity = 1 - positiveDistance;
      const negativeMargin = Math.max(0, negativeDistance - positiveDistance);
      const phraseMatches = profile.signals.filter((signal) => lowered.includes(signal)).length;
      const negativeSignalMatches = profile.negativeSignals.filter((signal) => lowered.includes(signal)).length;
      const signalBoost = Math.min(0.18, phraseMatches * 0.06);

      let score = semanticSimilarity + negativeMargin * 0.35 + signalBoost;
      if (phraseMatches >= 2) {
        score = Math.max(score, 0.12 + Math.min(phraseMatches - 2, 2) * 0.03);
      } else if (phraseMatches === 1) {
        score = Math.max(score, 0.075);
      }
      score -= negativeSignalMatches * 0.12;

      matches.push({ category: profile.category, profile: profile.name, score });
    }

    const bestByCategory = new Map();
    for (const match of matches) {
      const existing = bestByCategory.get(match.category);
      if (existing === undefined || match.score > existing.score) {
        bestByCategory.set(match.category, match);
      }
    }

    return [...bestByCategory.values()].map((match) => ({
      chunk,
      category: match.category,
      profile: match.profile,
      score: match.score
    }));
  }

  function selectResults(candidates, category, chunks) {
    const policy = CATEGORY_POLICIES[category];
    if (policy === undefined || candidates.length === 0) return [];

    const scores = candidates.map((candidate) => candidate.score).slice().sort((a, b) => a - b);
    const chunkOrder = new Map(chunks.map((chunk, index) => [chunk.id, index]));
    const ranked = candidates.slice().sort((left, right) => {
      if (left.score === right.score) {
        return (chunkOrder.get(left.chunk.id) ?? 0) - (chunkOrder.get(right.chunk.id) ?? 0);
      }
      return right.score - left.score;
    });
    const selected = ranked.slice(0, policy.maximumResults);

    const mean = scores.reduce((total, score) => total + score, 0) / scores.length;
    const variance =
      scores.reduce((total, score) => total + (score - mean) ** 2, 0) / scores.length;
    const standardDeviation = Math.sqrt(variance);

    return selected.map((candidate) => {
      let confidence = "relative";
      if (scores.length >= 4 && standardDeviation > 0) {
        const zScore = (candidate.score - mean) / standardDeviation;
        if (zScore >= 1.25) confidence = "strong";
        else if (zScore >= 0.5) confidence = "possible";
      }
      return {
        id: `${candidate.chunk.id}-${category}`,
        chunkID: candidate.chunk.id,
        blockIDs: candidate.chunk.blockIDs,
        breadcrumb: candidate.chunk.breadcrumb,
        category,
        confidence,
        matchedProfile: candidate.profile,
        score: candidate.score
      };
    });
  }

  /**
   * Create a steppable analysis run.
   *
   * The UI drives this one chunk at a time so that scrolling stays responsive
   * and cancellation takes effect immediately (acceptance criterion 9), while
   * the offline checks drive it in a tight loop.
   *
   * Throws immediately for the model-availability, empty-content, and
   * unsupported-language failures the spec requires to be explicit.
   */
  function createRun(chunks) {
    if (!Embedding.isAvailable()) throw Errors.embeddingUnavailable();
    if (chunks.length === 0) throw Errors.noAnalyzableContent();

    const languageSample = chunks.slice(0, 4).map((chunk) => chunk.sourceText).join("\n");
    const language = Embedding.detectLanguage(languageSample);
    if (language !== "en" && language !== "und") throw Errors.unsupportedLanguage(language);

    const candidates = new Map();
    let index = 0;

    return {
      total: chunks.length,
      get processed() {
        return index;
      },
      get isComplete() {
        return index >= chunks.length;
      },
      /** Score one chunk. Returns the completed fraction. */
      step() {
        for (const candidate of scoreCandidates(chunks[index])) {
          const bucket = candidates.get(candidate.category);
          if (bucket === undefined) candidates.set(candidate.category, [candidate]);
          else bucket.push(candidate);
        }
        index += 1;
        return index / chunks.length;
      },
      /** Rank each category's distribution and apply its fixed quota. */
      finish() {
        const results = [];
        for (const category of CATEGORIES) {
          results.push(...selectResults(candidates.get(category) ?? [], category, chunks));
        }
        return results;
      }
    };
  }

  /**
   * Score every chunk and keep only each category's top results.
   *
   * @param {object[]} chunks from makeChunks
   * @param {(fraction: number) => void} [progress] called once per chunk
   * @param {() => boolean} [isCancelled] polled between chunks
   */
  function analyze(chunks, progress, isCancelled) {
    const report = typeof progress === "function" ? progress : () => {};
    const cancelled = typeof isCancelled === "function" ? isCancelled : () => false;

    const run = createRun(chunks);
    while (!run.isComplete) {
      if (cancelled()) throw Errors.cancelled();
      report(run.step());
    }
    return run.finish();
  }

  return {
    modelIdentifier: MODEL_IDENTIFIER,
    profileVersion: PROFILE_VERSION,
    categories: CATEGORIES,
    categoryLabels: CATEGORY_LABELS,
    categoryPolicies: CATEGORY_POLICIES,
    isAvailable: () => Embedding.isAvailable(),
    documentRevision,
    makeChunks,
    createRun,
    analyze,
    AttentionAnalysisError
  };
});
