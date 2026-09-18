public enum ProtectionDecision {
    public static func make(
        state: ViewingState,
        activeDisplays: Set<DisplayID>,
        settings: AppSettings
    ) -> Set<DisplayID> {
        switch state {
        case .viewing(let displayID):
            return activeDisplays.subtracting([displayID])
        case .away:
            return activeDisplays
        case .paused:
            return []
        case .unavailable, .uncalibrated:
            return settings.failurePolicy == .protectionFirst ? activeDisplays : []
        }
    }
}
