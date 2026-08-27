import MarcCore
import SwiftUI

struct AttentionPanel: View {
    @ObservedObject var document: MarkdownDocument
    @Binding var mode: WorkspaceMode
    @Binding var navigationTarget: String?
    @Binding var highlightTarget: String?
    let close: () -> Void
    @FocusState private var focusedResultID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested Attention")
                        .font(.headline)
                    Text("Local embeddings · Beta")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            if document.attentionResultsAreStale, !document.attentionResults.isEmpty {
                staleBanner
                Divider()
            }

            content
        }
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch document.attentionState {
        case .idle:
            emptyState(
                title: "Analyze This File",
                description: "Rank a small number of passages that may be urgent, important, or need review.",
                buttonTitle: "Analyze Attention"
            ) {
                document.startAttentionAnalysis()
            }

        case .running:
            VStack(spacing: 16) {
                Spacer()
                ProgressView(value: document.attentionProgress, total: 1)
                    .frame(width: 250)
                Text("Analyzing \(document.url.lastPathComponent) locally…")
                    .font(.callout)
                Text(progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(document.attentionProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Each section is embedded and scored, then only the strongest results in each category are retained.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                Button("Cancel") {
                    document.cancelAttentionAnalysis()
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)

        case .ready:
            if document.attentionResults.isEmpty {
                emptyState(
                    title: "No Suggestions Visible",
                    description: "All ranked suggestions were dismissed. Run the analysis again to restore them.",
                    buttonTitle: "Analyze Again"
                ) {
                    document.startAttentionAnalysis(force: true)
                }
            } else {
                resultsList
            }

        case let .unavailable(message):
            ContentUnavailableView(
                "Local Model Unavailable",
                systemImage: "brain.head.profile",
                description: Text(message)
            )

        case let .failed(message):
            emptyState(
                title: "Analysis Failed",
                description: message,
                buttonTitle: "Try Again"
            ) {
                document.startAttentionAnalysis(force: true)
            }
        }
    }

    private var progressDescription: String {
        let total = document.attentionTotalChunks
        let processed = document.attentionProcessedChunks
        guard total > 0 else { return "Preparing semantic sections…" }
        if processed >= total {
            return "Ranking category distributions…"
        }
        return "Embedding and scoring section \(max(1, processed + 1)) of \(total)"
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(displayResults.count) highlighted section\(displayResults.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Analyze Again") {
                    document.startAttentionAnalysis(force: true)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(AttentionCategory.allCases) { category in
                        let categoryResults = results(for: category)
                        if !categoryResults.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                AttentionCategoryHeader(
                                    category: category,
                                    count: categoryResults.count,
                                    relativeOnly: categoryResults.allSatisfy { $0.confidence == .relative }
                                )
                                ForEach(Array(categoryResults.enumerated()), id: \.element.id) { index, result in
                                    AttentionResultCard(
                                        result: result,
                                        rank: index + 1,
                                        stale: document.attentionResultsAreStale,
                                        jump: {
                                            jump(to: result)
                                        },
                                        dismiss: {
                                            document.dismissAttentionChunk(result.chunkID)
                                        }
                                    )
                                    .focused($focusedResultID, equals: result.id)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .onMoveCommand(perform: moveFocus)
            .onAppear {
                if focusedResultID == nil {
                    focusedResultID = orderedDisplayResults.first?.id
                }
            }
        }
    }

    private var displayResults: [AttentionResult] {
        var bestByChunk: [String: AttentionResult] = [:]
        for result in document.attentionResults {
            if let existing = bestByChunk[result.chunkID] {
                if resultPriority(result) > resultPriority(existing) {
                    bestByChunk[result.chunkID] = result
                }
            } else {
                bestByChunk[result.chunkID] = result
            }
        }
        return Array(bestByChunk.values)
    }

    private var orderedDisplayResults: [AttentionResult] {
        AttentionCategory.allCases.flatMap(results)
    }

    private func results(for category: AttentionCategory) -> [AttentionResult] {
        displayResults
            .filter { $0.category == category }
            .sorted {
                if $0.score == $1.score {
                    return $0.breadcrumb < $1.breadcrumb
                }
                return $0.score > $1.score
            }
    }

    private func resultPriority(_ result: AttentionResult) -> (Int, Double, Int) {
        let confidence: Int
        switch result.confidence {
        case .strong: confidence = 3
        case .possible: confidence = 2
        case .relative: confidence = 1
        }
        let category: Int
        switch result.category {
        case .urgent: category = 3
        case .review: category = 2
        case .important: category = 1
        }
        return (confidence, result.score, category)
    }

    private func jump(to result: AttentionResult) {
        guard let blockID = result.blockIDs.first else { return }
        mode = .rendered
        navigationTarget = blockID
        highlightTarget = blockID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if highlightTarget == blockID {
                highlightTarget = nil
            }
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let results = orderedDisplayResults
        guard !results.isEmpty else { return }
        let current = focusedResultID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        switch direction {
        case .up, .left:
            focusedResultID = results[max(0, current - 1)].id
        case .down, .right:
            focusedResultID = results[min(results.count - 1, current + 1)].id
        default:
            break
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            Text("Results are for an older document version.")
                .font(.caption)
            Spacer()
            Button("Analyze Again") {
                document.startAttentionAnalysis(force: true)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.09))
    }

    private func emptyState(
        title: String,
        description: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "scope")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.purple)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            Spacer()
            Text("Suggestions are not facts. Every result points to source text.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct AttentionCategoryHeader: View {
    let category: AttentionCategory
    let count: Int
    let relativeOnly: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(category.label)
                .font(.subheadline.bold())
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.12), in: Capsule())
            Spacer()
            Text(relativeOnly ? "Best relative matches" : limitDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var color: Color {
        switch category {
        case .urgent: .red
        case .important: .indigo
        case .review: .purple
        }
    }

    private var icon: String {
        switch category {
        case .urgent: "exclamationmark.triangle.fill"
        case .important: "star.fill"
        case .review: "checkmark.bubble.fill"
        }
    }

    private var limitDescription: String {
        switch category {
        case .urgent: "Top 2 in document"
        case .important: "Top 3 in document"
        case .review: "Top 4 in document"
        }
    }
}

private struct AttentionResultCard: View {
    let result: AttentionResult
    let rank: Int
    let stale: Bool
    let jump: () -> Void
    let dismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(categoryColor)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stale ? .secondary : .primary)
                        .lineLimit(2)

                    if !parentPath.isEmpty {
                        Text(parentPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Text(result.matchedProfile)
                            .lineLimit(1)
                        Text("·")
                        Text("#\(rank)")
                            .monospacedDigit()
                        if result.confidence != .relative {
                            Text("·")
                            Text(result.confidence.label)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(categoryColor)
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(
                isHovered ? categoryColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(categoryColor.opacity(stale ? 0.14 : 0.28), lineWidth: 1)
        }
        .opacity(stale ? 0.7 : 1)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Jump to Passage", action: jump)
            Divider()
            Button("Dismiss Suggestion", action: dismiss)
        }
        .help("Jump to \(result.breadcrumb)")
    }

    private var breadcrumbComponents: [String] {
        result.breadcrumb
            .components(separatedBy: " › ")
            .filter { !$0.isEmpty }
    }

    private var title: String {
        breadcrumbComponents.last ?? result.breadcrumb
    }

    private var parentPath: String {
        breadcrumbComponents.dropLast().joined(separator: " › ")
    }

    private var categoryColor: Color {
        switch result.category {
        case .urgent: .red
        case .important: .indigo
        case .review: .purple
        }
    }
}
