/*
 * marc — local sentence embedding provider (Windows).
 *
 * The macOS build uses Apple's NaturalLanguage `NLEmbedding` sentence model.
 * Windows has no equivalent system-provided, reviewed, offline embedding, and
 * ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md forbids both network providers and
 * loading arbitrary downloaded model files. This provider is therefore a
 * bundled, inert, fully deterministic lexical-semantic embedder:
 *
 *   - words are normalized and stemmed lightly,
 *   - a reviewed concept lexicon maps related surface forms onto shared
 *     dimensions ("outage", "down", "incident" -> concept:incident),
 *   - unigrams, bigrams, and concepts are hashed into a fixed-width vector,
 *   - the vector is L2 normalized so cosine distance is 1 - dot product.
 *
 * It is weaker than a trained sentence model at paraphrase, which is why the
 * scorer keeps the spec's deterministic phrase signals and its relative,
 * distribution-based confidence bands rather than absolute thresholds.
 *
 * The lexicon is data, not code. It is reviewed in source control, never
 * user-editable Markdown, and cannot execute.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.MarcEmbedding = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const DIMENSIONS = 384;
  const MODEL_IDENTIFIER = "marc-local-lexical-en-v1";

  const UNIGRAM_WEIGHT = 1.0;
  const BIGRAM_WEIGHT = 0.7;
  const CONCEPT_WEIGHT = 1.6;

  // Structural words plus the fixed embedding-input header words, which would
  // otherwise appear in every chunk and dilute the signal.
  const STOPWORDS = new Set(`a an and are as at be been being but by can could
    did do does doing done for from had has have having he her hers him his how
    i if in into is it its itself me more most my no nor not of off on once only
    or other our ours out over own same she should so some such than that the
    their theirs them then there these they this those through to too under
    until up very was we were what when where which while who whom why will
    with would you your yours document section content`.split(/\s+/u));

  /*
   * Reviewed concept lexicon. Each entry maps surface forms onto one shared
   * dimension so that semantically related wording lands in the same place.
   */
  const CONCEPT_LEXICON = {
    incident: ["outage", "outages", "down", "downtime", "incident", "incidents", "broken", "crash", "crashed", "crashing", "failing", "failure", "failures", "failed", "fails", "error", "errors", "corrupt", "corrupted", "corruption", "degraded", "unavailable", "offline"],
    blocking: ["blocking", "blocked", "blocker", "blockers", "stuck", "halted", "stalled", "cannot", "unable", "impossible", "prevented", "preventing", "waiting"],
    urgency: ["urgent", "urgently", "immediate", "immediately", "now", "asap", "critical", "emergency", "deadline", "overdue", "expiring", "expires", "imminent", "today", "tomorrow"],
    remediation: ["rollback", "rollbacks", "revert", "reverted", "mitigate", "mitigation", "hotfix", "patch", "restore", "recover", "recovery", "intervention", "escalate", "escalation"],
    security: ["security", "vulnerability", "vulnerabilities", "exploit", "breach", "leak", "leaked", "credential", "credentials", "secret", "secrets", "token", "password", "privacy", "exposed", "exposure", "malicious", "attack"],
    destruction: ["delete", "deleted", "deletion", "destructive", "destroy", "wipe", "wiped", "drop", "truncate", "irreversible", "permanent", "unrecoverable", "dataloss"],
    decision: ["decision", "decisions", "decide", "decided", "deciding", "choose", "chose", "choice", "recommend", "recommends", "recommended", "recommendation", "propose", "proposed", "proposal", "adopt", "select", "selected"],
    change: ["change", "changes", "changed", "changing", "breaking", "migration", "migrate", "refactor", "rewrite", "redesign", "scope", "contract", "behavior", "behaviour", "api", "interface"],
    risk: ["risk", "risks", "risky", "tradeoff", "tradeoffs", "downside", "consequence", "consequences", "impact", "impacts", "expensive", "costly", "cost"],
    dependency: ["dependency", "dependencies", "depends", "depend", "depending", "dependent", "upstream", "downstream", "prerequisite", "requires", "required", "blockedby", "coupling", "integration"],
    stakeholders: ["team", "teams", "customer", "customers", "user", "users", "owner", "owners", "stakeholder", "stakeholders", "people", "everyone", "component", "components", "services"],
    approval: ["approval", "approve", "approved", "approver", "signoff", "sign", "authorize", "authorization", "permission", "confirm", "confirmation", "consent"],
    review: ["review", "reviews", "reviewed", "reviewer", "feedback", "inspect", "audit", "check", "checked", "verify", "verified", "verification", "validate", "validated", "validation"],
    question: ["question", "questions", "unclear", "unknown", "unresolved", "ambiguous", "ambiguity", "uncertain", "uncertainty", "maybe", "perhaps", "possibly", "assume", "assumed", "assumption", "assumptions", "todo", "tbd", "contradiction", "conflicting"],
    judgment: ["judgment", "judgement", "human", "manual", "manually", "discretion", "opinion", "preference", "subjective"],
    testing: ["test", "tests", "testing", "tested", "coverage", "suite", "assertion", "regression", "evidence", "proof", "benchmark"],
    resolved: ["resolved", "resolution", "fixed", "closed", "complete", "completed", "done", "finished", "shipped", "landed", "passed", "passing", "succeeded", "success", "successful"],
    historical: ["historical", "history", "previously", "formerly", "past", "old", "legacy", "archived", "retrospective", "postmortem", "earlier"],
    hypothetical: ["hypothetical", "hypothetically", "example", "examples", "illustrative", "sample", "theoretical", "imagine", "suppose", "pretend", "fictional"],
    routine: ["normal", "normally", "routine", "standard", "usual", "typical", "ordinary", "background", "overview", "describes", "description", "explains", "explanation", "documents", "architecture", "reference"],
    negligible: ["minor", "trivial", "negligible", "cosmetic", "formatting", "whitespace", "typo", "nit", "small", "insignificant"],
    plan: ["plan", "plans", "planned", "roadmap", "milestone", "phase", "phases", "step", "steps", "task", "tasks", "implementation", "implement"],
    data: ["data", "database", "record", "records", "row", "rows", "table", "schema", "storage", "file", "files", "backup", "backups"]
  };

  const CONCEPT_INDEX = new Map();
  for (const [concept, words] of Object.entries(CONCEPT_LEXICON)) {
    for (const word of words) {
      const existing = CONCEPT_INDEX.get(word);
      if (existing === undefined) CONCEPT_INDEX.set(word, [concept]);
      else existing.push(concept);
    }
  }

  // Light suffix stripping. Deliberately conservative: it only removes endings
  // that do not change the concept, so that whitespace or tense reflow does not
  // materially move a chunk's vector.
  function stem(word) {
    if (word.length > 5 && word.endsWith("ing")) return word.slice(0, -3);
    if (word.length > 4 && word.endsWith("ed")) return word.slice(0, -2);
    if (word.length > 4 && word.endsWith("es")) return word.slice(0, -2);
    if (word.length > 3 && word.endsWith("s") && !word.endsWith("ss")) return word.slice(0, -1);
    return word;
  }

  function tokenize(text) {
    const lowered = text.toLowerCase();
    const raw = lowered.split(/[^\p{L}\p{N}]+/u);
    const tokens = [];
    for (const token of raw) {
      if (token.length === 0) continue;
      if (STOPWORDS.has(token)) continue;
      tokens.push(token);
    }
    return tokens;
  }

  function hashDimension(key) {
    let hash = 2166136261;
    for (let i = 0; i < key.length; i += 1) {
      hash ^= key.charCodeAt(i);
      hash = Math.imul(hash, 16777619) >>> 0;
    }
    return hash % DIMENSIONS;
  }

  function accumulate(counts, key, weight) {
    counts.set(key, (counts.get(key) ?? 0) + weight);
  }

  /** Build an L2-normalized vector for one text. */
  function embed(text) {
    const tokens = tokenize(text);
    const counts = new Map();

    for (let i = 0; i < tokens.length; i += 1) {
      const token = tokens[i];
      const stemmed = stem(token);
      accumulate(counts, `w:${stemmed}`, UNIGRAM_WEIGHT);

      const concepts = CONCEPT_INDEX.get(token) ?? CONCEPT_INDEX.get(stemmed);
      if (concepts !== undefined) {
        for (const concept of concepts) accumulate(counts, `c:${concept}`, CONCEPT_WEIGHT);
      }

      if (i + 1 < tokens.length) {
        accumulate(counts, `b:${stemmed}|${stem(tokens[i + 1])}`, BIGRAM_WEIGHT);
      }
    }

    const vector = new Float64Array(DIMENSIONS);
    for (const [key, count] of counts) {
      // Sublinear term frequency keeps long sections from being dominated by
      // one repeated word.
      vector[hashDimension(key)] += 1 + Math.log(count);
    }

    let magnitude = 0;
    for (let i = 0; i < DIMENSIONS; i += 1) magnitude += vector[i] * vector[i];
    magnitude = Math.sqrt(magnitude);
    if (magnitude > 0) {
      for (let i = 0; i < DIMENSIONS; i += 1) vector[i] /= magnitude;
    }
    return vector;
  }

  function dot(left, right) {
    let total = 0;
    for (let i = 0; i < DIMENSIONS; i += 1) total += left[i] * right[i];
    return total;
  }

  /** Cosine distance in [0, 2], matching NLEmbedding's `.cosine` distance. */
  function distance(left, right) {
    return 1 - dot(left, right);
  }

  /*
   * Language gate. The spec forbids silently applying the English model to a
   * non-English document. Without NLLanguageRecognizer this uses two robust,
   * offline signals: the dominant writing script and the English function-word
   * rate. It is intentionally permissive so that terse but valid English
   * technical notes are never rejected.
   */
  const ENGLISH_MARKERS = new Set(`the of and to in is it that for on with as at
    this be are was were by an or from not have has had will would can could
    should we you they there their which when what if but all any into more`
    .split(/\s+/u));

  function detectLanguage(sample) {
    const text = sample.slice(0, 8000);
    let latin = 0;
    let cjk = 0;
    let cyrillic = 0;
    let arabic = 0;
    let other = 0;
    for (const character of text) {
      if (/\p{Script=Latin}/u.test(character)) latin += 1;
      else if (/\p{Script=Han}|\p{Script=Hiragana}|\p{Script=Katakana}|\p{Script=Hangul}/u.test(character)) cjk += 1;
      else if (/\p{Script=Cyrillic}/u.test(character)) cyrillic += 1;
      else if (/\p{Script=Arabic}|\p{Script=Hebrew}/u.test(character)) arabic += 1;
      else if (/\p{L}/u.test(character)) other += 1;
    }
    const letters = latin + cjk + cyrillic + arabic + other;
    if (letters === 0) return "und";
    if (cjk / letters > 0.2) return "zh";
    if (cyrillic / letters > 0.3) return "ru";
    if (arabic / letters > 0.3) return "ar";
    if (latin / letters < 0.6) return "und";

    const words = text.toLowerCase().split(/[^\p{L}]+/u).filter((word) => word.length > 0);
    if (words.length < 12) return "en";
    let markers = 0;
    for (const word of words) if (ENGLISH_MARKERS.has(word)) markers += 1;
    // Latin-script prose with essentially no English function words is very
    // likely another Latin-script language.
    return markers / words.length < 0.015 ? "unknown-latin" : "en";
  }

  return {
    modelIdentifier: MODEL_IDENTIFIER,
    dimensions: DIMENSIONS,
    isAvailable: () => CONCEPT_INDEX.size > 0,
    embed,
    distance,
    dot,
    tokenize,
    detectLanguage
  };
});
