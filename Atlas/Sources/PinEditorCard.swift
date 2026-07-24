import SwiftUI

struct PinEditorCard: View {
    @EnvironmentObject private var state: AppState
    @State private var titleDraft = ""
    @State private var noteDraft = ""
    @State private var colorDraft: RoutePinColor = .blue
    @State private var symbolDraft: RoutePinSymbol = .pin
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        if let pin = state.selectedPin {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    locationStats(pin)
                    pinAppearancePicker
                    noteEditor
                    actions(pin)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 380, maxHeight: 560)
            .atlasPanel()
            .accessibilityElement(children: .contain)
            .onAppear { loadDrafts(from: pin) }
            .onChange(of: state.selectedPinID) { _, _ in
                if let selected = state.selectedPin { loadDrafts(from: selected) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolDraft.systemName)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(colorDraft.color, in: Circle())
                .shadow(color: colorDraft.color.opacity(0.25), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("MAP PIN")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(AtlasTheme.moss)
                TextField("Pin name", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(AtlasTheme.forest)
                    .focused($isTitleFocused)
                    .submitLabel(.done)
                    .accessibilityLabel("Pin name")
            }
        }
    }

    private func locationStats(_ pin: RoutePin) -> some View {
        HStack(spacing: 0) {
            pinStat(
                title: "Elevation",
                value: elevationLabel(pin),
                symbol: "mountain.2.fill"
            )
            Divider().frame(height: 34)
            pinStat(
                title: "Coordinates",
                value: coordinateLabel(pin),
                symbol: "location.fill"
            )
        }
        .padding(.vertical, 11)
        .background(AtlasTheme.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func pinStat(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(AtlasTheme.forest)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var pinAppearancePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPEARANCE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(AtlasTheme.moss)

            HStack(spacing: 10) {
                ForEach(RoutePinColor.allCases) { option in
                    Button {
                        withAnimation(AtlasMotion.quick) { colorDraft = option }
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 28, height: 28)
                            .overlay {
                                if colorDraft == option {
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                        .padding(3)
                                    Circle()
                                        .stroke(option.color.opacity(0.35), lineWidth: 2)
                                        .padding(-3)
                                }
                            }
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(AtlasPressButtonStyle())
                    .accessibilityLabel("\(option.title) pin")
                    .accessibilityAddTraits(colorDraft == option ? .isSelected : [])
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                ForEach(RoutePinSymbol.allCases) { option in
                    Button {
                        withAnimation(AtlasMotion.quick) { symbolDraft = option }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: option.systemName)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(height: 19)
                            Text(option.title)
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(symbolDraft == option ? .white : AtlasTheme.forest)
                        .frame(maxWidth: .infinity, minHeight: 47)
                        .background(
                            symbolDraft == option ? colorDraft.color : AtlasTheme.moss.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(AtlasPressButtonStyle())
                    .accessibilityAddTraits(symbolDraft == option ? .isSelected : [])
                }
            }
        }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if noteDraft.isEmpty {
                Text("Add a trail note…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $noteDraft)
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 66, maxHeight: 88)
                .padding(.horizontal, 5)
                .accessibilityLabel("Pin note")
        }
        .background(AtlasTheme.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func actions(_ pin: RoutePin) -> some View {
        HStack(spacing: 9) {
            Button(role: .destructive) { state.removePin(id: pin.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 46, height: 46)
                    .background(.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(AtlasPressButtonStyle())
            .foregroundStyle(.red)
            .accessibilityLabel("Remove pin")

            Button {
                commit(pinID: pin.id)
                isTitleFocused = false
                state.dismissPinEditor()
            } label: {
                Label("Save pin", systemImage: "checkmark")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(.white)
                    .background(colorDraft.color, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(AtlasPressButtonStyle())
        }
    }

    private func loadDrafts(from pin: RoutePin) {
        titleDraft = pin.title
        noteDraft = pin.note
        colorDraft = pin.resolvedColor
        symbolDraft = pin.resolvedSymbol
        state.refreshPinElevation(id: pin.id)
    }

    private func commit(pinID: UUID) {
        state.updatePin(
            id: pinID,
            title: titleDraft,
            note: noteDraft,
            color: colorDraft,
            symbol: symbolDraft
        )
    }

    private func coordinateLabel(_ pin: RoutePin) -> String {
        "\(pin.latitude.formatted(.number.precision(.fractionLength(4)))), \(pin.longitude.formatted(.number.precision(.fractionLength(4))))"
    }

    private func elevationLabel(_ pin: RoutePin) -> String {
        if let elevation = pin.elevationMeters {
            return state.unitSystem.elevation(elevation)
        }
        return state.isLoadingPinElevation(id: pin.id) ? "Sampling…" : "Unavailable"
    }
}
