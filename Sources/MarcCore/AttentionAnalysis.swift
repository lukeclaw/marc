import Foundation
import NaturalLanguage

public enum AttentionCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case urgent
    case important
    case review

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .urgent: "Urgent"
        case .important: "Important"
        case .review: "Review"
        }
    }
}

public enum AttentionConfidence: String, Sendable {
    case strong
    case possible
    case relative

    public var label: String { rawValue.capitalized }
}

public struct AttentionChunk: Identifiable, Equatable, Sendable {
    public let id: String
    public let blockIDs: [String]
    public let breadcrumb: String
    public let sourceText: String
    public let embeddingText: String
}

public struct AttentionResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let chunkID: String
    public let blockIDs: [String]
    public let breadcrumb: String
    public let category: AttentionCategory
    public let confidence: AttentionConfidence
    public let matchedProfile: String
    public let score: Double
}

public enum AttentionAnalysisError: LocalizedError, Sendable {
    case embeddingUnavailable
    case unsupportedLanguage(String)
    case noAnalyzableContent

    public var errorDescription: String? {
        switch self {
        case .embeddingUnavailable:
            "The approved local sentence embedding model is unavailable."
        case let .unsupportedLanguage(language):
            "Attention analysis currently supports English documents. Detected \(language)."
        case .noAnalyzableContent:
            "This document does not contain enough prose to analyze."
        }
    }
}

public enum AttentionAnalyzer {
    public static let modelIdentifier = "apple-natural-language-english-v1"
    public static let profileVersion = "attention-profiles-v1"

    public static var isAvailable: Bool {
        NLEmbedding.sentenceEmbedding(for: .english) != nil
    }

    public static func documentRevision(for parsed: ParsedMarkdown) -> String {
        stableIdentifier(
            parsed.blocks
                .map { "\($0.id):\($0.signature)" }
                .joined(separator: "\n")
        )
    }

    public static func makeChunks(from parsed: ParsedMarkdown, fileName: String) -> [AttentionChunk] {
        let headingTitles = Dictionary(uniqueKeysWithValues: parsed.headings.map { ($0.id, $0.title) })
        var drafts: [ChunkDraft] = []
        var draftIndexes: [String: Int] = [:]

        for block in parsed.blocks {
            guard let text = analysisText(for: block), !text.isEmpty else { continue }
            let sectionID: String
            let breadcrumbIDs: [String]
            if case .heading = block.kind {
                sectionID = block.id
                breadcrumbIDs = block.ancestorHeadingIDs + [block.id]
            } else {
                sectionID = block.ancestorHeadingIDs.last ?? "document-introduction"
                breadcrumbIDs = block.ancestorHeadingIDs
            }
            let breadcrumb = breadcrumbIDs.compactMap { headingTitles[$0] }.joined(separator: " › ")
            let key = sectionID

            if let index = draftIndexes[key],
               drafts[index].sourceText.count + text.count < 3_500 {
                drafts[index].blockIDs.append(block.id)
                drafts[index].sourceText += "\n\n\(text)"
            } else {
                let part = drafts.filter { $0.sectionID == sectionID }.count + 1
                let draft = ChunkDraft(
                    id: "\(sectionID)-attention-\(part)",
                    sectionID: sectionID,
                    blockIDs: [block.id],
                    breadcrumb: breadcrumb.isEmpty ? fileName : breadcrumb,
                    sourceText: text
                )
                drafts.append(draft)
                draftIndexes[key] = drafts.count - 1
            }
        }

        return drafts.map { draft in
            AttentionChunk(
                id: draft.id,
                blockIDs: draft.blockIDs,
                breadcrumb: draft.breadcrumb,
                sourceText: draft.sourceText,
                embeddingText: """
                Document: \(fileName)
                Section: \(draft.breadcrumb)
                Content:
                \(draft.sourceText)
                """
            )
        }
    }

    public static func analyze(
        chunks: [AttentionChunk],
        progress: (Double) -> Void = { _ in }
    ) throws -> [AttentionResult] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw AttentionAnalysisError.embeddingUnavailable
        }
        guard !chunks.isEmpty else {
            throw AttentionAnalysisError.noAnalyzableContent
        }

        let languageSample = chunks.prefix(4).map(\.sourceText).joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(languageSample.prefix(8_000)))
        if let language = recognizer.dominantLanguage, language != .english {
            throw AttentionAnalysisError.unsupportedLanguage(language.rawValue)
        }

        var candidates: [AttentionCategory: [ScoredCandidate]] = [:]
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            for candidate in scoreCandidates(chunk: chunk, embedding: embedding) {
                candidates[candidate.category, default: []].append(candidate)
            }
            progress(Double(index + 1) / Double(chunks.count))
        }

        return AttentionCategory.allCases.flatMap { category in
            selectResults(
                from: candidates[category] ?? [],
                category: category,
                chunks: chunks
            )
        }
    }

    private static func scoreCandidates(
        chunk: AttentionChunk,
        embedding: NLEmbedding
    ) -> [ScoredCandidate] {
        let lowered = chunk.sourceText.lowercased()
        var matches: [(category: AttentionCategory, profile: String, score: Double)] = []

        for profile in profiles {
            let positiveDistance = profile.positive
                .map { Double(embedding.distance(between: chunk.embeddingText, and: $0, distanceType: .cosine)) }
                .min() ?? 2
            let negativeDistance = profile.negative
                .map { Double(embedding.distance(between: chunk.embeddingText, and: $0, distanceType: .cosine)) }
                .min() ?? 2
            let semanticSimilarity = 1 - positiveDistance
            let negativeMargin = max(0, negativeDistance - positiveDistance)
            let phraseMatches = profile.signals.filter { lowered.contains($0) }.count
            let negativeSignalMatches = profile.negativeSignals.filter { lowered.contains($0) }.count
            let signalBoost = min(0.18, Double(phraseMatches) * 0.06)
            var score = semanticSimilarity + negativeMargin * 0.35 + signalBoost
            if phraseMatches >= 2 {
                score = max(score, 0.12 + Double(min(phraseMatches - 2, 2)) * 0.03)
            } else if phraseMatches == 1 {
                score = max(score, 0.075)
            }
            score -= Double(negativeSignalMatches) * 0.12

            matches.append((profile.category, profile.name, score))
        }

        return Dictionary(grouping: matches, by: \.category)
            .compactMap { category, matches -> ScoredCandidate? in
                guard let best = matches.max(by: { $0.score < $1.score }) else { return nil }
                return ScoredCandidate(
                    chunk: chunk,
                    category: category,
                    profile: best.profile,
                    score: best.score
                )
            }
    }

    private static func selectResults(
        from candidates: [ScoredCandidate],
        category: AttentionCategory,
        chunks: [AttentionChunk]
    ) -> [AttentionResult] {
        guard let policy = categoryPolicies[category], !candidates.isEmpty else { return [] }
        let scores = candidates.map(\.score).sorted()
        let ranked = candidates.sorted { left, right in
            if left.score == right.score {
                return chunks.firstIndex(where: { $0.id == left.chunk.id }) ?? 0
                    < chunks.firstIndex(where: { $0.id == right.chunk.id }) ?? 0
            }
            return left.score > right.score
        }
        let selected = Array(ranked.prefix(policy.maximumResults))
        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { partial, score in
            partial + pow(score - mean, 2)
        } / Double(scores.count)
        let standardDeviation = sqrt(variance)

        return selected.map { candidate in
            let relativeConfidence: AttentionConfidence
            if scores.count >= 4, standardDeviation > 0 {
                let zScore = (candidate.score - mean) / standardDeviation
                if zScore >= 1.25 {
                    relativeConfidence = .strong
                } else if zScore >= 0.5 {
                    relativeConfidence = .possible
                } else {
                    relativeConfidence = .relative
                }
            } else {
                relativeConfidence = .relative
            }
            return AttentionResult(
                id: "\(candidate.chunk.id)-\(category.rawValue)",
                chunkID: candidate.chunk.id,
                blockIDs: candidate.chunk.blockIDs,
                breadcrumb: candidate.chunk.breadcrumb,
                category: category,
                confidence: relativeConfidence,
                matchedProfile: candidate.profile,
                score: candidate.score
            )
        }
    }

    private static func analysisText(for block: MarkdownBlock) -> String? {
        switch block.kind {
        case let .heading(_, title):
            return title
        case let .paragraph(text):
            return text
        case let .list(items):
            return items.map { item in
                let marker: String
                switch item.marker {
                case .bullet: marker = "•"
                case let .ordered(number): marker = "\(number)."
                case let .task(checked): marker = checked ? "[x]" : "[ ]"
                }
                return "\(marker) \(item.text)"
            }.joined(separator: "\n")
        case let .table(table):
            return ([table.headers] + table.rows)
                .map { $0.joined(separator: " | ") }
                .joined(separator: "\n")
        case let .blockquote(text):
            return text
        case let .code(language, content):
            let sample = String(content.prefix(600))
            return "Code \(language ?? "block"):\n\(sample)"
        case .horizontalRule:
            return nil
        }
    }

    private static func stableIdentifier(_ source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private struct ChunkDraft {
        let id: String
        let sectionID: String
        var blockIDs: [String]
        let breadcrumb: String
        var sourceText: String
    }

    private struct Profile {
        let category: AttentionCategory
        let name: String
        let positive: [String]
        let negative: [String]
        let signals: [String]
        let negativeSignals: [String]
    }

    private struct ScoredCandidate {
        let chunk: AttentionChunk
        let category: AttentionCategory
        let profile: String
        let score: Double
    }

    private struct CategoryPolicy {
        let maximumResults: Int
    }

    private static let categoryPolicies: [AttentionCategory: CategoryPolicy] = [
        .urgent: CategoryPolicy(maximumResults: 2),
        .important: CategoryPolicy(maximumResults: 3),
        .review: CategoryPolicy(maximumResults: 4)
    ]

    private static let profiles: [Profile] = [
        Profile(
            category: .urgent,
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
        ),
        Profile(
            category: .urgent,
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
        ),
        Profile(
            category: .important,
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
        ),
        Profile(
            category: .important,
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
        ),
        Profile(
            category: .review,
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
        ),
        Profile(
            category: .review,
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
        )
    ]
}
