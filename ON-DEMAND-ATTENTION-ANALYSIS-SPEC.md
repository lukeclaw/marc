# On-Demand Attention Analysis Specification

**Implementation status:** Beta. The local Apple embedding engine, explicit
trigger, cancellable panel, source-linked results, stale state, and UI markers
are implemented. Release readiness still depends on the evaluation thresholds
in this specification.

## Summary

marc may offer an explicitly requested, local-only analysis that ranks document
sections likely to deserve immediate human attention. The initial labels are:

- **Urgent**: potentially time-sensitive, blocking, failing, or harmful
- **Important**: consequential decisions, risks, dependencies, or scope changes
- **Review necessary**: unresolved questions, ambiguity, requested approval, or
  claims that explicitly require verification

This feature is a reading aid, not a truth detector. Vector embeddings measure
semantic similarity; they do not prove that a passage is urgent or correct.
Results must therefore be presented as suggestions tied directly to source text.

## True-north test

The feature is successful only if it helps the reader answer:

> Which few passages should I inspect first?

It must not become summarization, rewriting, chat, autonomous monitoring, or a
general document assistant.

## Product constraints

1. Analysis runs only after the user clicks **Analyze Attention**.
2. Opening, scrolling, editing, or externally updating a file never starts it.
3. No system notifications are used.
4. Version 1 performs no network requests and requires no account.
5. Markdown is never modified by analysis.
6. Every result includes and navigates to the exact source passage.
7. Suggestions are visually separate from deterministic unread/update markers.
8. If the document changes, existing results become stale and are not
   automatically regenerated.
9. The feature favors a few high-confidence results over broad coverage.

## User experience

### Starting an analysis

The toolbar contains an **Analyze Attention** button. Selecting it opens a small
confirmation popover describing:

- the current file being analyzed;
- that processing is local and on demand;
- that results are suggestions, not facts; and
- the approximate number of sections to process.

The user starts the run explicitly. A cancellable progress indicator appears in
the attention panel. The editor and reader remain usable.

### Results panel

Results appear in a temporary right-side panel with separate **Urgent**,
**Important**, and **Review** sections. Each result contains:

- heading breadcrumb;
- confidence band: **strong**, **possible**, or **relative**;
- the matched review profile, such as “blocking failure” or “approval needed”;
- its rank within the category; and
- a whole-row **Jump to passage** action.

The UI must say **Suggested attention**, never “AI detected” or “This is urgent.”
It must not restate the source passage or generate a rationale in new prose. The
panel is a compact navigator, not an alternate reading surface. Dismissal is a
contextual action rather than permanent card chrome.

Each category is ranked independently against the full document distribution.
Urgent shows at most two results, Important three, and Review four.
Adjacent matching chunks are merged into one section result. Empty categories
are hidden.

If one section ranks in multiple categories, the navigator shows it once under
its strongest relative category. Arrow keys move focus between rows, Enter jumps
to the passage, and the destination receives a temporary purple highlight.

While analysis runs, the panel shows:

- a determinate progress bar and percentage;
- the current section number and total section count;
- the active phase, such as embedding/scoring or distribution ranking; and
- a plain-language explanation that only the strongest category results survive.

### Document integration

Attention suggestions use a distinct purple marker. Existing states remain:

- blue: unread;
- orange: externally updated; and
- purple: on-demand attention suggestion.

Tab and outline badges may show a small purple count only while current analysis
results are open. Attention results do not change read/unread state.

### Staleness

An analysis is keyed to the document revision captured when the user clicked the
button. If the content changes:

- the panel shows **Results are for an older version**;
- markers become visually subdued;
- navigation still targets surviving block identities when possible; and
- the user may click **Analyze Again**.

marc never reruns automatically.

## Analysis unit

The parser produces analysis chunks from semantic Markdown structure:

1. A heading and its breadcrumb provide section context.
2. Paragraphs, list groups, block quotes, and table rows provide content.
3. Fenced code is represented by its language and nearby explanatory prose;
   large raw code bodies are not embedded in full.
4. Very short adjacent blocks are combined.
5. Long sections are divided at block boundaries into approximately 300–600
   words with one neighboring block of overlap.

Each embedding input has this form:

```text
Document: <file name>
Section: <H1 > H2 > H3 breadcrumb>
Content:
<original section text>
```

Chunks retain their source block IDs and ranges. No generated text is added to
the embedding input.

## Model strategy

### Version 1: Apple Natural Language

Use the system `NaturalLanguage` framework and its sentence embedding capability
through `NLEmbedding`. This avoids executable plugins, arbitrary downloaded
models, network providers, and new runtime dependencies.

The analyzer checks model availability before showing the start action. If the
required language embedding is unavailable, marc disables analysis and explains
that no approved local embedding model is available. It does not download a
replacement.

Initially, analysis supports English documents. Language detection and additional
system-supported embeddings may be added only after per-language evaluation.

### Future model providers

An optional Core ML embedding model may be considered only if it is:

- approved and reviewed for enterprise use;
- signed or bundled with a reviewed marc release;
- fully local at runtime;
- versioned with its evaluation data; and
- selected explicitly in settings.

marc must not load arbitrary model files, execute model-provided code, or install
models from URLs.

## Review profiles

Embeddings are not sent directly into a three-label classifier. They are compared
with bundled, human-reviewed prototype sets.

### Urgent profiles

- active failure, outage, or data corruption;
- blocking dependency or inability to proceed;
- imminent deadline or expiration;
- security, privacy, or destructive-action risk; and
- immediate rollback or intervention requested.

### Important profiles

- consequential decision or recommendation;
- scope, contract, or behavior change;
- material risk or tradeoff;
- dependency affecting multiple components or people; and
- irreversible or expensive action.

### Review-necessary profiles

- explicit request for approval or review;
- unresolved question, ambiguity, or contradiction;
- low-confidence statement or unverified assumption;
- proposed behavior requiring human judgment; and
- failed or missing validation.

Each profile contains positive prototypes and confusing negative prototypes. For
example, “the test documents an expected failure” must not score like “production
is currently failing.”

Prototype text is inert, bundled data reviewed in source control. It is not
editable Markdown and cannot execute code.

## Scoring

For each chunk:

1. Compute its normalized sentence embedding.
2. Calculate cosine similarity against every positive and negative prototype.
3. Derive a profile score from the strongest positive similarity, profile
   centroid similarity, and negative-example margin.
4. Apply small deterministic adjustments only for explicit signals such as an
   unchecked task, “approval required,” or a failed-validation marker.
5. Merge neighboring results belonging to the same section.
6. Build the score distribution for each category across the entire document.
7. Rank every section within its category distribution.
8. Keep only that category's fixed top result count.
9. Derive confidence from relative separation within the document.

Scores remain internal. The UI shows **strong** or **possible**, not percentages,
because numeric precision would imply certainty the model does not provide.

Categories may overlap. A blocking security decision can appear in both Urgent
and Important when it independently clears both distributions.

### Category policies

Initial beta policies are deliberately asymmetric:

| Category | Selection |
|---|---:|
| Urgent | Top 2 sections |
| Important | Top 3 sections |
| Review | Top 4 sections |

There are no absolute score floors. “Strong,” “Possible,” and “Relative” describe
how far a selected section stands above the document's own category distribution,
not a hidden global confidence threshold. This guarantees bounded results without
allowing broad Important scores to consume the panel.

## Architecture

### Prerequisite

The parsed document must be cached and invalidated only when content changes.
Attention analysis must not add another full-document parse to scrolling or view
rendering.

### Components

```swift
protocol AttentionEmbeddingProvider {
    var modelIdentifier: String { get }
    func embed(_ texts: [String]) async throws -> [[Double]]
}

struct AttentionAnalysisRequest {
    let documentURL: URL
    let documentRevision: String
    let chunks: [AttentionChunk]
}

struct AttentionResult {
    let chunkID: String
    let blockIDs: [String]
    let category: AttentionCategory
    let confidence: AttentionConfidence
    let matchedProfile: String
}
```

- `AttentionChunker`: creates source-linked semantic chunks.
- `AppleSentenceEmbeddingProvider`: wraps `NLEmbedding`.
- `AttentionProfileStore`: loads reviewed bundled prototype data.
- `AttentionScorer`: computes similarity, category distributions, relative
  confidence, and fixed top-result selection.
- `AttentionAnalysisController`: owns explicit run, cancellation, progress, and
  staleness.
- `AttentionPanel`: displays results and navigation.

Embedding and scoring run outside the main actor. Only progress and final results
return to the UI actor.

## Storage and caching

Results are ephemeral by default. marc may cache embeddings and results locally
using this key:

```text
model version + profile version + document revision + chunk revision
```

The cache exists only to make a repeated user-requested run faster. A cache hit
does not display analysis until the user clicks **Analyze Attention**.

The cache:

- stores no credentials;
- is bounded by size and age;
- can be cleared from settings;
- is invalidated by model/profile changes; and
- never causes background analysis.

User dismissals and optional **Useful / Not useful** feedback remain local.
Feedback is evaluation data, not an automatic online-learning signal.

## Failure behavior

- **Embedding unavailable:** disable analysis with a clear local-model message.
- **Unsupported language:** do not silently use an English model.
- **Document changes during analysis:** discard the run as stale.
- **Cancellation:** return no partial markers unless the user explicitly opens
  partial results.
- **Individual chunk failure:** surface the incomplete run; do not return a
  success-shaped empty category.
- **Low relative separation:** show the category's top results as **Relative**,
  not as an absolute classification.

## Evaluation

False positives are more damaging than missed passages because they make the
reader ignore all intelligence markers. Evaluation therefore optimizes
precision before recall.

Create a reviewed corpus of representative AI-authored Markdown containing:

- incidents and operational reports;
- implementation plans and specifications;
- code-review reports;
- investigation results;
- status updates;
- deliberately verbose but low-importance prose; and
- hard negatives using words like “failure,” “urgent,” or “risk” in harmless
  contexts.

Required measurements:

- precision at 5 for each category;
- category ranking quality at the fixed `2/3/4` result quotas;
- false-positive rate on hard negatives;
- reviewer agreement on category definitions;
- analysis latency by document size; and
- result stability after harmless whitespace or Markdown reflow.

Minimum ship thresholds on the reviewed evaluation corpus:

- overall precision at 5 of at least 0.80;
- urgent precision at 5 of at least 0.90;
- hard-negative false-positive rate below 0.05;
- no more than nine displayed category results for every document;
- median analysis under two seconds for a 1 MB document; and
- median analysis under five seconds for a 5 MB document on the baseline
  supported Apple Silicon Mac.

If these thresholds are not met, the feature does not ship. Lowering thresholds
or adding generated explanations is not an acceptable substitute.

## Acceptance criteria

1. No analysis starts without a direct click.
2. No network request occurs during model availability checks or analysis.
3. No notification permission is requested.
4. Every result links to unchanged source text.
5. A changed document never triggers an automatic rerun.
6. Low-separation documents label selected results **Relative**.
7. Results are capped and ranked; the feature never marks most of a document.
8. Whitespace-only reflow does not materially alter rankings.
9. Scrolling remains responsive while analysis runs.
10. The feature can be fully disabled without affecting core reading behavior.
11. All minimum evaluation thresholds are met before release.

## Implementation phases

### Phase 0: foundation

- Cache parsed documents.
- Establish stable block source ranges and document revision IDs.
- Add performance measurements for large files.

### Phase 1: offline evaluation harness

- Define and review category prototypes.
- Build chunking and scoring as a command-line check target.
- Tune thresholds against the labeled corpus before creating UI.

### Phase 2: on-demand engine

- Implement the Apple embedding provider.
- Add cancellation, progress, staleness, cache bounds, and explicit errors.
- Confirm through instrumentation that no automatic invocation path exists.

### Phase 3: restrained UI

- Add **Analyze Attention**.
- Add the temporary panel, source navigation, category tags, and purple markers.
- Add result dismissal and optional local feedback.

### Phase 4: decision gate

Ship only if reviewer-measured precision is high enough that the top results save
time. If results are merely plausible or frequently obvious, remove the feature
rather than expanding it.

## Explicit non-goals

- summaries or rewritten views;
- chat or question answering;
- inferred truth, correctness, or severity guarantees;
- automatic background analysis;
- folder-wide surveillance;
- system notifications;
- cloud model providers in version 1;
- arbitrary model installation; and
- modifying Markdown to store classifications.
