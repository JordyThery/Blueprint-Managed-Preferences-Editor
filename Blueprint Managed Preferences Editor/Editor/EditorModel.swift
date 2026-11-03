import AppKit
import Foundation
import JTKit
import Observation

/// What the detail column shows for a blueprint.
enum EditorSelection: Hashable {
    case domain(PreferenceDomain.ID)
    case rawJSON
}

/// Editing state for one blueprint: the document, undo/redo, and the
/// save / deploy / restore workflows.
@Observable
final class EditorModel {
    enum Operation: Equatable {
        case idle
        case saving
        case deploying
        case restoring
        case reloading

        var label: String {
            switch self {
            case .idle: ""
            case .saving: "Saving…"
            case .deploying: "Deploying…"
            case .restoring: "Restoring…"
            case .reloading: "Reloading…"
            }
        }

        /// "the save", for "Wait for the save to finish".
        var noun: String {
            switch self {
            case .idle: "the operation"
            case .saving: "the Save"
            case .deploying: "the Deploy"
            case .restoring: "the Restore"
            case .reloading: "the Reload"
            }
        }

        /// "saved", for "is still being saved".
        var pastParticiple: String {
            switch self {
            case .idle: "changed"
            case .saving: "saved"
            case .deploying: "deployed"
            case .restoring: "restored"
            case .reloading: "reloaded"
            }
        }
    }

    /// A menu bar command for the window to carry out: the window holds the
    /// sheets and confirmations, the menu only asks (`request`).
    enum Request: Equatable {
        case review
        case saveAndDeploy
        case deploy
        case restore
        case newDomain
        case renameDomain
        case removeDomain
        case importDomains
        case exportDomain
    }

    /// A result shown in the window, not in an alert: "“…” was saved." It
    /// stays until the next edit or operation.
    struct Status: Equatable {
        let title: String
        let message: String

        /// Something was done (Saved, Imported), not only reported (Stopped, Nothing Imported).
        var isDone: Bool { !title.contains("Stopped") && !title.hasPrefix("Nothing") }
    }

    struct Alert {
        enum Kind {
            case info
            case error
            /// The Blueprint changed on the server since it was loaded.
            case conflict
        }

        let kind: Kind
        let title: String
        let message: String
    }

    let blueprintID: String
    private(set) var document: BlueprintEditDocument
    private(set) var isDirty = false
    private(set) var operation: Operation = .idle
    var selection: EditorSelection?
    /// The selected entry per domain, for domains with several mode entries.
    var selectedEntryIDs: [PreferenceDomain.ID: MCXEntry.ID] = [:]
    var alert: Alert?
    /// The last result, shown in the editor's status line.
    var status: Status?
    /// Set by the menu bar; the window carries it out and clears it.
    var request: Request?

    /// This editor's waits before a retry, with its own client: Stop in its
    /// status line ends only its own wait.
    let waits = RequestWaits()
    /// The connection change count when this editor was made. Editors are
    /// dropped on every change, so an operation that finds another count
    /// after building its client would reach another tenant.
    private let generation: Int

    /// The window's undo manager, set by the views.
    weak var undoManager: UndoManager?
    @ObservationIgnored private unowned let app: AppModel

    init(detail: JamfPlatform.BlueprintDetail, app: AppModel) {
        blueprintID = detail.id
        document = BlueprintEditDocument(detail: detail)
        self.app = app
        generation = app.connectionGeneration
    }

    var base: JamfPlatform.BlueprintDetail { document.base }
    var isReadOnly: Bool { app.isReadOnly(blueprintID) }
    /// The backup folder in use: the demo's temporary one in demo mode.
    var backupRoot: URL { app.backupRoot }
    var isBusy: Bool { operation != .idle }
    var canEdit: Bool { !isReadOnly && !isBusy }
    /// Deploy… needs the edits saved first (a deploy reloads the Blueprint,
    /// which would discard them) and, like Save, a Blueprint not assigned to
    /// a division.
    var canDeploy: Bool { canEdit && !isDirty }

    // MARK: Undoable mutations

    /// Clears this editor's undo registrations. Must be called before the editor is
    /// discarded: NSUndoManager does not retain or clear closure targets, so stale
    /// actions would otherwise call into a deallocated editor.
    func detachUndoHistory() {
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    /// Applies a change to the payloads as one undoable action.
    /// Returns false when nothing changed and no action was registered.
    @discardableResult
    private func perform(_ actionName: String, _ change: (inout BlueprintEditDocument) -> Void) -> Bool {
        guard canEdit else { return false }
        status = nil
        var updated = document
        change(&updated)
        guard updated.payloads != document.payloads else { return false }
        let previous = document.payloads
        document.payloads = updated.payloads
        registerUndo(restoring: previous, actionName: actionName)
        recomputeDirty()
        return true
    }

    private func registerUndo(restoring payloads: [ManagedPreferencesPayload], actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restorePayloads(payloads, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restorePayloads(_ payloads: [ManagedPreferencesPayload], actionName: String) {
        let current = document.payloads
        document.payloads = payloads
        registerUndo(restoring: current, actionName: actionName)
        recomputeDirty()
        // Show the Blueprint being undone, and drop a selection that no longer exists.
        app.selectedBlueprintID = blueprintID
        if case .domain(let id) = selection, document.domain(withID: id) == nil {
            selection = nil
        }
    }

    private func recomputeDirty() {
        isDirty = document.hasChanges
    }

    /// Replaces the baseline with a freshly loaded detail, discarding edits and undo history.
    func reset(to detail: JamfPlatform.BlueprintDetail) {
        let selectedName: String? = {
            if case .domain(let id) = selection { return document.domain(withID: id)?.name }
            return nil
        }()
        undoManager?.removeAllActions(withTarget: self)
        document = BlueprintEditDocument(detail: detail)
        selectedEntryIDs = [:]
        isDirty = false
        // Keep the same domain selected by name, if it still exists.
        if let selectedName {
            let match = document.payloads.flatMap(\.domains).first { $0.name == selectedName }
            selection = match.map { .domain($0.id) }
        } else if selection != .rawJSON {
            selection = nil
        }
    }

    /// Back to the newest copy read from the server: the editor's baseline, or
    /// the app's copy when a Refresh read the Blueprint since.
    func discardChanges() {
        let stored = app.details[blueprintID]
        reset(to: stored.map { $0.fetchedAt > base.fetchedAt ? $0 : base } ?? base)
    }

    // MARK: Domains

    func domain(withID id: PreferenceDomain.ID) -> PreferenceDomain? {
        document.domain(withID: id)
    }

    /// The entry being edited for a domain: the selected one, or the first.
    func currentEntry(of domain: PreferenceDomain) -> MCXEntry? {
        guard let entries = domain.entries else { return nil }
        if let id = selectedEntryIDs[domain.id], let entry = entries.first(where: { $0.id == id }) { return entry }
        return entries.first
    }

    /// Whether a domain's settings can be edited now: the editor allows edits
    /// and the payload holding the domain has the expected shape.
    func canEdit(domainID: PreferenceDomain.ID) -> Bool {
        guard canEdit, let index = document.payloadIndex(containing: domainID) else { return false }
        return document.payloads[index].isEditable
    }

    /// The payload New Domain and Import add to: the editable payload holding
    /// `nearDomainID`, or else the first editable payload.
    func targetPayloadIndex(near nearDomainID: PreferenceDomain.ID?) -> Int? {
        if let nearDomainID, let index = document.payloadIndex(containing: nearDomainID),
           document.payloads[index].isEditable {
            return index
        }
        return document.payloads.firstIndex(where: \.isEditable)
    }

    /// Checks a name for a renamed domain (`renaming`) or a new one added near
    /// `nearDomainID`: one payload may not hold two domains with the same name.
    func validateDomainName(_ name: String, renaming domainID: PreferenceDomain.ID?, near nearDomainID: PreferenceDomain.ID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The domain name can’t be empty." }
        let index = domainID.flatMap(document.payloadIndex(containing:)) ?? targetPayloadIndex(near: nearDomainID)
        guard let index else { return nil }
        let clash = document.payloads[index].domains.contains { $0.name == trimmed && $0.id != domainID }
        return clash ? "A domain named “\(trimmed)” already exists in this payload." : nil
    }

    /// Adds a domain to the payload containing `nearDomainID`, or the first
    /// editable payload. Nil when the name is empty or already used there.
    @discardableResult
    func addDomain(name: String, mode: String = ManagementMode.forced, settings: [PlistNode] = [], near nearDomainID: PreferenceDomain.ID? = nil) -> PreferenceDomain.ID? {
        guard validateDomainName(name, renaming: nil, near: nearDomainID) == nil,
              let payloadIndex = targetPayloadIndex(near: nearDomainID) else { return nil }
        let domain = PreferenceDomain.new(name: name.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode, settings: settings)
        guard perform("Add Domain", { document in
            document.payloads[payloadIndex].domains.append(domain)
        }) else { return nil }
        selection = .domain(domain.id)
        return domain.id
    }

    func renameDomain(_ id: PreferenceDomain.ID, to name: String) {
        guard validateDomainName(name, renaming: id) == nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Rename Domain") { document in
            document.modifyDomain(withID: id) { $0.name = trimmed }
        }
    }

    func removeDomain(_ id: PreferenceDomain.ID) {
        perform("Remove Domain") { document in
            for index in document.payloads.indices where document.payloads[index].isEditable {
                document.payloads[index].domains.removeAll { $0.id == id }
            }
        }
        if selection == .domain(id) { selection = nil }
    }

    func setMode(_ mode: String, domainID: PreferenceDomain.ID, entryID: MCXEntry.ID) {
        perform("Change Management Mode") { document in
            document.modifyDomain(withID: domainID) { domain in
                guard case .entries(var entries) = domain.content,
                      let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
                entries[index].mode = mode
                domain.content = .entries(entries)
            }
        }
    }

    /// What an import did.
    struct ImportResult: Equatable {
        var added = 0
        var replaced = 0
        /// Domains that exist with an unexpected shape: read-only, so left as they are.
        var skipped: [String] = []

        /// The alert after importing `fileName`.
        func summary(fileName: String) -> (title: String, message: String) {
            var sentences: [String] = []
            let changed = added > 0 || replaced > 0
            if changed {
                let parts = [added > 0 ? "\(counted(added, "domain")) added" : nil,
                             replaced > 0 ? "\(counted(replaced, "domain")) updated" : nil].compactMap(\.self)
                sentences.append("Imported from \(fileName): \(parts.joined(separator: ", ")).")
            } else if skipped.isEmpty {
                sentences.append("\(fileName) matches the current settings; nothing changed.")
            }
            if !skipped.isEmpty {
                let names = skipped.map { "“\($0)”" }.joined(separator: ", ")
                sentences.append("\(names) \(skipped.count == 1 ? "has" : "have") an unexpected shape and \(skipped.count == 1 ? "is" : "are") read-only, so \(skipped.count == 1 ? "it was" : "they were") left as \(skipped.count == 1 ? "it is" : "they are").")
            }
            if changed { sentences.append("Use Undo to revert.") }
            return (changed ? "Imported" : "Nothing Imported", sentences.joined(separator: " "))
        }
    }

    /// Imports domains into the payload containing `nearDomainID` (or the first
    /// editable payload). An existing domain gets the settings of its entry
    /// with the same mode replaced, or a new entry for a mode it doesn’t have
    /// yet; new domains are added. Domains with an unexpected shape are
    /// skipped. One undo step.
    @discardableResult
    func importDomains(_ imported: [ImportedDomain], near nearDomainID: PreferenceDomain.ID?) -> ImportResult {
        guard let payloadIndex = targetPayloadIndex(near: nearDomainID) else { return ImportResult() }
        var result = ImportResult()
        let applied = perform("Import") { document in
            for domain in imported {
                let domains = document.payloads[payloadIndex].domains
                guard let index = domains.firstIndex(where: { $0.name == domain.name }) else {
                    document.payloads[payloadIndex].domains.append(
                        .new(name: domain.name, mode: domain.mode, settings: domain.settings)
                    )
                    result.added += 1
                    continue
                }
                guard case .entries(var entries) = domains[index].content else {
                    if !result.skipped.contains(domain.name) { result.skipped.append(domain.name) }
                    continue
                }
                if let entryIndex = entries.firstIndex(where: { $0.mode == domain.mode }) {
                    entries[entryIndex].settings = domain.settings
                } else {
                    entries.append(MCXEntry(mode: domain.mode, settings: domain.settings))
                }
                document.payloads[payloadIndex].domains[index].content = .entries(entries)
                result.replaced += 1
            }
        }
        return applied ? result : ImportResult(skipped: result.skipped)
    }

    // MARK: Key/value tree

    /// Returns false when nothing changed and no undo action was registered.
    @discardableResult
    func modifySettings(_ actionName: String, domainID: PreferenceDomain.ID, entryID: MCXEntry.ID, _ body: (inout [PlistNode]) -> Void) -> Bool {
        perform(actionName) { document in
            document.modifySettings(domainID: domainID, entryID: entryID, body)
        }
    }

    // MARK: Save / deploy / restore

    /// Save pipeline: re-GET and compare the steps and `updated` (Save sends
    /// only the steps, so the scope may differ), back up, PATCH the complete
    /// steps array, reload. Optionally deploys afterwards, which compares
    /// the scope too. Each step that fails after the save says that the
    /// save itself went through.
    func save(andDeploy deploy: Bool) async {
        guard isDirty, !isReadOnly, !isBusy else { return }
        let snapshot = document
        let name = snapshot.base.overview.name
        begin(.saving)
        defer { operation = .idle }
        let service: JamfPlatform.Blueprints
        var sent = false
        do {
            service = try currentService(for: .save)
            // Decided now, for the connection in use: a later connection or
            // Demo Mode change can't move the backup.
            let backupRoot = app.backupRoot

            // 1. Optimistic concurrency.
            let latest = try await service.detail(id: blueprintID)
            if let change = Self.serverChange(from: snapshot.base, to: latest, comparingScope: false) {
                report(conflictAlert(latest: latest, change: change, outcome: "Nothing was changed."), generation)
                return
            }

            // 2. Backup of the full detail as it is on the server right now.
            try BackupStore.write(latest, root: backupRoot)

            // 3. PATCH the complete steps array.
            guard let steps = snapshot.updatedSteps else {
                throw JamfPlatform.APIError(.invalidResponse("The Blueprint has no steps array to update."))
            }
            sent = true
            try await service.patchSteps(id: blueprintID, steps: steps)
        } catch {
            handle(error, action: .save, mayHaveReachedJamf: sent, generation)
            return
        }

        // 4. Reload the new baseline. If that fails, what was sent becomes the
        // baseline, so the saved edits don't look unsaved.
        if let problem = await reloadAfterWrite(service: service, generation: generation) {
            markSaved(snapshot)
            let skipped = deploy ? ", so it wasn’t deployed" : ""
            report(Alert(kind: .error, title: "Saved, Not Reloaded",
                         message: "“\(name)” was saved, but \(problem.sentence)\(skipped). Reload before editing again.\(problem.detail)"),
                   generation)
            return
        }

        guard deploy else {
            report(Alert(kind: .info, title: "Saved", message: "“\(name)” was saved. It shows as Out of Date until you deploy it."), generation)
            return
        }

        // 5. Deploy what was just saved and checked.
        operation = .deploying
        switch await startDeployment(service: service, confirmed: base, generation: generation) {
        case .started:
            break
        case .notStarted(let alert):
            report(Alert(kind: alert.kind, title: "Saved, Not Deployed",
                         message: "“\(name)” was saved, but it wasn’t deployed. \(alert.message)"),
                   generation)
            return
        case .failed(let message):
            report(Alert(kind: .error, title: "Saved, Deploy Failed",
                         message: "“\(name)” was saved, but its deployment couldn’t be started. \(message)"),
                   generation)
            return
        }
        if let problem = await reloadAfterWrite(service: service, generation: generation) {
            report(Alert(kind: .error, title: "Saved and Deployed, Not Reloaded",
                         message: "“\(name)” was saved and its deployment has started, but \(problem.sentence). Reload before editing again.\(problem.detail)"),
                   generation)
            return
        }
        report(Alert(kind: .info, title: "Saved and Deployment Started", message: "“\(name)” was saved and its deployment has started."), generation)
    }

    /// Deploys the saved Blueprint. Only without unsaved edits and not on a
    /// read-only Blueprint (see `canDeploy`). JTKit reads it again just
    /// before the deploy: the confirmation showed the scope of the copy
    /// loaded earlier, so a Blueprint whose steps or scope changed on the
    /// server since is not deployed.
    func deploy() async {
        guard canDeploy else { return }
        let name = base.overview.name
        begin(.deploying)
        defer { operation = .idle }
        let service: JamfPlatform.Blueprints
        do {
            service = try currentService(for: .deploy)
        } catch {
            handle(error, action: .deploy, mayHaveReachedJamf: false, generation)
            return
        }
        switch await startDeployment(service: service, confirmed: base, generation: generation) {
        case .started:
            break
        case .notStarted(let alert):
            report(alert, generation)
            return
        case .failed(let message):
            report(Alert(kind: .error, title: "Deploy Failed", message: message), generation)
            return
        }
        if let problem = await reloadAfterWrite(service: service, generation: generation) {
            report(Alert(kind: .error, title: "Deployed, Not Reloaded",
                         message: "The deployment of “\(name)” has started, but \(problem.sentence). Reload before editing again.\(problem.detail)"),
                   generation)
            return
        }
        report(Alert(kind: .info, title: "Deployment Started", message: "The deployment of “\(name)” has started."), generation)
    }

    /// How a deploy request went.
    private enum DeployOutcome {
        case started
        /// Nothing was sent, or Jamf refused it: the alert says why.
        case notStarted(Alert)
        /// The deploy request failed; the message says whether it may have started.
        case failed(String)
    }

    /// The Blueprint changed on the server since the user confirmed it.
    private struct ChangedOnServer: Error {
        let latest: JamfPlatform.BlueprintDetail
    }

    /// JTKit's `startDeployment(id:check:)`: reads the Blueprint, deploys it
    /// only when its steps and scope are still those of `confirmed`.
    private func startDeployment(service: JamfPlatform.Blueprints, confirmed: JamfPlatform.BlueprintDetail,
                                 generation: Int) async -> DeployOutcome {
        do {
            _ = try await service.startDeployment(id: blueprintID) { latest in
                guard confirmed.isUnchangedInStepsAndScope(in: latest) else { throw ChangedOnServer(latest: latest) }
            }
            return .started
        } catch let notStarted as JamfPlatform.Blueprints.DeploymentNotStarted {
            // Nothing was sent, so nothing started.
            if let changed = notStarted.underlying as? ChangedOnServer {
                let change = Self.serverChange(from: confirmed, to: changed.latest, comparingScope: true)
                    ?? "It was changed"
                return .notStarted(conflictAlert(latest: changed.latest, change: change,
                                                 outcome: "Nothing was deployed. Reload to see its current settings and scope."))
            }
            if notStarted.underlying is CancellationError {
                return .notStarted(Alert(kind: .info, title: "Deploy Stopped",
                                         message: "You stopped waiting for Jamf, so nothing was deployed."))
            }
            return .notStarted(Alert(kind: .error, title: "Deploy Failed",
                                     message: "Nothing was deployed.\n\n\(notStarted.underlying.localizedDescription)"))
        } catch is CancellationError {
            return .failed("You stopped waiting for Jamf. The deployment may have started anyway: reload to see its state.")
        } catch let error as JamfPlatform.APIError where error.divisionLockMessage != nil {
            // Refused for a division, as Save would be: read-only from now on.
            if app.connectionGeneration == generation { app.readOnlyBlueprintIDs.insert(blueprintID) }
            return .notStarted(Alert(kind: .error, title: "Blueprint Is Read-Only", message: error.localizedDescription))
        } catch {
            let refused = (error as? JamfPlatform.APIError)?.status.map { (400..<500).contains($0) } ?? false
            let maybe = refused ? "" : " It may have started anyway: reload to see its state."
            return .failed("Use Deploy… to try again.\(maybe)\n\n\(error.localizedDescription)")
        }
    }

    /// PATCHes the steps from a backup, after the same check as Save (steps
    /// and `updated`) and a fresh backup.
    func restore(from backup: BlueprintBackup) async {
        guard !isReadOnly, !isBusy else { return }
        let name = base.overview.name
        begin(.restoring)
        defer { operation = .idle }
        let service: JamfPlatform.Blueprints
        var sent = false
        do {
            let backupDetail = try BackupStore.load(backup)
            guard let steps = backupDetail.steps, steps.arrayValue != nil else {
                throw BackupStore.BackupError(message: "The backup has no steps array.")
            }
            service = try currentService(for: .restore)
            // Decided now, for the connection in use (see Save).
            let backupRoot = app.backupRoot
            let latest = try await service.detail(id: blueprintID)
            if let change = Self.serverChange(from: base, to: latest, comparingScope: false) {
                report(conflictAlert(latest: latest, change: change, outcome: "Nothing was changed."), generation)
                return
            }
            try BackupStore.write(latest, root: backupRoot)
            sent = true
            try await service.patchSteps(id: blueprintID, steps: steps)
        } catch {
            handle(error, action: .restore, mayHaveReachedJamf: sent, generation)
            return
        }
        let date = backup.date.formatted(date: .abbreviated, time: .standard)
        if let problem = await reloadAfterWrite(service: service, generation: generation) {
            report(Alert(kind: .error, title: "Restored, Not Reloaded",
                         message: "The steps from the backup of \(date) were restored to “\(name)”, but \(problem.sentence). Reload before editing again.\(problem.detail)"),
                   generation)
            return
        }
        report(Alert(kind: .info, title: "Restored", message: "The steps from the backup of \(date) were restored to “\(name)”. Deploy to apply them to devices."), generation)
    }

    /// Re-fetches the Blueprint. With unsaved edits only when
    /// `discardingEdits` (the user confirmed losing them).
    func reload(discardingEdits: Bool = false) async {
        guard !isBusy, !isDirty || discardingEdits else { return }
        begin(.reloading)
        defer { operation = .idle }
        do {
            let fresh = try await currentService(for: .reload).detail(id: blueprintID)
            guard app.connectionGeneration == generation else { return }
            app.store(fresh)
            reset(to: fresh)
        } catch {
            handle(error, action: .reload, mayHaveReachedJamf: false, generation)
        }
    }

    /// The connection changed (a change waiting to be applied, applied while
    /// the client was built), so the client is for another tenant than this
    /// editor's Blueprint.
    private struct ConnectionChanged: Error {}

    /// This editor's client, checked to be for the tenant the Blueprint was
    /// loaded from: building it applies a waiting connection change.
    /// - Throws: `ConnectionChanged` when that happened; nothing is sent then.
    private func currentService(for action: Action) throws -> JamfPlatform.Blueprints {
        let service = try app.currentService(waits: waits)
        guard app.connectionGeneration == generation else { throw ConnectionChanged() }
        return service
    }

    private func begin(_ operation: Operation) {
        status = nil
        self.operation = operation
    }

    /// Why a reload after a write didn't happen, for "“…” was saved, but …".
    private struct ReloadProblem {
        /// "you stopped waiting for Jamf before it was reloaded"
        let sentence: String
        /// The error, after a blank line; empty after Stop.
        let detail: String
    }

    /// Reloads after a successful write. Returns why it didn't, or nil.
    /// Nothing reaches the app's state once the connection changed meanwhile.
    private func reloadAfterWrite(service: JamfPlatform.Blueprints, generation: Int) async -> ReloadProblem? {
        do {
            let fresh = try await service.detail(id: blueprintID)
            if app.connectionGeneration == generation { app.store(fresh) }
            reset(to: fresh)
            return nil
        } catch is CancellationError {
            return ReloadProblem(sentence: "you stopped waiting for Jamf before it was reloaded", detail: "")
        } catch {
            return ReloadProblem(sentence: "reloading it failed", detail: "\n\n\(error.localizedDescription)")
        }
    }

    /// After a save whose reload failed: what was sent becomes the baseline.
    /// Its `updated` time is still the old one, so the next save or deploy
    /// finds the Blueprint changed and asks for a reload.
    private func markSaved(_ snapshot: BlueprintEditDocument) {
        let sent = snapshot.updatedBlueprintJSON.serialized()
        guard let saved = try? JamfPlatform.BlueprintDetail(data: sent) else { return }
        reset(to: saved)
    }

    /// What changed on the server between `loaded` and `latest`, as a
    /// sentence, or nil when nothing that matters did: the steps compared in
    /// full and the `updated` time (when both copies have one), and for a
    /// deploy the scope too. Save and Restore send only the steps, so a
    /// scope changed by someone else doesn't stop them.
    static func serverChange(from loaded: JamfPlatform.BlueprintDetail, to latest: JamfPlatform.BlueprintDetail,
                             comparingScope: Bool) -> String? {
        guard loaded.overview.id == latest.overview.id else { return "It is another Blueprint" }
        if (loaded.steps ?? .null) != (latest.steps ?? .null) {
            return "Its steps (its payloads and other settings) were changed"
        }
        if comparingScope, (loaded.scope ?? .null) != (latest.scope ?? .null) {
            return "Its scope was changed"
        }
        if let updated = loaded.overview.updated, let latestUpdated = latest.overview.updated, updated != latestUpdated {
            func time(_ overview: JamfPlatform.BlueprintOverview, _ raw: String) -> String {
                overview.updatedDate?.formatted(date: .abbreviated, time: .standard) ?? raw
            }
            return "It was updated at \(time(latest.overview, latestUpdated)); you loaded the version of \(time(loaded.overview, updated))"
        }
        return nil
    }

    private func conflictAlert(latest: JamfPlatform.BlueprintDetail, change: String, outcome: String) -> Alert {
        let edits = isDirty ? "; unsaved edits will be lost" : ""
        return Alert(
            kind: .conflict,
            title: "Blueprint Changed on the Server",
            message: "“\(latest.overview.name)” was changed on the server after you loaded it. \(change). \(outcome) Reload to get the latest version\(edits)."
        )
    }

    /// Shows a result on this editor: an info result in the window's status
    /// line (and read out by VoiceOver), anything else as an alert; or, when
    /// the connection changed while the operation ran (or the editor was
    /// closed), in the main window.
    private func report(_ alert: Alert, _ generation: Int) {
        if app.connectionGeneration == generation, app.editors[blueprintID] === self {
            if alert.kind == .info {
                show(Status(title: alert.title, message: alert.message))
            } else {
                self.alert = alert
            }
        } else {
            app.notice = Alert(
                kind: alert.kind == .info ? .info : .error,
                title: alert.title,
                message: alert.message + "\n\nThis was on the connection in use before the connection changed."
            )
        }
    }

    /// Shows a result in the status line and asks VoiceOver to read it.
    func show(_ status: Status) {
        self.status = status
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: status.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// What an operation is called in its messages.
    private enum Action: String {
        case save = "Save"
        case deploy = "Deploy"
        case restore = "Restore"
        case reload = "Reload"

        /// "saved"
        var pastParticiple: String {
            switch self {
            case .save: "saved"
            case .deploy: "deployed"
            case .restore: "restored"
            case .reload: "reloaded"
            }
        }

        /// "nothing was saved"
        var nothingDone: String {
            switch self {
            case .save: "nothing was saved"
            case .deploy: "nothing was deployed"
            case .restore: "nothing was restored"
            case .reload: "nothing was reloaded"
            }
        }
    }

    /// - Parameter mayHaveReachedJamf: the write request was being sent, so
    ///   a stopped wait doesn't tell whether Jamf has the change.
    private func handle(_ error: Error, action: Action, mayHaveReachedJamf: Bool, _ generation: Int) {
        if error is ConnectionChanged {
            report(Alert(kind: .info, title: "\(action.rawValue) Not Started",
                         message: "The connection changed before “\(base.overview.name)” could be \(action.pastParticiple), so \(action.nothingDone) and nothing was read from the new connection."),
                   generation)
            return
        }
        // Stop during a wait before a retry (RequestWaits): say what that left.
        if error is CancellationError {
            let message = mayHaveReachedJamf
                ? "You stopped waiting for Jamf. The change may have reached Jamf anyway: reload “\(base.overview.name)” to see what it has."
                : "You stopped waiting for Jamf, so \(action.nothingDone)."
            report(Alert(kind: mayHaveReachedJamf ? .error : .info, title: "\(action.rawValue) Stopped", message: message), generation)
            return
        }
        // JTKit's message ends with the hint that the Blueprint is assigned to a division.
        if let platformError = error as? JamfPlatform.APIError, platformError.divisionLockMessage != nil {
            if app.connectionGeneration == generation { app.readOnlyBlueprintIDs.insert(blueprintID) }
            report(Alert(kind: .error, title: "Blueprint Is Read-Only", message: platformError.localizedDescription), generation)
            return
        }
        report(Alert(kind: .error, title: "\(action.rawValue) Failed", message: error.localizedDescription), generation)
    }
}
