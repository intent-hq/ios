enum SpecialistModelFetchOutcome {
    case noModelUpdate

    case replaceModels([ModelInfo])

    case superseded
}
