import SwiftUI
import PeariscopeCore

// MARK: - Idle View

struct IdleView: View {
    @ObservedObject var networkManager: NetworkManager
    @Binding var mode: ContentView.AppMode
    @State private var glowPhase = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Hero
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.pearGlow)
                        .frame(width: 64, height: 64)
                        .blur(radius: glowPhase ? 16 : 10)
                        .opacity(glowPhase ? 0.8 : 0.4)
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                }
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: glowPhase)

                Text("Peariscope")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text("Peer-to-peer remote desktop")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Action cards
            HStack(spacing: 12) {
                ActionCard(
                    title: "Share Screen",
                    subtitle: "Let others view & control this Mac",
                    icon: "antenna.radiowaves.left.and.right",
                    action: { mode = .hosting }
                )
                ActionCard(
                    title: "Connect",
                    subtitle: "View & control a remote device",
                    icon: "laptopcomputer.and.arrow.down",
                    action: { mode = .viewing }
                )
            }
            .padding(.horizontal, 20)

            if let error = networkManager.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.08))
                    .clipShape(Capsule())
            }

            Spacer()

            HStack(spacing: 4) {
                Text("Powered by")
                Image("PearLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 9)
                Link("Pear Runtime", destination: URL(string: "https://pears.com")!)
            }
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
            .padding(.bottom, 10)
        }
        .onAppear { glowPhase = true }
    }
}

struct ActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHovered ? Color.pearGreenDim : Color.pearGreen.opacity(0.06))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isHovered ? Color.pearGreen : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 8 : 4, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isHovered ? Color.pearGreen.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovered }
        }
    }
}
