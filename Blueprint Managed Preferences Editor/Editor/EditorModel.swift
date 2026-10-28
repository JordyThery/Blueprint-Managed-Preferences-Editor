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
            /// The blueprint changed on the server since it was loaded.
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
        // Show the blueprint being undone, and drop a selection that no longer exists.
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

    func discardChanges() {
        reset(to: document.base)
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

    func validateDomainName(_ name: String, inPayloadOf domainID: PreferenceDomain.ID?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The domain name can't be empty." }
        guard let index = domainID.flatMap(document.payloadIndex(containing:)) else { return nil }
        let clash = document.payloads[index].domains.contains { $0.name == trimmed && $0.id != domainID }
        return clash ? "A domain named “\(trimmed)” already exists in this payload." : nil
    }

    /// Adds a domain to the payload containing `nearDomainID`, or the first editable payload.
    @discardableResult
    func addDomain(name: String, mode: String = ManagementMode.forced, settings: [PlistNode] = [], near nearDomainID: PreferenceDomain.ID? = nil) -> PreferenceDomain.ID? {
        guard let payloadIndex = nearDomainID.flatMap(document.payloadIndex(containing:))
                ?? document.payloads.firstIndex(where: \.isEditable) else { return nil }
        let domain = PreferenceDomain.new(name: name.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode, settings: settings)
        perform("Add Domain") { document in
            document.payloads[payloadIndex].domains.append(domain)
        }
        selection = .domain(domain.id)
        return domain.id
    }

    func renameDomain(_ id: PreferenceDomain.ID, to name: String) {
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

    /// Imports domains into the payload containing `nearDomainID` (or the first editable
    /// payload). Existing domains get the settings of the entry with the same mode (or
    /// their first entry) replaced; new domains are added. One undo step.
    @discardableResult
    func importDomains(_ imported: [ImportedDomain], near nearDomainID: PreferenceDomain.ID?) -> (added: Int, replaced: Int) {
        guard let payloadIndex = nearDomainID.flatMap(document.payloadIndex(containing:))
                ?? document.payloads.firstIndex(where: \.isEditable) else { return (0, 0) }
        var added = 0
        var replaced = 0
        let applied = perform("Import") { document in
            for domain in imported {
                if let index = document.payloads[payloadIndex].domains.firstIndex(where: { $0.name == domain.name }),
                   case .entries(var entries) = document.payloads[payloadIndex].domains[index].content {
                    let entryIndex = entries.firstIndex { $0.mode == domain.mode } ?? 0
                    entries[entryIndex].settings = domain.settings
                    document.payloads[payloadIndex].domains[index].content = .entries(entries)
                    replaced += 1
                } else {
                    document.payloads[payloadIndex].domains.append(
                        .new(name: domain.name, mode: domain.mode, settings: domain.settings)
                    )
                    added += 1
                }
            }
        }
        return applied ? (added, replaced) : (0, 0)
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
    /// steps array, reload. Optionally deploys afterwards.
    func save(andDeploy deploy: Bool) async {
        guard isDirty, !isReadOnly, !isBusy else { return }
        let snapshot = document
        operation = .saving
        // Tracks which step failed, so errors are reported under the right title.
        var action = "Save"
        defer { operation = .idle }
        do {
            let service = try app.currentService()

            // 1. Optimistic concurrency.
            let latest = try await service.detail(id: blueprintID)
            guard snapshot.base.isUnchanged(in: latest) else {
                alert = conflictAlert(latest: latest)
                return
            }

            // 2. Backup of the full detail as it is on the server right now.
            try BackupStore.write(latest, root: app.backupRoot)

            // 3. PATCH the complete steps array.
            guard let steps = snapshot.updatedSteps else {
                throw JamfPlatformError(.invalidResponse("The blueprint has no steps array to update."))
            }
            try await service.patchSteps(id: blueprintID, steps: steps)

            // 4. Reload the new baseline.
            guard await reloadAfterWrite(service: service) else { return }

            if deploy {
                operation = .deploying
                action = "Deploy"
                try await service.deploy(id: blueprintID)
                guard await reloadAfterWrite(service: service) else { return }
                alert = Alert(kind: .info, title: "Saved and Deployment Started", message: "“\(base.overview.name)” was saved and its deployment has started.")
            } else {
                alert = Alert(kind: .info, title: "Saved", message: "“\(base.overview.name)” was saved. It shows as Out of Date until you deploy it.")
            }
        } catch {
            handle(error, action: action)
        }
    }

    /// Deploys the saved blueprint. Only without unsaved edits and not on a
    /// read-only Blueprint (see `canDeploy`).
    func deploy() async {
        guard canDeploy else { return }
        operation = .deploying
        defer { operation = .idle }
        do {
            let service = try app.currentService()
            try await service.deploy(id: blueprintID)
            guard await reloadAfterWrite(service: service) else { return }
            alert = Alert(kind: .info, title: "Deployment Started", message: "Deployment of “\(base.overview.name)” has started.")
        } catch {
            handle(error, action: "Deploy")
        }
    }

    /// PATCHes the steps from a backup, after the same concurrency check and a fresh backup.
    func restore(from backup: BlueprintBackup) async {
        guard !isReadOnly, !isBusy else { return }
        operation = .restoring
        defer { operation = .idle }
        do {
            let backupDetail = try BackupStore.load(backup)
            guard let steps = backupDetail.steps, steps.arrayValue != nil else {
                throw BackupStore.BackupError(message: "The backup has no steps array.")
            }
            let service = try app.currentService()
            let latest = try await service.detail(id: blueprintID)
            guard base.isUnchanged(in: latest) else {
                alert = conflictAlert(latest: latest)
                return
            }
            try BackupStore.write(latest, root: app.backupRoot)
            try await service.patchSteps(id: blueprintID, steps: steps)
            guard await reloadAfterWrite(service: service) else { return }
            alert = Alert(kind: .info, title: "Restored", message: "The steps from the backup of \(backup.date.formatted(date: .abbreviated, time: .standard)) were restored. Deploy to apply them to devices.")
        } catch {
            handle(error, action: "Restore")
        }
    }

    /// Re-fetches the blueprint and discards local edits.
    func reload() async {
        guard !isBusy else { return }
        operation = .reloading
        defer { operation = .idle }
        do {
            let fresh = try await app.currentService().detail(id: blueprintID)
            app.store(fresh)
            reset(to: fresh)
        } catch {
            handle(error, action: "Reload")
        }
    }

    /// Reloads after a successful write. Returns false (with an alert) if the reload failed.
    private func reloadAfterWrite(service: JamfPlatform.Blueprints) async -> Bool {
        do {
            let fresh = try await service.detail(id: blueprintID)
            app.store(fresh)
            reset(to: fresh)
            return true
        } catch {
            alert = Alert(kind: .error, title: "Reload Failed", message: "The change was sent, but reloading the blueprint failed. Reload before editing again.\n\n\(error.localizedDescription)")
            return false
        }
    }

    private func conflictAlert(latest: JamfPlatform.BlueprintDetail) -> Alert {
        Alert(
            kind: .conflict,
            title: "Blueprint Changed on the Server",
            message: "“\(latest.overview.name)” was modified after you loaded it (loaded: \(base.overview.updated ?? "unknown"), now: \(latest.overview.updated ?? "unknown")). Nothing was saved. Reload to get the latest version; your unsaved edits will be lost."
        )
    }

    private func handle(_ error: Error, action: String) {
        // JTKit's message ends with the hint that the Blueprint is assigned to a division.
        if let platformError = error as? JamfPlatformError, platformError.hasCode(.divisionPatchNotAllowed) {
            app.readOnlyBlueprintIDs.insert(blueprintID)
            alert = Alert(kind: .error, title: "Blueprint Is Read-Only", message: platformError.localizedDescription)
            return
        }
        if error is CancellationError { return }
        alert = Alert(kind: .error, title: "\(action) Failed", message: error.localizedDescription)
    }
}
