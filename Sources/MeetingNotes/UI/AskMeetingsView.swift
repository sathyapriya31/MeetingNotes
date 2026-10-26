import SwiftUI

/// One turn in the "Ask your meetings" chat.
struct AskMessage: Identifiable {
    enum Role { case user, assistant, error }

    let id = UUID()
    let role: Role
    let text: String
    var answer: MeetingAnswer? = nil
}

// MARK: - Ask Your Meetings

/// Chat over all past meetings: retrieval with EmbeddingGemma, answers from the local LLM.
/// Messages live in the parent so the conversation survives switching tabs.
struct AskMeetingsView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @EnvironmentObject var store: MeetingStore

    @Binding var messages: [AskMessage]
    /// Called when a source chip is tapped, to open that meeting.
    var onOpenMeeting: (UUID) -> Void

    @State private var question = ""
    @State private var isAnswering = false
    @FocusState private var isInputFocused: Bool

    private let suggestions = [
        "What did we decide about the release date?",
        "Which action items are assigned to me?",
        "What concerns came up about the budget?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            emptyState
                        }
                        ForEach(messages) { message in
                            bubble(for: message)
                                .id(message.id)
                        }
                        if isAnswering {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Searching your meetings…")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.fg.opacity(0.5))
                            }
                            .id("thinking")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: isAnswering) {
                    if isAnswering { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }

            inputBar
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.cyanWave)
                Text("ASK YOUR MEETINGS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.fg.opacity(0.85))
            }
            Text("Ask a question across all your recorded meetings. Answers are generated on-device from the relevant parts of your transcripts.")
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Theme.fg.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        submit(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.fg.opacity(0.8))
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.fg.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.borderSubtle, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAnswering || store.meetings.isEmpty)
                }
            }
            .padding(.top, 2)

            if store.meetings.isEmpty {
                Text("Record a meeting first — there's nothing to search yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg.opacity(0.4))
            }
        }
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(for message: AskMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Theme.primaryBlue.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant, .error:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(message.role == .error ? Theme.redRecording : Theme.fg.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let sources = message.answer?.sources, !sources.isEmpty {
                    sourceChips(sources)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func sourceChips(_ sources: [(number: Int, meetingID: UUID)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SOURCES")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Theme.fg.opacity(0.4))
            ForEach(sources, id: \.number) { source in
                if let meeting = store.meetings.first(where: { $0.id == source.meetingID }) {
                    Button {
                        onOpenMeeting(meeting.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(source.number)")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.cyanWave)
                                .frame(width: 16, height: 16)
                                .background(Theme.cyanWave.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            Text(meeting.displayTitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.fg.opacity(0.8))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(meeting.date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.fg.opacity(0.4))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Theme.fg.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open this meeting")
                }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your meetings…", text: $question, axis: .vertical)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.fg)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit { submit(question) }

            Button {
                submit(question)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(canSubmit ? Color.white : Theme.fg.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .background(canSubmit ? Theme.primaryBlue : Theme.fg.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isInputFocused ? Theme.borderActive.opacity(0.8) : Theme.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var canSubmit: Bool {
        !isAnswering && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        question = ""
        messages.append(AskMessage(role: .user, text: trimmed))
        isAnswering = true

        Task {
            defer { isAnswering = false }
            do {
                let answer = try await coordinator.ask(trimmed)
                messages.append(AskMessage(role: .assistant, text: answer.text, answer: answer))
            } catch {
                messages.append(AskMessage(role: .error, text: "Couldn't answer: \(error.localizedDescription)"))
            }
        }
    }
}
