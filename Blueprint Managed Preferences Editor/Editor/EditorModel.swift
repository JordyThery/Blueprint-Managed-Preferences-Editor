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

    /// The window's undo manager, set by the views.
    weak var undoManager: UndoManager?
    @ObservationIgnored private unowned let app: AppModel

    init(detail: JamfPlatform.BlueprintDetail, app: AppModel) {
        blueprintID = detail.id
        document = BlueprintEditDocument(detail: detail)
        self.app = app
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

    /// Save pipeline: re-GET and compare `updated`, back up, PATCH the complete
    /// steps array, reload. Optionally deploys afterwards. Each step that
    /// fails after the save says that the save itself went through.
    func save(andDeploy deploy: Bool) async {
        guard isDirty, !isReadOnly, !isBusy else { return }
        let snapshot = document
        let name = snapshot.base.overview.name
        let generation = app.connectionGeneration
        operation = .saving
        defer { operation = .idle }
        let service: JamfPlatform.Blueprints
        do {
            service = try app.currentService()

            // 1. Optimistic concurrency.
            let latest = try await service.detail(id: blueprintID)
            guard snapshot.base.isUnchanged(in: latest) else {
                report(conflictAlert(latest: latest, outcome: "Nothing was changed."), generation)
                return
            }

            // 2. Backup of the full detail as it is on the server right now.
            try BackupStore.write(latest, root: app.backupRoot)

            // 3. PATCH the complete steps array.
            guard let steps = snapshot.updatedSteps else {
                throw JamfPlatform.APIError(.invalidResponse("The Blueprint has no steps array to update."))
            }
            try await service.patchSteps(id: blueprintID, steps: steps)
        } catch {
            handle(error, action: "Save", generation)
            return
        }

        // 4. Reload the new baseline. If that fails, what was sent becomes the
        // baseline, so the saved edits don't look unsaved.
        if let error = await reloadAfterWrite(service: service, generation: generation) {
            markSaved(snapshot)
            let skipped = deploy ? ", so it wasn’t deployed" : ""
            report(Alert(kind: .error, title: "Saved, Reload Failed",
                         message: "“\(name)” was saved, but reloading it failed\(skipped). Reload before editing again.\n\n\(error.localizedDescription)"),
                   generation)
            return
        }

        guard deploy else {
            report(Alert(kind: .info, title: "Saved", message: "“\(name)” was saved. It shows as Out of Date until you deploy it."), generation)
            return
        }

        // 5. Deploy what was just saved and checked.
        operation = .deploying
        do {
            try await service.deploy(id: blueprintID)
        } catch {
            if error is CancellationError { return }
            report(Alert(kind: .error, title: "Saved, Deploy Failed",
                         message: "“\(name)” was saved, but its deployment couldn’t be started. Use Deploy… to try again.\n\n\(error.localizedDescription)"),
                   generation)
            return
        }
        if let error = await reloadAfterWrite(service: service, generation: generation) {
            report(Alert(kind: .error, title: "Reload Failed",
                         message: "“\(name)” was saved and its deployment has started, but reloading it failed. Reload before editing again.\n\n\(error.localizedDescription)"),
                   generation)
            return
        }
        report(Alert(kind: .info, title: "Saved and Deployment Started", message: "“\(name)” was saved and its deployment has started."), generation)
    }

    /// Deploys the saved Blueprint. Only without unsaved edits and not on a
    /// read-only Blueprint (see `canDeploy`). Reads it again first: the
    /// confirmation showed the scope of the copy loaded earlier, so a
    /// Blueprint changed on the server since is not deployed.
    func deploy() async {
        guard canDeploy else { return }
        let name = base.overview.name
        let generation = app.connectionGeneration
        operation = .deploying
        defer { operation = .idle }
        let service: JamfPlatform.Blueprints
        do {
            service = try app.currentService()
            let latest = try await service.detail(id: blueprintID)
            guard base.isUnchanged(in: latest) else {
                report(conflictAlert(latest: latest, outcome: "Nothing was deployed. Reload to see its current settings and scope."), generation)
                return
            }
            try await service.deploy(id: blueprintID)
        } catch {
            handle(error, action: "Deploy", generation)
            return
        }
        if let error = await reloadAfterWrite(service: service, generation: generation) {
            report(Alert(kind: .error, title: "Reload Failed",
                         message: "The deployment of “\(name)” has started, but reloading it failed. Reload before editing again.\n\n\(error.localizedDescription)"),
                   generation)
            return
        }
        report(Alert(kind: .info, title: "Deployment Started", message: "The deployment of “\(name)” has started."), generation)
    }

    /// PATCHes the steps from a backup, after the same concurrency check and a fresh backup.
    func restore(from backup: BlueprintBackup) async {
        guard !isReadOnly, !isBusy else { return }
        let name = base.overview.name
        let generation = app.connectionGeneration
        operation = .restoring
        defer { operation = .idle }
        let service: JamfPlatform.Blueprints
        do {
            let backupDetail = try BackupStore.load(backup)
            guard let steps = backupDetail.steps, steps.arrayValue != nil else {
                throw BackupStore.BackupError(message: "The backup has no steps array.")
            }
            service = try app.currentService()
            let latest = try await service.detail(id: blueprintID)
            guard base.isUnchanged(in: latest) else {
                report(conflictAlert(latest: latest, outcome: "Nothing was changed."), generation)
                return
            }
            try BackupStore.write(latest, root: app.backupRoot)
            try await service.patchSteps(id: blueprintID, steps: steps)
        } catch {
            handle(error, action: "Restore", generation)
            return
        }
        let date = backup.date.formatted(date: .abbreviated, time: .standard)
        if let error = await reloadAfterWrite(service: service, generation: generation) {
            report(Alert(kind: .error, title: "Restored, Reload Failed",
                         message: "The steps from the backup of \(date) were restored to “\(name)”, but reloading it failed. Reload before editing again.\n\n\(error.localizedDescription)"),
                   generation)
            return
        }
        report(Alert(kind: .info, title: "Restored", message: "The steps from the backup of \(date) were restored. Deploy to apply them to devices."), generation)
    }

    /// Re-fetches the Blueprint. With unsaved edits only when
    /// `discardingEdits` (the user confirmed losing them).
    func reload(discardingEdits: Bool = false) async {
        guard !isBusy, !isDirty || discardingEdits else { return }
        let generation = app.connectionGeneration
        operation = .reloading
        defer { operation = .idle }
        do {
            let fresh = try await app.currentService().detail(id: blueprintID)
            guard app.connectionGeneration == generation else { return }
            app.store(fresh)
            reset(to: fresh)
        } catch {
            handle(error, action: "Reload", generation)
        }
    }

    /// Reloads after a successful write. Returns the error if the reload failed.
    /// Nothing reaches the app's state once the connection changed meanwhile.
    private func reloadAfterWrite(service: JamfPlatform.Blueprints, generation: Int) async -> Error? {
        do {
            let fresh = try await service.detail(id: blueprintID)
            if app.connectionGeneration == generation { app.store(fresh) }
            reset(to: fresh)
            return nil
        } catch {
            return error
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

    private func conflictAlert(latest: JamfPlatform.BlueprintDetail, outcome: String) -> Alert {
        func time(_ overview: JamfPlatform.BlueprintOverview) -> String {
            overview.updatedDate?.formatted(date: .abbreviated, time: .standard) ?? overview.updated ?? "unknown"
        }
        let edits = isDirty ? "; unsaved edits will be lost" : ""
        return Alert(
            kind: .conflict,
            title: "Blueprint Changed on the Server",
            message: "“\(latest.overview.name)” was modified after you loaded it (loaded: \(time(base.overview)), now: \(time(latest.overview))). \(outcome) Reload to get the latest version\(edits)."
        )
    }

    /// Shows `alert` on this editor, or, when the connection changed while the
    /// operation ran (or the editor was closed), in the main window.
    private func report(_ alert: Alert, _ generation: Int) {
        if app.connectionGeneration == generation, app.editors[blueprintID] === self {
            self.alert = alert
        } else {
            app.notice = Alert(
                kind: alert.kind == .info ? .info : .error,
                title: alert.title,
                message: alert.message + "\n\nThis was on the connection in use before the connection changed."
            )
        }
    }

    private func handle(_ error: Error, action: String, _ generation: Int) {
        if error is CancellationError { return }
        // JTKit's message ends with the hint that the Blueprint is assigned to a division.
        if let platformError = error as? JamfPlatform.APIError, platformError.hasCode(.divisionPatchNotAllowed) {
            if app.connectionGeneration == generation { app.readOnlyBlueprintIDs.insert(blueprintID) }
            report(Alert(kind: .error, title: "Blueprint Is Read-Only", message: platformError.localizedDescription), generation)
            return
        }
        report(Alert(kind: .error, title: "\(action) Failed", message: error.localizedDescription), generation)
    }
}
