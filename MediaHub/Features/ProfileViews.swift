import SwiftUI

// MARK: - Avatar

/// Round profile picture: the profile's colour with its icon (or first letter) on top.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 30

    var body: some View {
        let base = Color(hex: profile.colorHex) ?? .purple
        ZStack {
            Circle().fill(LinearGradient(colors: [base, base.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if profile.symbol.isEmpty {
                Text(profile.initial)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: profile.symbol)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Top-right button

/// Adds the profile avatar to the top-right of a screen, like the Apple TV app. Toolbar items get the
/// Liquid Glass treatment from the system, so the avatar sits in a glass circle. Tapping opens the profile picker.
struct ProfileToolbar: ViewModifier {
    @Environment(ProfileStore.self) private var profiles
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showing = true } label: { ProfileAvatar(profile: profiles.active, size: 30) }
                        .accessibilityLabel("Profile")
                        .accessibilityValue(profiles.active.name)
                }
            }
            .sheet(isPresented: $showing) { ProfileSheet() }
    }
}

extension View {
    /// Put this on the root content of each tab's NavigationStack.
    func profileToolbar() -> some View { modifier(ProfileToolbar()) }
}

// MARK: - Picker sheet

enum ProfileTarget: Identifiable {
    case new
    case edit(Profile)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let p): return p.id
        }
    }
}

/// "Who's watching?": tap a profile to switch, or enter Manage mode to edit, add and delete.
struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @State private var managing = false
    @State private var target: ProfileTarget?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 16, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(profiles.profiles) { tile($0) }
                        if profiles.canAdd { addTile }
                    }
                    Text(footnote)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(managing ? "Done Editing" : "Manage Profiles") {
                        withAnimation(.snappy) { managing.toggle() }
                    }
                    .buttonStyle(.glass)
                }
                .padding(20)
            }
            .navigationTitle("Who's watching?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $target) { ProfileEditor(target: $0) }
    }

    private var footnote: String {
        simkl.isConnected
            ? "Watch history and Continue Watching are kept separately for each profile. Your library comes from Simkl, so every profile shares it."
            : "Each profile keeps its own watch history and library on this device. Connect Simkl in Settings to sync a library across devices."
    }

    private func tile(_ p: Profile) -> some View {
        let active = p.id == profiles.activeID
        return Button {
            if managing { target = .edit(p) }
            else { profiles.select(p.id); dismiss() }
        } label: {
            VStack(spacing: 9) {
                ProfileAvatar(profile: p, size: 76)
                    .overlay {
                        if managing {
                            ZStack {
                                Circle().fill(.black.opacity(0.5))
                                Image(systemName: "pencil").font(.title3.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(4)
                    .overlay { if active && !managing { Circle().strokeBorder(theme.accent, lineWidth: 3) } }
                Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(p.name)
        .accessibilityHint(managing ? "Edit profile" : "Switch to this profile")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var addTile: some View {
        Button { target = .new } label: {
            VStack(spacing: 9) {
                Image(systemName: "plus").font(.title.weight(.semibold))
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(4)
                Text("Add Profile").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Editor

struct ProfileEditor: View {
    let target: ProfileTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profiles
    @State private var name: String
    @State private var colorHex: String
    @State private var symbol: String
    @State private var confirmDelete = false

    /// "" = the first letter of the name.
    private static let symbols = ["", "person.fill", "face.smiling.fill", "star.fill", "heart.fill", "bolt.fill",
                                  "flame.fill", "moon.fill", "sparkles", "gamecontroller.fill", "pawprint.fill",
                                  "leaf.fill", "film.fill", "tv.fill", "music.note"]

    init(target: ProfileTarget) {
        self.target = target
        switch target {
        case .new:
            _name = State(initialValue: "")
            _colorHex = State(initialValue: Theme.presets.randomElement()?.hex ?? Theme.defaultHex)
            _symbol = State(initialValue: "")
        case .edit(let p):
            _name = State(initialValue: p.name)
            _colorHex = State(initialValue: p.colorHex)
            _symbol = State(initialValue: p.symbol)
        }
    }

    private var existing: Profile? {
        if case .edit(let p) = target { return p }
        return nil
    }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: Profile {
        Profile(id: "preview", name: trimmed.isEmpty ? "?" : trimmed, colorHex: colorHex, symbol: symbol)
    }
    private let grid = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProfileAvatar(profile: draft, size: 96)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                }
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                Section("Colour") {
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(Theme.presets, id: \.hex) { p in
                            Button { colorHex = p.hex } label: {
                                Circle().fill(Color(hex: p.hex) ?? .gray).frame(width: 36, height: 36)
                                    .overlay {
                                        if colorHex.uppercased() == p.hex.uppercased() {
                                            Image(systemName: "checkmark").font(.footnote.weight(.black)).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(p.name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Icon") {
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { s in iconButton(s) }
                    }
                    .padding(.vertical, 4)
                }
                if existing != nil, profiles.profiles.count > 1 {
                    Section {
                        Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deletes this profile's watch history and local library.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(trimmed.isEmpty) }
            }
            .onChange(of: name) { _, v in if v.count > 20 { name = String(v.prefix(20)) } }
            .confirmationDialog("Delete \(existing?.name ?? "this profile")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    if let p = existing { profiles.delete(p.id) }
                    dismiss()
                }
            } message: {
                Text("Its watch history and local library will be removed. This can't be undone.")
            }
        }
        .presentationDetents([.large])
    }

    private func iconButton(_ s: String) -> some View {
        let on = symbol == s
        let fill: Color = on ? (Color(hex: colorHex) ?? .accentColor) : Color.primary.opacity(0.12)
        return Button { symbol = s } label: {
            ZStack {
                Circle().fill(fill)
                if s.isEmpty {
                    Text(draft.initial).font(.system(size: 17, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: s).font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.isEmpty ? "Initial" : s.replacingOccurrences(of: ".fill", with: ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        if var p = existing {
            p.name = name; p.colorHex = colorHex; p.symbol = symbol
            profiles.update(p)
        } else {
            profiles.add(name: name, colorHex: colorHex, symbol: symbol)
        }
        dismiss()
    }
}
