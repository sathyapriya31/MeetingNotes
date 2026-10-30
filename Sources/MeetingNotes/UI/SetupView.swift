import SwiftUI

/// First-run screen: downloads the on-device models with per-model and overall
/// progress. Shown over the main window when models are missing at launch; the
/// downloads run in the background either way, so it can be dismissed.
struct SetupView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @EnvironmentObject var setup: ModelSetup

    var body: some View {
        ZStack {
            Theme.bgApp.opacity(0.97)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(spacing: 0) {
                    ForEach(ModelSetup.Model.allCases) { model in
                        row(for: model)
                        if model != ModelSetup.Model.allCases.last {
                            Divider().background(Theme.borderSubtle)
                        }
                    }
                }
                .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderSubtle, lineWidth: 1))

                overallProgress

                footer
            }
            .padding(28)
            .frame(width: 560)
            .background(Theme.bgSidebar, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderSubtle, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Theme.primaryBlue, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text(setup.isComplete ? "You're all set" : "Setting up Meeting Notes")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.fg)
                Text(setup.isComplete
                     ? "All models are on your Mac and loaded. Recordings now start right away."
                     : "Everything runs on your Mac, so no audio leaves it. The AI models (about \(Self.size(totalMegabytes))) download once; after that the app works offline. You can keep using the app while they download.")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fg.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(for model: ModelSetup.Model) -> some View {
        let state = setup.state(of: model)
        return HStack(spacing: 12) {
            Image(systemName: model.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.cyanWave)
                .frame(width: 30, height: 30)
                .background(Theme.cyanWave.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text(model.purpose)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.fg.opacity(0.5))
                        .lineLimit(1)
                    Spacer()
                    statusLabel(state, model: model)
                }
                switch state {
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.primaryBlue)
                case .loading:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.primaryBlue)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.orange)
                        .lineLimit(2)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func statusLabel(_ state: ModelSetup.State, model: ModelSetup.Model) -> some View {
        switch state {
        case .waiting:
            Text(setup.toDownload.contains(model) ? Self.size(model.megabytes) : "Waiting")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.fg.opacity(0.45))
        case .downloading(let fraction):
            Text("\(Int(fraction * 100))% of \(Self.size(model.megabytes))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.primaryBlue)
        case .loading:
            Text("Loading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.fg.opacity(0.6))
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.greenLocal)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
    }

    private var overallProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: setup.overallProgress)
                .progressViewStyle(.linear)
                .tint(setup.isComplete ? Theme.greenLocal : Theme.primaryBlue)
            Text(setup.isComplete
                 ? "All models ready"
                 : "\(Int(setup.overallProgress * 100))% · \(Self.size(setup.overallProgress * totalMegabytes)) of \(Self.size(totalMegabytes))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.fg.opacity(0.55))
        }
    }

    private var footer: some View {
        HStack {
            if setup.hasFailure {
                Text("Check your internet connection, then retry.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg.opacity(0.5))
                Spacer()
                Button("Retry") { coordinator.preloadModels() }
                    .disabled(setup.isBusy)
            } else {
                Spacer()
            }
            Button(setup.isComplete ? "Get Started" : "Continue in Background") {
                setup.showsSetupScreen = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    private var totalMegabytes: Double {
        ModelSetup.Model.allCases.map(\.megabytes).reduce(0, +)
    }

    static func size(_ megabytes: Double) -> String {
        megabytes >= 1_000
            ? String(format: "%.1f GB", megabytes / 1_000)
            : "\(Int(megabytes.rounded())) MB"
    }
}

/// Compact progress shown in the sidebar while models are still downloading or
/// loading after the setup screen was dismissed (or when it never showed because
/// the models were already downloaded). Click to open the setup screen.
struct ModelSetupStatusRow: View {
    @EnvironmentObject var setup: ModelSetup

    var body: some View {
        Button {
            setup.showsSetupScreen = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if setup.hasFailure && !setup.isBusy {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text("Model download failed — click to retry")
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                        Text(setup.pendingDownloadMegabytes > 0
                             ? "Downloading AI models · \(Int(setup.overallProgress * 100))%"
                             : "Loading AI models…")
                    }
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.fg.opacity(0.75))

                if setup.pendingDownloadMegabytes > 0 && !setup.hasFailure {
                    ProgressView(value: setup.overallProgress)
                        .progressViewStyle(.linear)
                        .tint(Theme.primaryBlue)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show model setup")
    }
}
