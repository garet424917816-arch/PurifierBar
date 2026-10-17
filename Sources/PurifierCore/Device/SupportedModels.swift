/// Specification-backed property maps and the decision to continue with an unverified model.
public enum SupportedModels {
    // Sources: https://home.miot-spec.com/spec/<model>, latest released MIoT specifications.
    // Only xiaomi.airp.cpa4 has been verified on hardware; all other maps are specification-based.
    public static let layouts: [String: PurifierLayout] = [
        "xiaomi.airp.cpa4": .cpa4,
        "xiaomi.airp.cpa4m": .cpa4,
        "zhimi.airp.cpa4": .cpa4,
        "zhimi.airp.rmb1": .cpa4,
        "zhimi.airpurifier.rma1": .rma1,
        "zhimi.airp.rma2": .rma2,
        "zhimi.airp.mb5": .mb5,
        "zhimi.airp.mb5a": .mb5,
        "zhimi.airp.mp4": .mb5,
        "zhimi.airp.mp4a": .mb5,
        "zhimi.airp.va2": .mb5,
        "zhimi.airp.va2a": .mb5,
        "zhimi.airp.vb4": .mb5,
        "zhimi.airpurifier.ma4": .mb3,
        "zhimi.airpurifier.mb3": .mb3,
        "zhimi.airp.mb3a": .mb3,
        "zhimi.airpurifier.va1": .proH,
        "zhimi.airpurifier.vb2": .proH,
        "zhimi.airpurifier.za1": .za1,
    ]
    public static let models = Set(layouts.keys)

    /// No property reads before consent for a model outside the table.
    public static func layout(for model: String?, decision: Decision) -> PurifierLayout? {
        guard decision != .needsConfirmation else { return nil }
        return model.flatMap { layouts[$0] } ?? .cpa4
    }

    public enum Decision: Equatable, Sendable {
        case supported
        case acceptedUnverified
        case needsConfirmation
    }

    public static func decision(
        for model: String?,
        supported: Set<String> = models,
        acceptedUnverifiedModel: String?
    ) -> Decision {
        // Missing info does not veto an authenticated read.
        guard let model else { return .supported }
        if supported.contains(model) { return .supported }
        return model == acceptedUnverifiedModel ? .acceptedUnverified : .needsConfirmation
    }
}
