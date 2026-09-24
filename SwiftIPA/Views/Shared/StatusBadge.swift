import SwiftUI

struct StatusBadge: View {
    enum Style {
        case tinted
        case plain
    }

    let text: String
    let color: Color
    var style: Style = .tinted

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, style == .tinted ? 7 : 0)
            .padding(.vertical, 2)
            .background(style == .tinted ? color.opacity(0.14) : .clear)
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct CertificateHealthBadge: View {
    let health: CertificateHealth

    var body: some View {
        switch health {
        case .valid:
            StatusBadge(text: String(localized: "Valid"), color: SIColor.success)
        case .expiringSoon:
            StatusBadge(text: String(localized: "Expiring soon"), color: SIColor.warning)
        case .expired:
            StatusBadge(text: String(localized: "Expired"), color: SIColor.danger)
        case .revoked:
            StatusBadge(text: String(localized: "Revoked"), color: SIColor.danger)
        case .unknown:
            StatusBadge(text: String(localized: "Unknown"), color: SIColor.textSecondary)
        }
    }
}
