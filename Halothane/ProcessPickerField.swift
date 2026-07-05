import SwiftUI

/// A text field with a filtering autocomplete dropdown of running processes.
/// Candidates come from the same system-wide sample as the "All Processes"
/// window. Matches on both name and path (so a process whose proc_name is
/// unhelpful — e.g. a bare version "2.1.186" — is findable by typing part of its
/// path) and shows the path as a hint. Typing filters; click or ↑/↓ + Return
/// selects (inserting the name). Freeform text is still allowed.
///
/// Filtering is driven by a local `query` state mirrored into the bound `text`,
/// rather than reading the external binding directly — that keeps the dropdown
/// in sync with the keystrokes even while the parent re-renders on each change.
struct ProcessPickerField: View {
    @Binding var text: String
    let candidates: [ProcCandidate]
    var placeholder: String = "Process name contains…"

    @State private var query = ""
    @State private var showList = false
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private var filtered: [ProcCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(q)
            || ($0.path?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Stable id of the keyboard-highlighted row (index → candidate).
    private var highlightedID: ProcCandidate.ID? {
        filtered.indices.contains(highlight) ? filtered[highlight].id : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onAppear { query = text }
                .onChange(of: text) { if text != query { query = text } }   // external (rule switch)
                .onChange(of: query) { text = query; highlight = 0; showList = focused }
                .onChange(of: focused) { showList = focused }
                .onKeyPress(.downArrow) {
                    guard showList, !filtered.isEmpty else { return .ignored }
                    highlight = min(highlight + 1, filtered.count - 1); return .handled
                }
                .onKeyPress(.upArrow) {
                    guard showList, !filtered.isEmpty else { return .ignored }
                    highlight = max(highlight - 1, 0); return .handled
                }
                .onKeyPress(.return) {
                    guard showList, filtered.indices.contains(highlight) else { return .ignored }
                    select(filtered[highlight]); return .handled
                }
                .onKeyPress(.escape) {
                    guard showList else { return .ignored }
                    showList = false; return .handled
                }

            if showList && !filtered.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { cand in
                                let isHighlighted = cand.id == highlightedID
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(cand.name).font(.callout).lineLimit(1)
                                    if let path = cand.path {
                                        Text(path).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isHighlighted ? Color.accentColor.opacity(0.25) : .clear)
                                .contentShape(Rectangle())
                                .id(cand.id)
                                .onTapGesture { select(cand) }
                            }
                        }
                        .padding(2)
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: highlight) {
                        if let id = highlightedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .padding(.top, 2)
            }
        }
    }

    private func select(_ cand: ProcCandidate) {
        query = cand.name
        text = cand.name
        showList = false
        focused = false
    }
}
