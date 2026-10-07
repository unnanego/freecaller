import AVFAudio
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var calls: CallController

  var body: some View {
    Group {
      if calls.call != nil {
        InCallView()
      } else if session.isSignedIn {
        NavigationStack { ContactsView() }
      } else {
        SignedOutView()
      }
    }
    .alert(
      calls.lastError ?? "",
      isPresented: Binding(get: { calls.lastError != nil }, set: { if !$0 { calls.lastError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
    .task {
      // Ask for the microphone up front, not in the middle of the first call.
      if AVAudioApplication.shared.recordPermission == .undetermined {
        _ = await AVAudioApplication.requestRecordPermission()
      }
    }
  }
}

// MARK: - contacts

struct ContactsView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var calls: CallController

  var body: some View {
    List {
      if session.contacts.isEmpty {
        Text("Контактов пока нет. Откройте Звонилку на iPhone.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(session.contacts) { contact in
        Button {
          calls.startCall(to: contact)
        } label: {
          HStack(spacing: 12) {
            Avatar(initials: contact.initials)
            Text(contact.displayName)
              .font(.title3.weight(.semibold))
              .lineLimit(2)
              .minimumScaleFactor(0.7)
          }
          .padding(.vertical, 8)
        }
        .accessibilityLabel("Позвонить: \(contact.displayName)")
      }
      NavigationLink("Диагностика") { DiagnosticsView() }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .navigationTitle("Звонилка")
    .refreshable { await session.refreshFromServer() }
  }
}

struct Avatar: View {
  let initials: String

  var body: some View {
    Text(initials)
      .font(.headline)
      .frame(width: 40, height: 40)
      .background(Circle().fill(Color.green.opacity(0.35)))
      .accessibilityHidden(true)
  }
}

// MARK: - in call

struct InCallView: View {
  @EnvironmentObject private var calls: CallController

  var body: some View {
    VStack(spacing: 8) {
      if let call = calls.call {
        Text(call.peerName)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
          .minimumScaleFactor(0.6)
          .multilineTextAlignment(.center)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(status(call, now: context.date))
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if call.isEcho, !calls.echoSummary.isEmpty {
          Text(calls.echoSummary)
            .font(.caption2)
            .multilineTextAlignment(.center)
        }
      }
      Spacer(minLength: 4)
      if calls.phase == .ringing {
        Button {
          calls.answer()
        } label: {
          Label("Ответить", systemImage: "phone.fill")
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
      }
      HStack(spacing: 16) {
        Button {
          calls.toggleMute()
        } label: {
          Image(systemName: calls.muted ? "mic.slash.fill" : "mic.fill")
            .font(.title2)
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .accessibilityLabel(calls.muted ? "Включить микрофон" : "Выключить микрофон")

        Button(role: .destructive) {
          calls.hangUp()
        } label: {
          Image(systemName: "phone.down.fill")
            .font(.title2)
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .clipShape(Circle())
        .accessibilityLabel("Завершить звонок")
      }
    }
    .padding(.horizontal, 4)
  }

  private func status(_ call: CallController.ActiveCall, now: Date) -> String {
    switch calls.phase {
    case .dialing: return "Вызов…"
    case .ringing: return "Входящий звонок"
    case .connecting: return "Соединение…"
    case .reconnecting: return "Восстанавливаем связь…"
    case .idle: return ""
    case .inCall:
      guard let start = call.connectedAt else { return "Соединение…" }
      let s = Int(now.timeIntervalSince(start))
      return String(format: "%d:%02d", s / 60, s % 60)
    }
  }
}

// MARK: - signed out

struct SignedOutView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Image(systemName: "iphone.and.arrow.forward")
          .font(.largeTitle)
          .accessibilityHidden(true)
        Text("Откройте Звонилку на iPhone — часы войдут сами.")
          .multilineTextAlignment(.center)
      }
      .padding()
    }
  }
}

// MARK: - diagnostics

/// What spike 1 and 2 in docs/watch-plan.md read off the watch.
struct DiagnosticsView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var calls: CallController
  @State private var codec: String?
  @State private var lines: [String] = []

  var body: some View {
    List {
      Section("Статус") {
        row("Аккаунт", session.displayName.isEmpty ? "—" : session.displayName)
        row("Пуш", calls.pushRegistered ? "зарегистрирован" : "нет")
        row("Opus", codec ?? "проверка…")
        row("Устройство", String(session.deviceId.prefix(8)))
      }
      Section {
        Button("Тест эха") { calls.startEchoTest() }
      } footer: {
        Text("Говорите — услышите себя через сервер. Показывает задержку.")
      }
      Section("Журнал") {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line).font(.system(size: 11, design: .monospaced))
        }
      }
    }
    .navigationTitle("Диагностика")
    .task {
      lines = Log.recent()
      let result = await Task.detached { AudioPipeline.codecCheck() }.value
      codec = result.map { "нет: \($0)" } ?? "работает"
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.footnote)
    }
  }
}
