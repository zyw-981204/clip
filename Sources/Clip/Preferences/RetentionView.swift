import SwiftUI

/// Two sliders, persisted via @AppStorage. Numeric values render to the right
/// of each slider so the user sees what they're picking.
struct RetentionView: View {
    @AppStorage("clip.retention.maxItems") private var maxItems: Int = 500
    @AppStorage("clip.retention.maxDays")  private var maxDays: Int  = 30

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最多条数")
                    Spacer()
                    Text("\(maxItems)").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(maxItems) },
                        set: { maxItems = Int($0) }
                    ),
                    in: 100...2000,
                    step: 50
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最长天数")
                    Spacer()
                    Text("\(maxDays)").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(maxDays) },
                        set: { maxDays = Int($0) }
                    ),
                    in: 1...365,
                    step: 1
                )
            }

            Text("钉住的条目不计入限制，也不会因为时间过期而被删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
