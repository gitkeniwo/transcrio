import SwiftUI
import TranscribeKit

/// Banner at the top of the center pane: ffmpeg missing, CLI not found, worker errors.
struct BannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var banner: AppModel.Banner

    var body: some View {
        switch banner {
        case .ffmpegMissing:
            BannerCard(tone: .red, systemImage: "exclamationmark.triangle.fill", title: "ffmpeg is missing",
                       message: "Transcrio needs ffmpeg to read audio. Install it, then check again. Your queue is kept.",
                       code: "brew install ffmpeg") {
                Button("Copy Command") { model.copyFFmpegCommand() }.buttonStyle(FlatButtonStyle())
                Button("Check Again") { Task { await model.checkEnvironment() } }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .disabled(model.checkingEnvironment)
            }
            .accessibilityAddTraits(.isStaticText)
        case .cliNotFound(let detail):
            if model.cliInstallSource == nil {
                // `swift run`: no app version, so nothing to install from.
                BannerCard(tone: .yellow, systemImage: "terminal", title: "Can’t find the transcribe command",
                           message: "Looked in ~/.local/bin/transcribe and tried uv run in the project folder. \(detail)") {
                    Button("Choose in Settings…") { openSettings() }.buttonStyle(FlatButtonStyle(prominent: true))
                    Button("Check Again") { Task { await model.checkEnvironment() } }.buttonStyle(FlatButtonStyle())
                }
            } else if model.uvPath == nil {
                BannerCard(tone: .yellow, systemImage: "terminal", title: "Transcrio needs uv to install its command-line tool",
                           message: "Transcrio transcribes with the transcribe command-line tool, which it installs with uv. "
                               + "Install uv, then check again.",
                           code: CLIInstaller.uvInstallCommand) {
                    Button("Copy Command") { model.copyUvCommand() }.buttonStyle(FlatButtonStyle())
                    Button("Check Again") { Task { await model.checkEnvironment() } }
                        .buttonStyle(FlatButtonStyle(prominent: true))
                        .disabled(model.checkingEnvironment)
                    Button("Choose in Settings…") { openSettings() }.buttonStyle(FlatButtonStyle())
                }
            } else {
                BannerCard(tone: .yellow, systemImage: "terminal", title: "Install the command-line tool",
                           message: "Transcrio transcribes with the transcribe command-line tool, which isn’t installed yet. "
                               + "Installing it takes a minute or two the first time. \(detail)",
                           extra: CLIInstallStatus(state: model.cliInstall)) {
                    Button("Install Command-Line Tool") { model.installCLI() }
                        .buttonStyle(FlatButtonStyle(prominent: true))
                        .disabled(model.cliInstall.isRunning || model.isRunning)
                    Button("Choose in Settings…") { openSettings() }.buttonStyle(FlatButtonStyle())
                        .disabled(model.cliInstall.isRunning)
                }
            }
        case .cliOutdated(let installed, let expected):
            if model.uvPath == nil {
                BannerCard(tone: .yellow, systemImage: "arrow.triangle.2.circlepath", title: "The command-line tool is out of date",
                           message: "Transcrio \(expected) comes with transcribe \(expected), but transcribe \(installed) is installed. "
                               + "Updating it needs uv.",
                           code: CLIInstaller.uvInstallCommand) {
                    Button("Copy Command") { model.copyUvCommand() }.buttonStyle(FlatButtonStyle())
                    Button("Check Again") { Task { await model.checkEnvironment() } }.buttonStyle(FlatButtonStyle())
                    Button("Not Now") { model.dismissOutdatedBanner() }.buttonStyle(FlatButtonStyle())
                }
            } else {
                BannerCard(tone: .yellow, systemImage: "arrow.triangle.2.circlepath", title: "Update the command-line tool",
                           message: "Transcrio \(expected) comes with transcribe \(expected), but transcribe \(installed) is installed. "
                               + (model.isRunning ? "Update once the batch finishes." : "Transcriptions still run in the meantime."),
                           extra: CLIInstallStatus(state: model.cliInstall)) {
                    Button("Update Command-Line Tool") { model.installCLI() }
                        .buttonStyle(FlatButtonStyle(prominent: true))
                        .disabled(model.cliInstall.isRunning || model.isRunning)
                    Button("Not Now") { model.dismissOutdatedBanner() }.buttonStyle(FlatButtonStyle())
                        .disabled(model.cliInstall.isRunning)
                }
            }
        case .message(let text):
            BannerCard(tone: .red, systemImage: "xmark.octagon.fill", title: "Transcription couldn’t run", message: text) {
                Button("Dismiss") { model.banner = nil }.buttonStyle(FlatButtonStyle())
            }
        }
    }
}

struct BannerCard<Actions: View>: View {
    var tone: Tone
    var systemImage: String
    var title: String
    var message: String
    var code: String?
    var extra: CLIInstallStatus?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(tone.fg).frame(width: 32, height: 32)
                .overlay(Image(systemName: systemImage).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.onFill))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let code {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .card(radius: 6)
                        .padding(.top, 5)
                }
                if let extra { extra.padding(.top, 5) }
                HStack(spacing: 8) { actions }.padding(.top, 7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

/// Progress or failure of `uv tool install` under the CLI banners.
struct CLIInstallStatus: View {
    var state: AppModel.CLIInstallState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running(let line):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(line)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Installing: \(line)")
        case .failed(let message, let tail):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.red)
                if !tail.isEmpty {
                    Text(tail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(radius: 6)
                }
            }
        }
    }
}

extension AppModel.CLIInstallState {
    var isRunning: Bool { if case .running = self { true } else { false } }
}

private struct ResultTile: View {
    var title: String
    var value: Int
    var tone: Tone
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").font(.system(size: 20, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(width: 150, height: 46)
        .foregroundStyle(tone.fg)
        .background(tone.bg, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct DismissButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

