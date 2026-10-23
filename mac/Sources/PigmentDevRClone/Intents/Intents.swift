import AppIntents
import Foundation
import RCloneKit

struct JobEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Sync Job" }
    static var defaultQuery: JobQuery { JobQuery() }

    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct JobQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [JobEntity] {
        await MainActor.run {
            AppEnvironment.shared.model.jobs.filter { identifiers.contains($0.id) }.map { JobEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [JobEntity] {
        await MainActor.run { AppEnvironment.shared.model.jobs.map { JobEntity(id: $0.id, name: $0.name) } }
    }
}

struct RunJobIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Sync Job" }
    static var description: IntentDescription { IntentDescription("Starts a PigmentDev rClone job now.") }

    @Parameter(title: "Job") var job: JobEntity
    @Parameter(title: "Dry run", default: false) var dryRun: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await MainActor.run { AppEnvironment.shared.model }
        await model.run(job.id, dryRun: dryRun)
        return .result(dialog: "Started \(job.name).")
    }
}

struct PauseAllIntent: AppIntent {
    static var title: LocalizedStringResource { "Pause All Syncing" }
    static var description: IntentDescription { IntentDescription("Pauses every PigmentDev rClone job.") }

    @Parameter(title: "Minutes (empty = until resumed)") var minutes: Int?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await MainActor.run { AppEnvironment.shared.model }
        if let minutes, minutes > 0 {
            if let client = await model.client { try await client.send("jobs.pauseAll", PauseAllParams(untilSec: minutes * 60)) }
            await model.refreshJobs()
        } else {
            await model.pauseAll(.untilResumed)
        }
        return .result(dialog: "Syncing paused.")
    }
}

struct ResumeAllIntent: AppIntent {
    static var title: LocalizedStringResource { "Resume All Syncing" }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await MainActor.run { AppEnvironment.shared.model }
        await model.resumeAll()
        return .result(dialog: "Syncing resumed.")
    }
}

struct JobStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Sync Status" }
    @Parameter(title: "Job") var job: JobEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text: String = await MainActor.run {
            let model = AppEnvironment.shared.model
            if let job, let j = model.job(job.id) {
                let l = (j.status ?? JobStatus()).label
                return "\(j.name): \(l.title)" + (l.detail.map { " — \($0)" } ?? "")
            }
            return OverallStatusText().text
        }
        return .result(value: text, dialog: "\(text)")
    }
}

struct PDRCloneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunJobIntent(), phrases: ["Run \(\.$job) in \(.applicationName)", "Sync \(\.$job) with \(.applicationName)"],
                    shortTitle: "Run Job", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: PauseAllIntent(), phrases: ["Pause \(.applicationName)", "Pause syncing in \(.applicationName)"],
                    shortTitle: "Pause All", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAllIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume All", systemImageName: "play.circle")
        AppShortcut(intent: JobStatusIntent(), phrases: ["\(.applicationName) status"], shortTitle: "Status", systemImageName: "info.circle")
    }
}
