import SwiftUI

struct PinEditorCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let pin = state.selectedPin {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(AtlasTheme.trailBlue)

                    TextField("Pin name", text: titleBinding(for: pin.id))
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AtlasTheme.forest)
                        .onSubmit { state.normalizePinTitle(id: pin.id) }
                        .accessibilityLabel("Pin name")

                    Button { state.dismissPinEditor() } label: {
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
                    if pin.note.isEmpty {
                        Text("Add a trail note…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: noteBinding(for: pin.id))
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
        }
    }

    private func titleBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { state.pins.first(where: { $0.id == id })?.title ?? "" },
            set: { state.setPinTitle(id: id, title: $0) }
        )
    }

    private func noteBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { state.pins.first(where: { $0.id == id })?.note ?? "" },
            set: { state.setPinNote(id: id, note: $0) }
        )
    }

    private func coordinateLabel(_ pin: RoutePin) -> String {
        "\(pin.latitude.formatted(.number.precision(.fractionLength(4)))), \(pin.longitude.formatted(.number.precision(.fractionLength(4))))"
    }
}
