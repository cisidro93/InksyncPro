import SwiftUI

struct EBookSettingsPanel: View {
    @ObservedObject var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Drag Indicator manually rendered since Sheet detents are iOS 16+
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 12)
                
                Text("Customize Appearance")
                    .font(.headline)
                
                // --- Themes Row ---
                HStack(spacing: 20) {
                    ForEach(EBookTheme.allCases) { theme in
                        VStack(spacing: 8) {
                            Circle()
                                .fill(theme.background(colorScheme: colorScheme))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text("Aa")
                                        .font(.system(size: 18, weight: .medium, design: .serif))
                                        .foregroundColor(theme.foreground(colorScheme: colorScheme))
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(prefs.themeRaw == theme.rawValue ? Color.blue : Color.gray.opacity(0.3), lineWidth: prefs.themeRaw == theme.rawValue ? 3 : 1)
                                )
                                .onTapGesture {
                                    withAnimation { prefs.themeRaw = theme.rawValue }
                                }
                            
                            Text(theme.rawValue)
                                .font(.caption2)
                                .foregroundColor(prefs.themeRaw == theme.rawValue ? .blue : .primary)
                        }
                    }
                }
                .padding(.horizontal)
                
                Divider()
                
                // --- Typography Settings ---
                VStack(alignment: .leading, spacing: 16) {
                    Text("TYPOGRAPHY").font(.caption).foregroundColor(.gray)
                    
                    // Font Family
                    HStack {
                        Text("Typeface")
                        Spacer()
                        Picker("Typeface", selection: $prefs.fontFamily) {
                            ForEach(EBookFontFamily.allCases) { fam in
                                Text(fam.displayName).tag(fam.rawValue)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    
                    // Font Size View
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Stepper(value: $prefs.fontSize, in: 10...36, step: 1) {
                            Text("\(Int(prefs.fontSize))pt")
                                .frame(width: 45, alignment: .trailing)
                        }
                        .labelsHidden()
                        Text("\(Int(prefs.fontSize))pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    
                    // Line Spacing
                    HStack {
                        Text("Line Spacing")
                        Spacer()
                        Stepper(value: $prefs.lineHeight, in: 1.0...2.5, step: 0.1) {
                            Text(String(format: "%.1f", prefs.lineHeight))
                        }
                        .labelsHidden()
                        Text(String(format: "%.1f", prefs.lineHeight))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    
                    // Alignment
                    Picker("Alignment", selection: $prefs.textAlign) {
                        Text("Justified").tag(EBookTextAlign.justify.rawValue)
                        Text("Left").tag(EBookTextAlign.left.rawValue)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                .padding(.horizontal)
                
                Divider()
                
                // --- Advanced Layout ---
                VStack(alignment: .leading, spacing: 16) {
                    Text("LAYOUT & SPACING").font(.caption).foregroundColor(.gray)
                    
                    // Margins
                    VStack(alignment: .leading) {
                        Text("Page Margins")
                        Slider(value: $prefs.textMargin, in: 0...60, step: 5)
                    }
                    
                    // Paragraph Spacing
                    VStack(alignment: .leading) {
                        Text("Paragraph Spacing")
                        Slider(value: $prefs.paragraphSpacing, in: 0...2.0, step: 0.1)
                    }
                    
                    // Paragraph Indent
                    VStack(alignment: .leading) {
                        Text("Paragraph Indent")
                        Slider(value: $prefs.paragraphIndent, in: 0...3.0, step: 0.2)
                    }
                }
                .padding(.horizontal)
                
                Divider()
                
                // --- Pagination ---
                VStack(alignment: .leading, spacing: 16) {
                    Text("PAGINATION").font(.caption).foregroundColor(.gray)
                    
                    ForEach(EBookPaginationMode.allCases) { mode in
                        HStack {
                            Image(systemName: mode == .paged ? "book.pages" : "arrow.up.and.down.text.horizontal")
                            Text(mode.rawValue)
                            Spacer()
                            if prefs.paginationMode == mode.rawValue {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation { prefs.paginationMode = mode.rawValue }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .background(Color(UIColor.systemBackground))
    }
}
