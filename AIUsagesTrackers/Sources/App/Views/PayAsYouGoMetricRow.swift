import SwiftUI

/// Displays a pay-as-you-go metric: name and formatted consumed amount with currency.
struct PayAsYouGoMetricRow: View {
    let name: String
    let currentAmount: Double
    let currency: String

    private var formattedAmount: String {
        let formatter = NumberFormatter()
        // Non-ISO units ("credits") would otherwise be mangled into a fake
        // currency code ("CRE 260,95") by the currency style.
        guard Locale.commonISOCurrencyCodes.contains(currency.uppercased()) else {
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            let number = formatter.string(from: NSNumber(value: currentAmount)) ?? String(format: "%.2f", currentAmount)
            return "\(number) \(currency)"
        }
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        // Fallback: if the currency code is unknown, prefix with the raw code
        if let formatted = formatter.string(from: NSNumber(value: currentAmount)) {
            return formatted
        }
        return "\(currency) \(String(format: "%.2f", currentAmount))"
    }

    var body: some View {
        HStack {
            Text(name.capitalized)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(formattedAmount)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }
}
