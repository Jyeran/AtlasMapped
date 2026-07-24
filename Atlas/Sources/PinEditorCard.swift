import SwiftUI

struct PinEditorCard: View {
    @EnvironmentObject private var state: AppState
    @State private var titleDraft = ""
    @State private var noteDraft = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        if let pin = state.selectedPin {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(AtlasTheme.trailBlue)

                    TextField("Pin name", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AtlasTheme.forest)
                        .focused($isTitleFocused)
                        .onSubmit { commit(pinID: pin.id) }
                        .accessibilityLabel("Pin name")

                    Button {
                        commit(pinID: pin.id)
                        state.dismissPinEditor()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(AtlasTheme.moss.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AtlasTheme.forest)
                    .accessibilityLabel("Close pin editor")
                }

                ZStack(alignment: .topLeading) {
                    if noteDraft.isEmpty {
                        Text("Add a trail note…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $noteDraft)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 58, maxHeight: 78)
                        .padding(.horizontal, 1)
                        .accessibilityLabel("Pin note")
                }
                .background(AtlasTheme.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                HStack {
                    Text(coordinateLabel(pin))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AtlasTheme.moss)
                    Spacer()
                    Button(role: .destructive) { state.removePin(id: pin.id) } label: {
                        Label("Remove pin", systemImage: "trash")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .padding(14)
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 360)
            .atlasPanel()
            .accessibilityElement(children: .contain)
            .onAppear { loadDrafts(from: pin) }
            .onChange(of: state.selectedPinID) { _, _ in
                if let selected = state.selectedPin { loadDrafts(from: selected) }
            }
            .onChange(of: isTitleFocused) { _, focused in
                if !focused { commit(pinID: pin.id) }
            }
            .onDisappear { commit(pinID: pin.id) }
        }
    }

    private func loadDrafts(from pin: RoutePin) {
        titleDraft = pin.title
        noteDraft = pin.note
    }

    private func commit(pinID: UUID) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Untitled Pin" : trimmed
        titleDraft = resolved
        if state.pins.first(where: { $0.id == pinID })?.title != resolved {
            state.setPinTitle(id: pinID, title: resolved)
        }
        if state.pins.first(where: { $0.id == pinID })?.note != noteDraft {
            state.setPinNote(id: pinID, note: noteDraft)
        }
    }

    private func coordinateLabel(_ pin: RoutePin) -> String {
        "\(pin.latitude.formatted(.number.precision(.fractionLength(4)))), \(pin.longitude.formatted(.number.precision(.fractionLength(4))))"
    }
}
