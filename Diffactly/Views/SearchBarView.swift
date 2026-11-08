import SwiftUI
import AppKit

struct SearchBarView: View {
    @ObservedObject var document: DiffDocument
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let search = document.search
        let scopeTitle = search.scope.title(in: document)

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))

            TextField("Find in \(scopeTitle)…", text: $document.search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFieldFocused)
                .frame(minWidth: 120, idealWidth: 160)
                .onSubmit {
                    isFieldFocused = true
                    let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true || NSEvent.modifierFlags.contains(.shift)
                    if isShift {
                        document.search.findPrevious()
                    } else {
                        document.search.findNext()
                    }
                }

            if !search.query.isEmpty {
                Text(search.matchSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(search.matches.isEmpty ? Color.red.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }

            // Options toggles (Aa, \b, .*)
            HStack(spacing: 2) {
                SearchOptionButton(
                    title: "Aa",
                    tooltip: "Match Case (Aa)",
                    isOn: $document.search.caseSensitive
                )
                SearchOptionButton(
                    title: "\\b",
                    tooltip: "Match Whole Word (\\b)",
                    isOn: $document.search.wholeWord
                )
                SearchOptionButton(
                    title: ".*",
                    tooltip: "Regular Expression (.*)",
                    isMonospaced: true,
                    isOn: $document.search.useRegex
                )
            }

            Divider()
                .frame(height: 16)

            // Scope Picker
            Picker("Scope", selection: $document.search.scope) {
                Text("All").tag(SearchScope.both)
                Text(document.title(for: .left)).tag(SearchScope.left)
                Text(document.title(for: .right)).tag(SearchScope.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Divider()
                .frame(height: 16)

            // Navigation Previous / Next
            HStack(spacing: 4) {
                Button {
                    document.search.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(search.matches.isEmpty)
                .help("Previous Match (⇧⌘G or ⇧Enter)")

                Button {
                    document.search.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(search.matches.isEmpty)
                .help("Next Match (⌘G or Enter)")
            }

            Divider()
                .frame(height: 16)

            // Close button
            Button {
                document.search.closeSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        .onAppear {
            isFieldFocused = true
        }
        .onChange(of: document.search.isPresented) { _, presented in
            if presented {
                DispatchQueue.main.async {
                    isFieldFocused = true
                }
            }
        }
        .onExitCommand {
            document.search.closeSearch()
        }
    }
}

private struct SearchOptionButton: View {
    let title: String
    let tooltip: String
    var isMonospaced: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(isMonospaced ? .system(size: 11, weight: .bold, design: .monospaced) : .system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.clear)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isOn ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
