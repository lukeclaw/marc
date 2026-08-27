import Foundation
import MarcCore

enum AttentionRunState: Equatable {
    case idle
    case running
    case ready
    case unavailable(String)
    case failed(String)
}

extension MarkdownDocument {
    var currentAttentionRevision: String {
        AttentionAnalyzer.documentRevision(for: parsed)
    }

    var attentionResultsAreStale: Bool {
        guard let attentionRevision else { return false }
        return attentionRevision != currentAttentionRevision
    }

    var hasCurrentAttentionResults: Bool {
        attentionState == .ready &&
            attentionRevision == currentAttentionRevision
    }

    var attentionSuggestionCount: Int {
        Set(attentionResults.map(\.chunkID)).count
    }

    func attentionResult(for blockID: String) -> AttentionResult? {
        attentionResults.first { $0.blockIDs.contains(blockID) }
    }

    func startAttentionAnalysis(force: Bool = false) {
        if hasCurrentAttentionResults && !force {
            return
        }
        guard AttentionAnalyzer.isAvailable else {
            attentionState = .unavailable("The approved local sentence embedding model is unavailable.")
            return
        }

        let revision = currentAttentionRevision
        let chunks = AttentionAnalyzer.makeChunks(from: parsed, fileName: url.lastPathComponent)
        guard !chunks.isEmpty else {
            attentionState = .failed("This document does not contain enough prose to analyze.")
            return
        }

        attentionTask?.cancel()
        attentionProgress = 0
        attentionProcessedChunks = 0
        attentionTotalChunks = chunks.count
        attentionResults = []
        attentionRevision = nil
        attentionState = .running

        attentionTask = Task { @MainActor [weak self] in
            let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
            let worker = Task.detached(priority: .userInitiated) {
                defer { progressContinuation.finish() }
                return try AttentionAnalyzer.analyze(chunks: chunks) { progress in
                    progressContinuation.yield(progress)
                }
            }
            let progressTask = Task { @MainActor [weak self] in
                for await progress in progressStream {
                    guard let self, self.attentionState == .running else { return }
                    self.attentionProgress = progress
                    self.attentionProcessedChunks = min(
                        self.attentionTotalChunks,
                        Int((progress * Double(self.attentionTotalChunks)).rounded())
                    )
                }
            }
            do {
                let results = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                progressTask.cancel()
                guard let self, self.currentAttentionRevision == revision else { return }
                self.attentionResults = results
                self.attentionRevision = revision
                self.attentionProgress = 1
                self.attentionProcessedChunks = self.attentionTotalChunks
                self.attentionState = .ready
                self.attentionTask = nil
            } catch is CancellationError {
                progressTask.cancel()
                guard let self, self.attentionState == .running else { return }
                self.attentionState = .idle
                self.attentionProgress = 0
                self.attentionProcessedChunks = 0
                self.attentionTotalChunks = 0
                self.attentionTask = nil
            } catch {
                progressTask.cancel()
                guard let self else { return }
                self.attentionState = .failed(error.localizedDescription)
                self.attentionProgress = 0
                self.attentionProcessedChunks = 0
                self.attentionTotalChunks = 0
                self.attentionTask = nil
            }
        }
    }

    func cancelAttentionAnalysis() {
        attentionTask?.cancel()
        attentionTask = nil
        attentionProgress = 0
        attentionProcessedChunks = 0
        attentionTotalChunks = 0
        attentionState = .idle
    }

    func dismissAttentionChunk(_ chunkID: String) {
        attentionResults.removeAll { $0.chunkID == chunkID }
    }
}
