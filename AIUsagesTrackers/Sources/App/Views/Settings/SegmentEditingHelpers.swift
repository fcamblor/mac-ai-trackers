import AIUsagesTrackersLib

enum SegmentEditingHelpers {
    static func metricName(_ metric: UsageMetric) -> String? {
        switch metric {
        case .timeWindow(let name, _, _, _):   return name
        case .payAsYouGo(let name, _, _):      return name
        case .unknown:                         return nil
        }
    }

    static func metricKind(_ metric: UsageMetric) -> MetricKind {
        metric.kind
    }
}
