/*
 * marc — on-demand attention analysis: controller and panel.
 *
 * Port of Sources/Marc/AttentionController.swift and
 * Sources/Marc/AttentionPanel.swift.
 *
 * Nothing here runs unless the reader clicks. Analysis is time-sliced so the
 * reader and editor stay usable while it runs, and cancellation is immediate.
 */
"use strict";

const MarcAttentionUI = (() => {
  const SLICE_BUDGET_MS = 8;

  const CATEGORY_STYLE = {
    urgent: { color: "var(--urgent)", icon: "warning", limit: "Top 2 in document" },
    important: { color: "var(--important)", icon: "star", limit: "Top 3 in document" },
    review: { color: "var(--attention)", icon: "checkBubble", limit: "Top 4 in document" }
  };

  /* ---------------------------------------------------------- controller */

  function start(store, document_, force) {
    if (document_.hasCurrentAttentionResults && force !== true) return;

    if (!MarcAttention.isAvailable()) {
      document_.attentionState = "unavailable";
      document_.attentionMessage = "The approved local sentence embedding model is unavailable.";
      store.emit("attention");
      return;
    }

    const revision = document_.currentAttentionRevision;
    const chunks = MarcAttention.makeChunks(document_.parsed, document_.fileName);

    document_.cancelAttentionAnalysis();
    document_.attentionProgress = 0;
    document_.attentionProcessedChunks = 0;
    document_.attentionTotalChunks = chunks.length;
    document_.attentionResults = [];
    document_.attentionRevision = null;

    let run;
    try {
      run = MarcAttention.createRun(chunks);
    } catch (error) {
      document_.attentionState = "failed";
      document_.attentionMessage = error.message;
      store.emit("attention", "tabs", "toc", "gutters");
      return;
    }

    document_.attentionState = "running";
    document_.attentionMessage = "";
    const token = { cancelled: false };
    document_.attentionRun = token;
    store.emit("attention", "tabs", "toc");

    const pump = () => {
      if (token.cancelled) return;
      const deadline = performance.now() + SLICE_BUDGET_MS;
      while (!run.isComplete && performance.now() < deadline) {
        document_.attentionProgress = run.step();
        document_.attentionProcessedChunks = run.processed;
      }

      if (run.isComplete) {
        let results;
        try {
          results = run.finish();
        } catch (error) {
          document_.attentionRun = null;
          document_.attentionState = "failed";
          document_.attentionMessage = error.message;
          store.emit("attention");
          return;
        }
        document_.attentionRun = null;
        // A document that changed mid-run makes this result stale on arrival.
        if (document_.currentAttentionRevision !== revision) {
          document_.attentionState = "idle";
          document_.attentionProgress = 0;
          document_.attentionProcessedChunks = 0;
          document_.attentionTotalChunks = 0;
          store.emit("attention");
          return;
        }
        document_.attentionResults = results;
        document_.attentionRevision = revision;
        document_.attentionProgress = 1;
        document_.attentionProcessedChunks = document_.attentionTotalChunks;
        document_.attentionState = "ready";
        store.emit("attention", "tabs", "toc", "gutters");
        return;
      }

      store.emit("attention");
      setTimeout(pump, 0);
    };

    setTimeout(pump, 0);
  }

  function cancel(store, document_) {
    document_.cancelAttentionAnalysis();
    store.emit("attention", "tabs", "toc", "gutters");
  }

  /* -------------------------------------------------------- disclosure UI */

  function disclosure(callbacks) {
    const available = MarcAttention.isAvailable();
    const analyzeButton = UI.el("button.primary-button.purple", {
      text: "Analyze",
      disabled: !available,
      on: { click: callbacks.analyze }
    });

    return UI.el("div", null, [
      UI.el("h2", { style: { color: "var(--attention)" }, text: "Local Attention Analysis" }),
      UI.el("div.caption", {
        style: { marginTop: "8px" },
        text:
          "marc will use its bundled local embedding model to suggest a small number of " +
          "urgent, important, or review-worthy passages."
      }),
      UI.el("div.disclosure-list", null, [
        UI.el("div", null, [UI.icon("tap"), UI.el("span", { text: "Runs only when you request it" })]),
        UI.el("div", null, [
          UI.icon("noNetwork"),
          UI.el("span", { text: "No network requests or notifications" })
        ]),
        UI.el("div", null, [
          UI.icon("quote"),
          UI.el("span", { text: "Suggestions link to original source text" })
        ])
      ]),
      available
        ? null
        : UI.el("div.caption", {
            style: { color: "var(--changed)" },
            text: "The approved local embedding model is unavailable."
          }),
      UI.el("div.popover-actions", null, [
        UI.el("button.secondary-button", { text: "Cancel", on: { click: callbacks.cancel } }),
        analyzeButton
      ])
    ]);
  }

  /* --------------------------------------------------------------- panel */

  function resultPriority(result) {
    const confidence = { strong: 3, possible: 2, relative: 1 }[result.confidence] ?? 1;
    const category = { urgent: 3, review: 2, important: 1 }[result.category] ?? 0;
    return [confidence, result.score, category];
  }

  function comparePriority(left, right) {
    const a = resultPriority(left);
    const b = resultPriority(right);
    for (let index = 0; index < a.length; index += 1) {
      if (a[index] !== b[index]) return a[index] - b[index];
    }
    return 0;
  }

  /* One section appears once, under its strongest relative category. */
  function displayResults(document_) {
    const bestByChunk = new Map();
    for (const result of document_.attentionResults) {
      const existing = bestByChunk.get(result.chunkID);
      if (existing === undefined || comparePriority(result, existing) > 0) {
        bestByChunk.set(result.chunkID, result);
      }
    }
    return [...bestByChunk.values()];
  }

  function resultsForCategory(document_, category) {
    return displayResults(document_)
      .filter((result) => result.category === category)
      .sort((left, right) => {
        if (left.score === right.score) return left.breadcrumb.localeCompare(right.breadcrumb);
        return right.score - left.score;
      });
  }

  function orderedResults(document_) {
    return MarcAttention.categories.flatMap((category) => resultsForCategory(document_, category));
  }

  function panel(store, document_, callbacks) {
    const node = UI.el("aside.sidebar.attention");
    node.append(
      UI.el("div.sidebar-header", null, [
        UI.el("div", { style: { flex: "1", minWidth: "0" } }, [
          UI.el("div", { text: "Suggested Attention" }),
          UI.el("div", {
            style: { fontSize: "10.5px", fontWeight: "400", color: "var(--chrome-tertiary)" },
            text: "Local embeddings · Beta"
          })
        ]),
        UI.el("button.tool-button", {
          title: "Close",
          on: { click: callbacks.close },
          style: { padding: "0 4px" }
        }, [UI.icon("close")])
      ])
    );

    if (document_.attentionResultsAreStale && document_.attentionResults.length > 0) {
      node.append(
        UI.el("div.banner", { style: { background: "rgba(217,119,6,0.09)" } }, [
          UI.icon("history"),
          UI.el("span", { style: { fontSize: "11.5px" }, text: "Results are for an older document version." }),
          UI.el("span.spacer"),
          UI.el("button.link-button", {
            text: "Analyze Again",
            on: { click: () => start(store, document_, true) }
          })
        ])
      );
    }

    node.append(content(store, document_, callbacks));
    return node;
  }

  function content(store, document_, callbacks) {
    switch (document_.attentionState) {
      case "running":
        return runningState(store, document_);
      case "ready":
        if (document_.attentionResults.length === 0) {
          return emptyState({
            title: "No Suggestions Visible",
            description:
              "All ranked suggestions were dismissed. Run the analysis again to restore them.",
            buttonTitle: "Analyze Again",
            action: () => start(store, document_, true)
          });
        }
        return resultsList(store, document_, callbacks);
      case "unavailable":
        return UI.el("div.empty-state", null, [
          UI.icon("brain"),
          UI.el("div.title", { text: "Local Model Unavailable" }),
          UI.el("div.description", { text: document_.attentionMessage })
        ]);
      case "failed":
        return emptyState({
          title: "Analysis Failed",
          description: document_.attentionMessage,
          buttonTitle: "Try Again",
          action: () => start(store, document_, true)
        });
      default:
        return emptyState({
          title: "Analyze This File",
          description:
            "Rank a small number of passages that may be urgent, important, or need review.",
          buttonTitle: "Analyze Attention",
          action: () => start(store, document_, false)
        });
    }
  }

  function progressDescription(document_) {
    const total = document_.attentionTotalChunks;
    const processed = document_.attentionProcessedChunks;
    if (total === 0) return "Preparing semantic sections…";
    if (processed >= total) return "Ranking category distributions…";
    return `Embedding and scoring section ${Math.max(1, processed + 1)} of ${total}`;
  }

  function runningState(store, document_) {
    const percent = Math.round(document_.attentionProgress * 100);
    return UI.el("div.empty-state", null, [
      UI.el("div.progress-track", null, [
        UI.el("div.progress-fill", { style: { width: `${percent}%` } })
      ]),
      UI.el("div", { style: { fontSize: "12.5px" }, text: `Analyzing ${document_.fileName} locally…` }),
      UI.el("div.description", { text: progressDescription(document_) }),
      UI.el("div.description", { style: { fontVariantNumeric: "tabular-nums" }, text: `${percent}%` }),
      UI.el("div.description", {
        style: { color: "var(--chrome-tertiary)", fontSize: "11px" },
        text:
          "Each section is embedded and scored, then only the strongest results in each " +
          "category are retained."
      }),
      UI.el("button.secondary-button", {
        text: "Cancel",
        on: { click: () => cancel(store, document_) }
      })
    ]);
  }

  function emptyState({ title, description, buttonTitle, action }) {
    return UI.el("div", { style: { display: "flex", flexDirection: "column", flex: "1", minHeight: "0" } }, [
      UI.el("div.empty-state", null, [
        UI.icon("scope", "attention-glyph"),
        UI.el("div.title", { text: title }),
        UI.el("div.description", { text: description }),
        UI.el("button.primary-button.purple", { text: buttonTitle, on: { click: action } })
      ]),
      UI.el("div.attention-footer", {
        text: "Suggestions are not facts. Every result points to source text."
      })
    ]);
  }

  function resultsList(store, document_, callbacks) {
    const visible = displayResults(document_);
    const container = UI.el("div", {
      style: { display: "flex", flexDirection: "column", flex: "1", minHeight: "0" }
    });

    container.append(
      UI.el("div", {
        style: {
          display: "flex",
          alignItems: "center",
          padding: "8px 12px",
          borderBottom: "1px solid var(--chrome-border)"
        }
      }, [
        UI.el("span", {
          style: { fontSize: "11.5px", color: "var(--chrome-secondary)" },
          text: `${visible.length} highlighted section${visible.length === 1 ? "" : "s"}`
        }),
        UI.el("span.spacer", { style: { flex: "1" } }),
        UI.el("button.link-button", {
          text: "Analyze Again",
          on: { click: () => start(store, document_, true) }
        })
      ])
    );

    const body = UI.el("div.sidebar-body.scroll", { style: { padding: "10px" } });
    const ordered = orderedResults(document_);
    const cards = new Map();

    for (const category of MarcAttention.categories) {
      const categoryResults = resultsForCategory(document_, category);
      if (categoryResults.length === 0) continue;

      const style = CATEGORY_STYLE[category];
      const relativeOnly = categoryResults.every((result) => result.confidence === "relative");
      const group = UI.el("div.attention-group");
      group.append(
        UI.el("div.attention-category", null, [
          UI.icon(style.icon, "category-glyph"),
          UI.el("span.name", { text: MarcAttention.categoryLabels[category] }),
          UI.badge(categoryResults.length, style.color),
          UI.el("span.limit", { text: relativeOnly ? "Best relative matches" : style.limit })
        ])
      );
      group.querySelector(".category-glyph").style.stroke = style.color;

      const list = UI.el("div.cards");
      categoryResults.forEach((result, index) => {
        const card = resultCard(store, document_, result, index + 1, style, callbacks);
        cards.set(result.id, card);
        list.append(card);
      });
      group.append(list);
      body.append(group);
    }

    /* Arrow keys move focus between rows; Enter jumps to the passage. */
    body.addEventListener("keydown", (event) => {
      if (!["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight"].includes(event.key)) return;
      event.preventDefault();
      const focusedID = document.activeElement?.dataset?.resultId ?? null;
      const currentIndex = ordered.findIndex((result) => result.id === focusedID);
      const delta = event.key === "ArrowDown" || event.key === "ArrowRight" ? 1 : -1;
      const nextIndex = Math.max(0, Math.min(ordered.length - 1, (currentIndex < 0 ? 0 : currentIndex) + delta));
      const next = cards.get(ordered[nextIndex]?.id);
      if (next !== undefined) next.focus();
    });

    container.append(body);
    return container;
  }

  function resultCard(store, document_, result, rank, style, callbacks) {
    const components = result.breadcrumb.split(" › ").filter((part) => part.length > 0);
    const title = components[components.length - 1] ?? result.breadcrumb;
    const parents = components.slice(0, -1).join(" › ");
    const stale = document_.attentionResultsAreStale;

    const meta = [result.matchedProfile, "·", `#${rank}`];
    if (result.confidence !== "relative") {
      meta.push("·", result.confidence.charAt(0).toUpperCase() + result.confidence.slice(1));
    }

    const jump = () => callbacks.jump(result);

    const card = UI.el(
      "button.attention-card",
      {
        title: `Jump to ${result.breadcrumb}`,
        class: stale ? "stale" : "",
        tabIndex: 0,
        dataset: { resultId: result.id },
        style: { borderColor: `color-mix(in srgb, ${style.color} ${stale ? "14%" : "28%"}, transparent)` },
        on: {
          click: jump,
          keydown: (event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              jump();
            }
          },
          contextmenu: (event) =>
            UI.contextMenuAt(
              [
                { label: "Jump to Passage", action: jump },
                { separator: true },
                {
                  label: "Dismiss Suggestion",
                  action: () => {
                    document_.dismissAttentionChunk(result.chunkID);
                    store.emit("attention", "tabs", "toc", "gutters");
                  }
                }
              ],
              event
            )
        }
      },
      [
        UI.el("div.rail", { style: { background: style.color } }),
        UI.el("div.body", null, [
          UI.el("div.headline", { text: title }),
          parents.length === 0 ? null : UI.el("div.parents", { text: parents }),
          UI.el("div.meta", { text: meta.join(" ") })
        ]),
        UI.icon("chevronRight", "chevron")
      ]
    );
    card.querySelector(".chevron").style.stroke = style.color;
    return card;
  }

  return { start, cancel, panel, disclosure, displayResults, orderedResults };
})();
