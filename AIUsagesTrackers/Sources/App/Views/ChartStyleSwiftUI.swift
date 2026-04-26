import SwiftUI
import AIUsagesTrackersLib

extension ChartSeriesColor {
    var displayName: String {
        switch self {
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .purple: "Purple"
        case .red: "Red"
        case .teal: "Teal"
        case .olive: "Olive"
        case .pink: "Pink"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .blue: Color(red: 0.20, green: 0.45, blue: 0.95)
        case .green: Color(red: 0.00, green: 0.56, blue: 0.44)
        case .orange: Color(red: 0.88, green: 0.42, blue: 0.10)
        case .purple: Color(red: 0.62, green: 0.34, blue: 0.88)
        case .red: Color(red: 0.86, green: 0.20, blue: 0.36)
        case .teal: Color(red: 0.08, green: 0.55, blue: 0.72)
        case .olive: Color(red: 0.54, green: 0.50, blue: 0.18)
        case .pink: Color(red: 0.80, green: 0.30, blue: 0.70)
        }
    }
}

extension ChartLineStyle {
    var displayName: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        }
    }

    var strokeStyle: StrokeStyle {
        switch self {
        case .solid:
            StrokeStyle(lineWidth: 2)
        case .dashed:
            StrokeStyle(lineWidth: 2, dash: [6, 4])
        case .dotted:
            StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4])
        }
    }
}
