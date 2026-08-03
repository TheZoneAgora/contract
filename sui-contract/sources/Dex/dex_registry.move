module agent_market::dex_registry {
    /// Mock DEX 실행 경로와 보안 감사 범위가 확정된 뒤 실제 DEX Adapter를 등록한다.
    /// 현재 Vault 정책은 하나의 Pool 주소만 허용한다.
    public struct DexAdapterMarker has copy, drop, store {}
}
