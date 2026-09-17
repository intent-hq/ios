enum SpecialistModelFetchOutcome {
    /// The request is current, but its provider is no longer selected.
    case noModelUpdate

    /// The request is current and its model catalog replaces the visible one.
    case replaceModels([ModelInfo])

    /// A newer request owns all model and loading state.
    case superseded
}
