import NIOSSL

/// Wrapper around `TLSConfiguration` from NIOSSL to provide a best effort implementation of `Hashable`
struct BestEffortHashableTLSConfiguration: Hashable {
    let base: TLSConfiguration
    
    init(wrapping base: TLSConfiguration) {
        self.base = base
    }
    
    func hash(into hasher: inout Hasher) {
        base.bestEffortHash(into: &hasher)
    }
    
    static func == (lhs: BestEffortHashableTLSConfiguration, rhs: BestEffortHashableTLSConfiguration) -> Bool {
        lhs.base.bestEffortEquals(rhs.base)
    }
}
