import JTKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedBlueprintID) {
            ForEach(model.visibleOverviews) { overview in
                BlueprintRow(
                    overview: overview,
                    domains: model.preferenceDomains[overview.id] ?? [],
                    error: model.detailErrors[overview.id],
                    isDirty: model.editors[overview.id]?.isDirty == true,
                    isReadOnly: model.isReadOnly(overview.id)
                )
                .tag(overview.id)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Name, description or domain")
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $model.sidebarFilter) {
                ForEach(AppModel.SidebarFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .bottom) {
            DiscoveryStatusView()
        }
        .overlay {
            if model.visibleOverviews.isEmpty && !model.isBusy {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.overviews.isEmpty {
            ContentUnavailableView(
                "No Blueprints Loaded",
                systemImage: "square.stack.3d.up",
                description: Text("Click Refresh to discover blueprints.")
            )
        } else if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView(
                "No Managed Preferences Found",
                systemImage: "square.stack.3d.up.slash",
                description: Text("None of the \(model.overviews.count) blueprints contain a com.apple.ManagedClient.preferences payload. Switch to All Blueprints to inspect them.")
            )
        }
    }
}

private struct DiscoveryStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.discoveryState {
            case .idle:
                EmptyView()
            case .listing:
                ProgressView().controlSize(.small)
                Text("Listing blueprints…")
            case .fetchingDetails(let completed, let total):
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(width: 80)
                Text("Reading \(completed) of \(total)")
            case .finished(let date):
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("\(model.managedPreferencesCount) of \(model.overviews.count) with Managed Preferences · \(date.formatted(date: .omitted, time: .shortened))")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .lineLimit(3)
                    .help(message)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, model.discoveryState == .idle ? 0 : 8)
    }
}

struct BlueprintRow: View {
    let overview: JamfPlatform.BlueprintOverview
    /// The Blueprint's preference domains, once its details are loaded.
    let domains: [String]
    let error: String?
    var isDirty = false
    var isReadOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if isDirty {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tint)
                        .help("Unsaved changes")
                }
                if isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Read-only (assigned to a division)")
                }
                Text(overview.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let state = overview.deploymentState?.state {
                    DeploymentStateBadge(state: state)
                }
            }
            if let date = overview.updatedDate {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if !domains.isEmpty {
                Text(domains.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeploymentStateBadge: View {
    let state: JamfPlatform.BlueprintState

    var body: some View {
        Text(state.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .deployed: .green
        case .outOfDate: .orange
        case .notDeployed: .secondary
        case .other: .blue
        }
    }
}
