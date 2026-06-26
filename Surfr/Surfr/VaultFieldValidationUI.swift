import SwiftUI
import SurfrCore

// MARK: - Shared TV-2-VAL field-validation presentation (soft, amber, never blocks)

/// A short amber hint shown beneath a field whose value looks suspect. Reuses the amber/⚠ vocabulary
/// (never red error states); informational only — it never affects whether save is enabled.
struct ValidationHint: View {
    let check: FieldCheck
    var body: some View {
        if let reason = check.reason {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

extension String {
    /// `self` unless empty, in which case `fallback` — keeps a raw value when canonicalisation yields "".
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension View {
    /// A subtle amber border when a field's value looks suspect (soft, informational).
    @ViewBuilder func suspectBorder(_ suspect: Bool) -> some View {
        if suspect {
            self.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.7), lineWidth: 1))
        } else {
            self
        }
    }
}

/// Quiet, dismissible "saved anyway" banner shown after a save when some fields looked suspect — the
/// save has ALREADY succeeded; this never blocks it.
struct SavedAnywayBanner: View {
    let onDone: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Some fields look incomplete or invalid — saved anyway.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDone).keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }
}

// MARK: - Month / Year picker (structured expiry / valid-from — can't produce garbage)

/// A month (01–12) + year picker for card expiry / valid-from. Structured input so a NEW value can't be
/// garbage; an unparseable IMPORTED value leaves the pickers unset and is flagged (but still editable).
struct MonthYearPicker: View {
    let label: String
    @Binding var month: Int?
    @Binding var year: Int?
    /// True when the originally-loaded value was non-empty but unparseable (imported junk).
    let rawWasSuspect: Bool

    private var years: [Int] {
        let now = Calendar.current.component(.year, from: Date())
        var range = Array((now - 30)...(now + 20))   // wide enough that an imported year always has a tag…
        if let y = year, !range.contains(y) { range.append(y); range.sort() }   // …and never drops the bound value
        return range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Month", selection: $month) {
                    Text("Month").tag(Int?.none)
                    ForEach(1...12, id: \.self) { m in Text(String(format: "%02d", m)).tag(Int?.some(m)) }
                }
                .labelsHidden().fixedSize()
                Picker("Year", selection: $year) {
                    Text("Year").tag(Int?.none)
                    ForEach(years, id: \.self) { y in Text(String(y)).tag(Int?.some(y)) }
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            if rawWasSuspect && (month == nil || year == nil) {
                ValidationHint(check: .suspect("the imported value isn’t a valid date — pick a month and year"))
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Country list (for the address country picker)

enum CountryList {
    /// Localized country names (ISO 3166-1 alpha-2), sorted.
    static let names: [String] = {
        let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
        return Set(codes.compactMap { Locale.current.localizedString(forRegionCode: $0) }).sorted()
    }()

    /// A non-empty country is "recognised" iff it matches a known localized name; empty is fine.
    static func isRecognised(_ country: String) -> Bool {
        country.isEmpty || names.contains(country)
    }
}
