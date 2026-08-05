module agent_market::dex_registry {
    /// 거래 장소 식별자다. Indexer와 실행 서버가 어느 경로로 체결됐는지 구분할 때 쓴다.
    ///
    /// Move에는 동적 디스패치가 없으므로 장소마다 별도 executor 모듈을 둔다.
    /// 대신 권한·상태·위험도·한도·중복 Signal·시간·가격 편차·최소 수령량 검사는
    /// 모두 investment_vault의 take_*_for_execution과 settle_*_execution에 모여 있어
    /// 어떤 장소로 체결하든 같은 안전장치가 적용된다.
    ///
    ///   VENUE_MOCK     agent_market::order_executor    (테스트 전용)
    ///   VENUE_DEEPBOOK agent_market::deepbook_executor (MVP 실거래 대상)
    ///
    /// Vault 정책은 여전히 allowed_pool 주소 하나만 허용한다.
    /// 다중 Pool과 라우팅은 보안 감사 범위가 확정된 뒤에 확장한다.
    const VENUE_MOCK: u8 = 0;
    const VENUE_DEEPBOOK: u8 = 1;

    public fun venue_mock(): u8 { VENUE_MOCK }

    public fun venue_deepbook(): u8 { VENUE_DEEPBOOK }
}
